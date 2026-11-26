/// File-oriented sampling and in-memory fits.
module cmdstan.sampling;

import cmdstan.csv : ChainDraws, readSampleCsv;
import cmdstan.internal.workspace : fullPath, newDirectory, removeArtifactDirectory;
import cmdstan.json : JsonFile, writeStanJson;
import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.exception : enforce, basicExceptionCtors;
import std.file : exists, isFile, mkdir, rmdirRecurse;
import std.path : buildPath;
import std.process : Pid, ProcessException, spawnProcess, wait, kill, Config;
import std.random : uniform;
import std.stdio : File, stdin;
import std.traits : isArray, Unqual;

class SamplingException : Exception
{
    /// Requested chains in launch order, including those still queued on failure.
    ChainRun[] chains;
    mixin basicExceptionCtors;
}

/// Cooperative cancellation flag shared with the supervising thread.
final class Cancellation
{
    private shared bool requested;
    /// Returns: Marks this token cancelled for all current and future calls.
    void cancel() @safe nothrow { requested.atomicStore(true); }
    /// Returns: Whether cancellation has been requested.
    @property bool cancelled() @safe nothrow { return requested.atomicLoad; }
}

struct SampleOptions
{
    uint chains = 1, parallelChains = 1;
    uint warmup = 1_000, samples = 1_000, thin = 1;
    uint seed; /// Zero selects one random positive seed for the run.
    bool saveWarmup, zeroInit;
    string outputDir; /// Optional parent for persistent high-level runs.
    Cancellation cancellation;
}

enum ChainState { queued, running, succeeded, failed, cancelled }

struct ChainRun
{
    uint id;
    ChainState state;
    int exitCode;
    string csv, stdoutLog, stderrLog;
    string[] argv;
}

struct SampleRun
{
    string directory;
    uint seed;
    ChainRun[] chains;
}

/++ Params:
        executable = Existing compiled model.
        data = Existing Stan JSON file, owned by the caller.
        outputDir = Parent directory for a new retained run directory.
        options = Sampling configuration. Chain IDs start at one.
    Returns: Artifact paths and process metadata for all chains in ID order.
    Throws: SamplingException for invalid options, cancellation, or child failure.
+/
SampleRun runSample(string executable, JsonFile data, string outputDir, SampleOptions options = SampleOptions.init)
{
    return runFiles(executable, data, outputDir, options, null);
}

/++ Params:
        I = JsonFile or an array of JsonFile values.
        executable = Existing compiled model.
        data = Caller-owned Stan data file.
        outputDir = Parent directory for a new retained run.
        options = Sampling configuration. zeroInit must be false.
        initial = One file shared across chains, or exactly one file per chain
            in launch order. Names must end in .json. Relative paths start at
            the caller's working directory.
    Returns: Retained artifacts and process metadata in chain ID order.
    Throws: SamplingException for invalid options, missing files, cancellation
        or a failed child. The caller retains ownership of all input files.
+/
SampleRun runSample(I)(string executable, JsonFile data, string outputDir, SampleOptions options,
                       auto ref const I initial)
    if (is(Unqual!I == JsonFile) || (isArray!I && is(Unqual!(typeof(initial[0])) == JsonFile)))
{
    return runFiles(executable, data, outputDir, options, initialPaths(initial, options, null));
}

private SampleRun runFiles(string executable, JsonFile data, string outputDir, SampleOptions options,
                           string[] paths)
{
    enforce!SamplingException(outputDir.length, "A retained output directory is required");
    validate(executable, data, options);
    return executeChains(fullPath(executable), fullPath(data.path), newDirectory(outputDir, "run-"), options, paths);
}

private string[] initialPaths(I)(auto ref const I initial, SampleOptions o, string directory)
{
    enforce!SamplingException(!o.zeroInit, "Explicit initialization conflicts with zeroInit");
    static if (isArray!I)
    {
        enforce!SamplingException(initial.length == o.chains, "Expected one initialization per chain");
        auto paths = new string[initial.length];
        foreach (i, ref value; initial)
            paths[i] = initialFile(value, directory, i + 1);
        return paths;
    }
    else return [initialFile(initial, directory, 0)];
}

