/// This executable serves as both test driver and stand-in CmdStan child.
module process_check;

import cmdstan;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : startsWith;
import std.array : replicate;
import std.conv : to;
import std.exception : enforce;
import std.file;
import std.path;
import std.process : environment;
import std.stdio : stdout, stderr;
import std.uuid : randomUUID;

int main(string[] args)
{
    if (args.length > 1 && args[1] == "sample") return fakeChild(args);
    auto root = buildPath(tempDir(), "cmdstand process " ~ randomUUID.toString);
    environment["STAN_NUM_THREADS"] = "3";
    mkdir(root);
    scope (success) rmdirRecurse(root);
    auto input = JsonFile(buildPath(root, "borrowed data.json"));
    SampleOptions o;
    o.chains = 3;
    o.parallelChains = 2;
    o.seed = 123;
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
    string input, output, id;
    foreach (i, arg; args)
    {
        if (arg == "data") input = args[i + 1]["file=".length .. $];
        if (arg == "output") output = args[i + 1]["file=".length .. $];
        if (arg.startsWith("id=")) id = arg[3 .. $];
    }
    enforce(dirName(output) == getcwd() && baseName(getcwd()) == "chain-" ~ id);
    enforce(environment["STAN_NUM_THREADS"] == "1");
    auto scenario = readText(input);
    if (scenario == "fail" && id == "1") return 17;
    if (scenario == "cancel" && id == "1") write(input ~ ".started", "ready");
    if (scenario != "success") { Thread.sleep(15.seconds); return 1; }

    // Both slots must start, and chain 3 must remain queued until one is free.
    auto run = dirName(getcwd());
    write(buildPath(getcwd(), "ready"), "");
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
