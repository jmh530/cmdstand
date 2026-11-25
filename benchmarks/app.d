import cmdstan.csv;
import cmdstan.json : writeStanJson;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.exception : enforce;
import std.file : getSize;
import std.stdio : writefln;

void main(string[] args)
{
    enforce(args.length == 3, "Usage: bench-csv CHAIN.csv COLUMN | --json ROWS");
    if (args[1] == "--json")
    {
        import std.file : remove, tempDir;
        import std.path : buildPath;
        import std.uuid : randomUUID;
        struct Data { double[3][] matrix; }
        Data data;
        data.matrix.length = args[2].to!size_t;
        foreach (i, ref row; data.matrix)
            row = [i + 0.125, i + 0.25, i + 0.375];
        auto path = buildPath(tempDir(), "cmdstand-bench-" ~ randomUUID.toString ~ ".json");
        StopWatch timer;
        timer.start();
        writeStanJson(path, data);
        timer.stop();
        scope (exit) remove(path);
        writefln("JSON: %.2f MiB/s, %s rows", getSize(path) / 1048576.0 /
                 (timer.peek.total!"nsecs" * 1e-9), data.matrix.length);
        return;
    }
    StopWatch timer;
    timer.start();
    auto chain = readSampleCsv(args[1]);
    auto seconds = timer.peek.total!"nsecs" * 1e-9;
    auto cells = (chain.warmupCount + chain.sampleCount) * chain.columnNames.length;
    writefln("%.2f MiB/s, %.0f values/s", getSize(args[1]) / 1048576.0 / seconds, cells / seconds);
    timer.reset();
    double sum = 0;
    foreach (v; chain.column(args[2])) sum += v;
    writefln("Column traversal: %s ns, sum %.17g", timer.peek.total!"nsecs", sum);
}