private string initialFile(I)(auto ref const I value, string directory, size_t id)
{
    static if (is(Unqual!I == JsonFile))
    {
        import std.path : absolutePath;
        import std.algorithm : endsWith;
        auto path = absolutePath(value.path);
        enforce!SamplingException(path.length && exists(path) && isFile(path), "Missing initialization file " ~ path);
        enforce!SamplingException(path.endsWith(".json"), "Initialization file must end in .json: " ~ path);
        return path;
    }
    else
    {
        auto path = buildPath(directory, id ? "init-" ~ id.to!string ~ ".json" : "init.json");
        writeStanJson(path, value);
        return path;
    }
}

private void validate(string exe, JsonFile data, SampleOptions o)
{
    enforce!SamplingException(exists(exe) && isFile(exe), "Missing model executable " ~ exe);
    enforce!SamplingException(exists(data.path) && isFile(data.path), "Missing JSON data " ~ data.path);
    enforce!SamplingException(o.chains && o.parallelChains && o.samples && o.thin,
                              "chains, parallelChains, samples and thin must be positive");
    enforce!SamplingException(o.chains <= int.max && o.samples <= int.max &&
                              o.warmup <= int.max && o.thin <= int.max, "Counts exceed CmdStan integer range");
}

private string[] command(string exe, string data, string csv, SampleOptions o, uint id, uint seed,
                         string[] paths)
{
    auto args = [exe, "sample", "num_samples=" ~ o.samples.to!string,
                 "num_warmup=" ~ o.warmup.to!string, "thin=" ~ o.thin.to!string,
                 o.saveWarmup ? "save_warmup=1" : "save_warmup=0", "id=" ~ id.to!string,
                 "random", "seed=" ~ seed.to!string, "data", "file=" ~ data];
    if (o.zeroInit) args ~= "init=0";
    if (paths.length) args ~= "init=" ~ paths[paths.length == 1 ? 0 : id - 1];
    return args ~ ["output", "file=" ~ csv, "sig_figs=17", "refresh=0", "save_cmdstan_config=1"];
}

version (Windows)
{
    // Wait for the process handle to signal, even if an exit code is available earlier.
    private auto pollChild(Pid child)
    {
        import std.process : waitTimeout;
        return waitTimeout(child, 0.msecs);
    }
}
else private import std.process : pollChild = tryWait;

private SampleRun executeChains(string exe, string data, string directory, SampleOptions o, string[] paths)
{
    SampleRun run;
    run.directory = directory;
    run.seed = o.seed ? o.seed : uniform!"[]"(1u, uint.max);
    run.chains.length = o.chains;
    foreach (i, ref c; run.chains) c.id = cast(uint)i + 1;
    Pid[] children = new Pid[o.chains];
    size_t next, active;
    try
    {
        while (next < o.chains || active)
        {
            enforce!SamplingException(o.cancellation is null || !o.cancellation.cancelled, "Sampling cancelled");
            while (next < o.chains && active < o.parallelChains)
            {
                auto c = &run.chains[next];
                c.state = ChainState.failed; // Until spawn succeeds.
                auto cwd = buildPath(directory, "chain-" ~ c.id.to!string);
                mkdir(cwd);
                c.csv = buildPath(cwd, "draws.csv");
                c.stdoutLog = buildPath(cwd, "stdout.log");
                c.stderrLog = buildPath(cwd, "stderr.log");
                c.argv = command(exe, data, c.csv, o, c.id, run.seed, paths);
                auto outFile = File(c.stdoutLog, "wb");
                auto errFile = File(c.stderrLog, "wb");
                // This milestone schedules single-threaded chains; leave the parent environment alone.
                children[next] = spawnProcess(c.argv, stdin, outFile, errFile,
                                              ["STAN_NUM_THREADS": "1"], Config.none, cwd);
                c.state = ChainState.running;
                ++active;
                ++next;
            }
            foreach (i, ref child; children[0 .. next])
            {
                if (child is null) continue;
                auto status = pollChild(child);
                if (!status.terminated) continue;
                child = null;
                --active;
                auto c = &run.chains[i];
                c.exitCode = status.status;
                c.state = status.status ? ChainState.failed : ChainState.succeeded;
                enforce!SamplingException(status.status == 0, "Chain " ~ c.id.to!string ~
                    " exited with code " ~ status.status.to!string ~ "\n" ~ tail(c.stderrLog) ~ tail(c.stdoutLog));
            }
            if (active) Thread.sleep(10.msecs);
        }
    }
    catch (Exception failure)
    {
        foreach (i, child; children)
        {
            if (child is null) continue;
            finishChild(child, run.chains[i]);
        }
        auto error = new SamplingException(failure.msg ~ "\nRun directory: " ~ directory);
        error.chains = run.chains;
        throw error;
    }
    return run;
}

