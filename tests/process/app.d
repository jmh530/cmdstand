/// This executable serves as both test driver and stand-in CmdStan child.
module cmdstan.process_check;

import cmdstan;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : startsWith;
import std.array : replicate;
import std.conv : to;
import std.exception : enforce;
import std.file;
import std.path;
import std.process : environment, spawnProcess, wait;
import std.stdio : stdout, stderr;
import std.uuid : randomUUID;

private void checkSkippedDiagnoseInput(string root)
{
    import std.exception : collectException;
    auto bin = buildPath(root, "bin");
    mkdir(bin);
    version (Windows) enum suffix = ".exe";
    else enum suffix = "";
    write(buildPath(root, "makefile"), "CMDSTAN_VERSION := 2.40.0\n");
    write(buildPath(bin, "stanc" ~ suffix), "");
    auto tool = buildPath(bin, "diagnose" ~ suffix);
    copy(thisExePath(), tool);
    version (Posix) setAttributes(tool, getAttributes(thisExePath()));

    auto first = buildPath(root, "first chain.csv");
    auto skipped = buildPath(root, "skipped chain.csv");
    foreach (path; [first, skipped]) write(path, "divergent__\n0\n");
    auto error = collectException!DiagnoseException(CmdStan.at(root).diagnose(first, skipped));
    assert(error !is null, "diagnose accepted a partial report");
    assert(error.msg.startsWith("File " ~ skipped ~ " not found"), error.msg);
}

int main(string[] args)
{
    if (stripExtension(baseName(args[0])) == "diagnose")
    {
        enforce(args.length == 3);
        // CmdStan can skip a file and still report success for the other chain.
        stdout.writeln("File ", args[2], " not found");
        stdout.writeln("Processing complete, no problems detected.");
        return 0;
    }
    if (args.length > 1 && args[1] == "sample") return fakeChild(args);
    if (args.length == 3 && args[1] == "exit") return args[2].to!int;
    // Deterministically exercise cleanup after siblings have already exited.
    import cmdstan.sampling : finishChild;
    foreach (code; [0, 17])
    {
        auto sibling = spawnProcess([thisExePath(), "exit", code.to!string]);
        auto actual = wait(sibling);
        assert(actual == code);
        ChainRun report;
        finishChild(sibling, report);
        assert(report.exitCode == code);
        assert(report.state == (code ? ChainState.failed : ChainState.succeeded));
    }
    auto root = buildPath(tempDir(), "cmdstand process " ~ randomUUID.toString);
    environment["STAN_NUM_THREADS"] = "3";
    mkdir(root);
    scope (success) rmdirRecurse(root);
    checkSkippedDiagnoseInput(root);
    version (Windows)
    {
        import cmdstan.internal.workspace : removeArtifactDirectory;
        import std.exception : assertThrown;
        import std.stdio : File;
        auto temporary = buildPath(root, "locked run");
        mkdir(temporary);
        auto log = buildPath(temporary, "stderr.log");
        auto locked = File(log, "wb");
        assertThrown!FileException(remove(log));
        auto release = new Thread({
            Thread.sleep(100.msecs);
            locked.close();
        });
        release.start();
        scope (exit) release.join();
        removeArtifactDirectory(temporary);
        assert(!exists(temporary));
    }
    auto input = JsonFile(buildPath(root, "borrowed data.json"));
    {
        import std.exception : assertThrown;
        auto previous = getcwd();
        chdir(root);
        scope (exit) chdir(previous);
        SampleOptions serial;
        serial.chains = 2;
        JsonFile[] initial = [JsonFile("start one.json"), JsonFile("start two.json")];
        write(initial[0].path, "first");
        write(initial[1].path, "second");
        write(input.path, "inspect init");
        auto perChain = runSample(thisExePath(), input, root, serial, initial);
        assert(readText(perChain.chains[0].csv) == "first");
        assert(readText(perChain.chains[1].csv) == "second");
        auto sharedRun = runSample(thisExePath(), input, root, serial, initial[0]);
        foreach (c; sharedRun.chains) assert(readText(c.csv) == "first");
        assertThrown!SamplingException(runSample(thisExePath(), input, root, serial, initial[0 .. 1]));
        auto rejected = buildPath(root, "rejected initializations");
        mkdir(rejected);
        foreach (name; ["second.txt", "second.JSON", "second.R"])
        {
            import std.algorithm : canFind;
            import std.range : empty;
            initial[1] = JsonFile(name);
            write(name, `{"theta":0.75}`);
            try { runSample(thisExePath(), input, rejected, serial, initial); assert(0); }
            catch (SamplingException e) { assert(e.msg.canFind(absolutePath(name)), e.msg); }
            assert(dirEntries(rejected, SpanMode.shallow).empty);
        }
        initial[1] = JsonFile("absent.json");
        assertThrown!SamplingException(runSample(thisExePath(), input, root, serial, initial));
        serial.zeroInit = true;
        assertThrown!SamplingException(runSample(thisExePath(), input, root, serial, initial[0]));
        assert(readText(initial[0].path) == "first");
    }
    SampleOptions o;
    o.chains = 3;
    o.parallelChains = 2;
    o.seed = 123;
    foreach (invalid; [0u, cast(uint) int.max + 1])
    {
        import std.exception : assertThrown;
        o.threadsPerChain = invalid;
        assertThrown!SamplingException(runSample(thisExePath(), input, root, o));
    }
    o.threadsPerChain = 2;
    write(input.path, "success");
    auto run = runSample(thisExePath(), input, root, o);
    assert(environment["STAN_NUM_THREADS"] == "3");
    foreach (c; run.chains)
    {
        assert(c.state == ChainState.succeeded && c.exitCode == 0);
        assert(getSize(c.stdoutLog) >= 131072 && getSize(c.stderrLog) >= 131072);
        assert(readText(c.csv) == "verified");
    }

    write(input.path, "fail");
    try { runSample(thisExePath(), input, root, o); assert(0); }
    catch (SamplingException e)
    {
        assert(e.chains[0].state == ChainState.failed && e.chains[0].exitCode == 17);
        assert(e.chains[1].state == ChainState.cancelled && e.chains[2].state == ChainState.queued);
        assert(exists(e.chains[0].stderrLog));
    }
    write(input.path, "cancel");
    o.cancellation = new Cancellation;
    auto thread = new Thread({
        auto deadline = MonoTime.currTime + 10.seconds;
        while (!exists(input.path ~ ".started") && MonoTime.currTime < deadline) Thread.sleep(5.msecs);
        o.cancellation.cancel();
    });
    thread.start();
    scope (exit) thread.join();
    try { runSample(thisExePath(), input, root, o); assert(0); }
    catch (SamplingException e)
    {
        assert(e.chains[0].state == ChainState.cancelled && e.chains[2].state == ChainState.queued);
    }
    assert(exists(input.path));
    return 0;
}

