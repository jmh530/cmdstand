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

/// Settings shared by file-oriented and in-memory sampling.
struct SampleOptions
{
    uint chains = 1, parallelChains = 1;
    uint warmup = 1_000, samples = 1_000, thin = 1;
    uint seed; /// Zero selects one random positive seed for the run.
    bool saveWarmup, zeroInit;
    string outputDir; /// Optional parent for persistent high-level runs.
    Cancellation cancellation;
    /// Maximum threads per chain process, from 1 (default) to int.max.
    /// Values above one require a model compiled with Stan thread support.
    uint threadsPerChain = 1;
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
    enforce!SamplingException(o.threadsPerChain > 0 && o.threadsPerChain <= int.max,
                              "threadsPerChain must be between 1 and int.max");
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
    if (o.threadsPerChain > 1) args ~= "num_threads=" ~ o.threadsPerChain.to!string;
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
                children[next] = spawnProcess(c.argv, stdin, outFile, errFile,
                                              ["STAN_NUM_THREADS": o.threadsPerChain.to!string], Config.none, cwd);
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
    /// Common seed. Zero also denotes missing or differing seeds in an imported fit.
    uint seed;
    /// Retained run metadata, empty for a transient run or an imported fit.
    SampleRun artifacts;

    /// Returns: Number of validated chains.
    @property size_t chainCount() const @safe pure nothrow { return draws.length; }

    /++ Params:
            index = Zero-based index in launch order or, for imports, input file order.
        Returns: Owned chain descriptor sharing the fit's numerical storage.
        Throws: RangeError if index is out of bounds.
    +/
    const(ChainDraws) chain(size_t index) const @safe { return draws[index]; }

    private void append(ChainDraws chain, string path)
    {
        enforce!SamplingException(!draws.length || draws[0].columnNames == chain.columnNames,
                                  "Inconsistent column schema in " ~ path);
        draws ~= chain;
    }
}

/++ Params:
        csvPaths = One or more caller-owned sampling CSV paths in the desired
            chain order. For multiple files, model names must be present and
            individual chain IDs (including zero) must be present and distinct.
            Native multi-chain files must be identifiable by their output names.
    Returns: An in-memory fit owning the decoded sampling and warmup draws.
        A common recorded seed is exposed through seed, otherwise seed is zero.
        No process artifacts are created. The files can be closed or removed
        by their owner after import.
    Throws: SamplingException for empty input, invalid seed metadata, or
        incompatible chains. CsvException or an I/O exception for invalid
        or unreadable sampling CSVs.
+/
SampleFit readSampleFit(const(string)[] csvPaths...)
{
    import std.conv : ConvException;
    enforce!SamplingException(csvPaths.length, "Expected at least one sampling CSV");
    SampleFit fit;
    bool[uint] seen;
    foreach (path; csvPaths)
    {
        auto chain = readSampleCsv(path);
        if (chain.nativeChainCount > 1) chain.id = nativeChainId(chain, path);
        if (csvPaths.length > 1)
        {
            enforce!SamplingException(chain.layout.model.length, "Missing model name in " ~ path);
            enforce!SamplingException(chain.hasRecordedId && chain.chainId !in seen,
                                      "Missing or duplicate chain ID in " ~ path);
            seen[chain.chainId] = true;
            enforce!SamplingException(!fit.draws.length || chain.layout == fit.draws[0].layout,
                                      "Incompatible model or sampling configuration in " ~ path);
        }
        uint seed;
        if (chain.recordedSeed.length)
        {
            try { seed = chain.recordedSeed.to!uint; }
            catch (ConvException e) { throw new SamplingException("Invalid seed in " ~ path); }
        }
        if (!fit.draws.length) fit.seed = seed;
        else if (fit.seed != seed) fit.seed = 0;
        fit.append(chain, path);
    }
    return fit;
}

///
unittest
{
    auto fit = readSampleFit("tests/fixtures/matrix.csv");
    assert(fit.chainCount == 1 && fit.chain(0).chainId == 7);
    assert(fit.chain(0).variable("m").series(1, 2) == [23, 123]);
}