package void finishChild(Pid child, ref ChainRun chain)
{
    auto status = pollChild(child);
    chain.exitCode = status.status;
    bool stopped;
    if (!status.terminated)
    {
        version (Windows)
        {
            enum stopCode = 0x434D44;
            enum stoppedStatus = stopCode;
        }
        else
        {
            import core.sys.posix.signal : SIGKILL;
            enum stopCode = SIGKILL;
            enum stoppedStatus = -SIGKILL;
        }
        try
        {
            kill(child, stopCode);
            stopped = true;
        }
        catch (ProcessException) { /* The child may have exited since the poll. */ }
        chain.exitCode = wait(child);
        stopped = stopped && chain.exitCode == stoppedStatus;
    }
    if (stopped) chain.state = ChainState.cancelled;
    else chain.state = chain.exitCode ? ChainState.failed : ChainState.succeeded;
}

package string tail(string path)
{
    import std.algorithm : min;
    auto f = File(path, "rb");
    auto n = min(f.size, 4096);
    f.seek(cast(long)(f.size - n));
    return cast(string) f.rawRead(new ubyte[cast(size_t)n]);
}

struct SampleFit
{
    private ChainDraws[] draws;
    uint seed;
    /// Retained run metadata. Empty directory means temporary files were removed.
    SampleRun artifacts;

    /// Returns: Number of validated chains.
    @property size_t chainCount() const @safe pure nothrow { return draws.length; }

    /++ Params:
            index = Zero-based index in requested chain order.
        Returns: Owned chain descriptor sharing the fit's numerical storage.
        Throws: RangeError if index is out of bounds.
    +/
    const(ChainDraws) chain(size_t index) const @safe { return draws[index]; }
}

package SampleFit sampleData(T, I)(string exe, auto ref const T data, SampleOptions o,
                                  auto ref const I initial)
{
    auto directory = newDirectory(o.outputDir, "run-");
    JsonFile input;
    string[] paths;
    try
    {
        static if (is(T == JsonFile)) input = JsonFile(fullPath(data.path));
        else
        {
            input = JsonFile(buildPath(directory, "data.json"));
            writeStanJson(input.path, data);
        }
        validate(exe, input, o);
        static if (!is(I == typeof(null))) paths = initialPaths(initial, o, directory);
    }
    catch (Exception e) { rmdirRecurse(directory); throw e; }

    auto run = executeChains(exe, input.path, directory, o, paths);
    SampleFit fit;
    foreach (ref c; run.chains)
    {
        auto draws = readSampleCsv(c.csv);
        enforce!SamplingException(draws.chainId == c.id &&
            draws.sampleCount == 1 + (o.samples - 1) / o.thin &&
            draws.warmupCount == (o.saveWarmup && o.warmup ? 1 + (o.warmup - 1) / o.thin : 0),
            "Unexpected chain ID or draw counts in " ~ c.csv);
        enforce!SamplingException(!fit.draws.length || fit.draws[0].columnNames == draws.columnNames,
                                  "Inconsistent column schema in " ~ c.csv);
        fit.draws ~= draws;
    }
    fit.seed = run.seed;
    if (o.outputDir.length) fit.artifacts = run;
    else removeArtifactDirectory(directory);
    return fit;
}