private int fakeChild(string[] args)
{
    string input, output, id, initial, threads = "1";
    foreach (i, arg; args)
    {
        if (arg == "data") input = args[i + 1]["file=".length .. $];
        if (arg == "output") output = args[i + 1]["file=".length .. $];
        if (arg.startsWith("id=")) id = arg[3 .. $];
        if (arg.startsWith("init=")) initial = arg[5 .. $];
        if (arg.startsWith("num_threads=")) threads = arg["num_threads=".length .. $];
    }
    enforce(baseName(getcwd()) == "chain-" ~ id);
    // getcwd can resolve a symlink in the supplied output directory.
    write("ready", "");
    enforce(exists(buildPath(dirName(output), "ready")));
    auto scenario = readText(input);
    enforce(threads == (scenario == "inspect init" ? "1" : "2"));
    enforce(environment["STAN_NUM_THREADS"] == threads);
    if (scenario == "inspect init")
    {
        write(output, readText(initial));
        return 0;
    }
    if (scenario == "fail" && id == "1") return 17;
    if (scenario == "cancel" && id == "1") write(input ~ ".started", "ready");
    if (scenario != "success") { Thread.sleep(15.seconds); return 1; }

    // Both slots must start, and chain 3 must remain queued until one is free.
    auto run = dirName(getcwd());
    if (id == "1" || id == "2")
    {
        auto other = id == "1" ? "chain-2" : "chain-1";
        auto deadline = MonoTime.currTime + 5.seconds;
        while (!exists(buildPath(run, other, "ready")) && MonoTime.currTime < deadline)
            Thread.sleep(5.msecs);
        enforce(exists(buildPath(run, other, "ready")));
        enforce(!exists(buildPath(run, "chain-3", "ready")) || exists(buildPath(run, other, "done")));
    }
    stdout.write("x".replicate(131072));
    stderr.write("y".replicate(131072));
    write(output, "verified");
    write(buildPath(getcwd(), "done"), "");
    return 0;
}