unittest
{
    import cmdstan.csv : CsvException;
    import std.exception : assertThrown;
    import std.file : readText, remove, write;
    import std.string : replace;
    auto directory = newDirectory(null, "saved-fit-");
    scope (exit) rmdirRecurse(directory);
    auto a = buildPath(directory, "a.csv");
    auto b = buildPath(directory, "b.csv");
    auto fixture = "# model = matrix_model\n# seed = 12\n" ~ readText("tests/fixtures/matrix.csv");
    write(a, fixture);
    auto second = fixture.replace("id = 7", "id = 2");
    write(b, second);
    const paths = [b, a];
    auto fit = readSampleFit(paths);
    assert(fit.chainCount == 2 && fit.chain(0).chainId == 2 && fit.chain(1).chainId == 7);
    assert(fit.seed == 12 && !fit.artifacts.directory.length);
    assertThrown!SamplingException(readSampleFit());
    assertThrown!SamplingException(readSampleFit(a, a));
    write(b, second.replace("id = 2", "id = 0"));
    assert(readSampleFit(b, a).chain(0).chainId == 0);
    assertThrown!SamplingException(readSampleFit(b, b));
    auto native = "# num_chains = 2\n# output\n# file = a.csv,b.csv\n" ~ fixture;
    write(a, native);
    write(b, native);
    assert(readSampleFit(b, a).chain(0).chainId == 8);
    assert(readSampleFit(a).chain(0).chainId == 7);
    assertThrown!SamplingException(readSampleFit(b, b));
    write(b, native.replace("a.csv,b.csv", "numbered.csv"));
    assertThrown!SamplingException(readSampleFit(b));
    write(a, fixture);
    foreach (bad; [second.replace("model = matrix_model", "model = other"),
                   second.replace("# model = matrix_model\n", ""),
                   second.replace("# id = 2", "# no recorded ID"), second.replace("num_samples = 3", "num_samples = 4"),
                   second.replace("lp__", "other"), second.replace("seed = 12", "seed = invalid")])
    {
        write(b, bad);
        assertThrown!SamplingException(readSampleFit(a, b));
    }
    foreach (other; [second.replace("seed = 12", "seed = 13"), second.replace("# seed = 12\n", "")])
    {
        write(b, other);
        assert(readSampleFit(a, b).seed == 0);
    }
    write(b, second ~ "0,1,2,3,4,5,6\n");
    assertThrown!CsvException(readSampleFit(a, b));
    remove(a);
    remove(b);
    assert(fit.chain(0).warmupVariable("m").series(1, 2) == [-23]);
}

// Native CmdStan writes the starting ID and output specification into every
// header. Resolve the file's position independently of the caller's ordering.
private uint nativeChainId(ref const ChainDraws chain, string path)
{
    import std.algorithm : endsWith, startsWith;
    import std.conv : ConvException;
    import std.path : absolutePath, baseName, extension, stripExtension;
    import std.string : indexOf, replace, split;
    auto name = baseName(path);
    auto output = chain.outputFile.replace("\\", "/");
    auto start = chain.chainId;
    auto count = chain.nativeChainCount;
    auto invalid = "Cannot determine native chain ID for " ~ path;
    enforce!SamplingException(chain.hasRecordedId && output.length && count - 1 <= uint.max - start, invalid);

    if (output.indexOf(',') >= 0)
    {
        auto names = output.split(",");
        enforce!SamplingException(names.length == count, invalid);
        auto actual = absolutePath(path).replace("\\", "/");
        size_t match, matches, best;
        foreach (i, recorded; names)
        {
            if (!extension(recorded).length) recorded ~= ".csv";
            if (baseName(recorded) != name) continue;
            // A full path distinguishes identically named files in separate
            // directories. A unique basename still works after relocation.
            size_t score = 1;
            if (actual == recorded) score = 3;
            else if (actual.endsWith("/" ~ recorded)) score = 2;
            if (score > best) { best = score; matches = 0; }
            if (score == best) { match = i; ++matches; }
        }
        enforce!SamplingException(matches == 1, invalid);
        return start + cast(uint) match;
    }

    auto prefix = stripExtension(baseName(output)) ~ "_";
    auto suffix = extension(baseName(output));
    if (!suffix.length) suffix = ".csv";
    enforce!SamplingException(name.startsWith(prefix) && name.endsWith(suffix)
                              && name.length > prefix.length + suffix.length, invalid);
    auto digits = name[prefix.length .. $ - suffix.length];
    uint id;
    try { id = digits.to!uint; }
    catch (ConvException e) { throw new SamplingException(invalid); }
    enforce!SamplingException(id >= start && id - start < count && digits == id.to!string, invalid);
    return id;
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
        fit.append(draws, c.csv);
    }
    fit.seed = run.seed;
    if (o.outputDir.length) fit.artifacts = run;
    else removeArtifactDirectory(directory);
    return fit;
}
