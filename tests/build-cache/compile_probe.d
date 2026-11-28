// Invoked by probe.py against the current, uncached compile path.
import cmdstan;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.exception : enforce;
import std.file : exists;
import std.path : buildPath, dirName;
import std.process : Config, execute;
import std.stdio : writeln;

void main(string[] args)
{
    enforce(args.length == 5, "Expected INSTALLATION SOURCE STAGING_ROOT EXPECTED_VALUE");
    CompileOptions options;
    options.stagingRoot = args[3];
    StopWatch clock;
    clock.start();
    auto model = CmdStan.at(args[1]).compile(args[2], options);
    clock.stop();
    scope (exit) model.close();
    string target = model.executable;
    version (Windows)
    {
        import std.string : replace;
        target = target.replace("\\", "/");
        enum make = "mingw32-make";
    }
    else enum make = "make";
    foreach (flags; ["", "STANCFLAGS=--warn-pedantic"])
    {
        string[] command = [make, "-q"];
        if (flags.length) command ~= flags;
        auto query = execute(command ~ target, null, Config.none, size_t.max, args[1]);
        auto label = flags.length ? flags : "baseline";
        enforce(query.status == 0 || query.status == 1,
                "make -q (" ~ label ~ ") failed with status " ~ query.status.to!string ~ "\n" ~ query.output);
        writeln("make -q (", label, "): ", query.status, query.status == 0 ? " (current)" : " (would rebuild)");
    }
    auto saved = model.save(buildPath(args[3], "saved-" ~ args[4]));
    version (Windows)
    {
        auto adjacentTbb = exists(buildPath(dirName(model.executable), "tbb.dll"));
        enforce(exists(buildPath(dirName(saved), "tbb.dll")) == adjacentTbb);
        writeln("Adjacent tbb.dll at build and save: ", adjacentTbb);
    }
    model.close();
    enforce(!exists(model.executable), "Expected original build to be removed");
    auto csv = buildPath(args[3], "draw.csv");
    auto result = execute([saved, "sample", "algorithm=fixed_param",
        "num_samples=1", "num_warmup=0", "output", "file=" ~ csv], null,
        Config.none, size_t.max, args[3]);
    enforce(result.status == 0, result.output);
    enforce(readSampleCsv(csv).column("value") == [args[4].to!double],
            "Compiled model returned the wrong nested-include value");
    writeln("Value ", args[4], " from saved executable; fresh compile: ",
            clock.peek.total!"msecs", " ms");
}
