import cmdstan;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file;
import std.path;
import std.process : Config, execute;
import std.stdio;
import std.uuid : randomUUID;

void main(string[] args)
{
    enforce(args.length == 2 || args.length == 3,
            "Usage: integration MODEL.stan [OUTPUT_PARENT_FOR_PYTHON]");
    auto root = buildPath(tempDir(), "cmdstand integration " ~ randomUUID.toString);
    mkdir(root);
    scope (success) rmdirRecurse(root);
    auto source = buildPath(root, "Bernoulli survey.stan");
    copy(args[1], source);
    auto stan = CmdStan.discover();
    auto broken = buildPath(root, "broken.stan");
    std.file.write(broken, "parameters { this is invalid Stan; }");
    try { stan.compile(broken); assert(0, "invalid Stan was accepted"); }
    catch (CompilationException error)
    {
        assert(error.directory.length && exists(buildPath(error.directory, "build.log")));
        rmdirRecurse(error.directory);
    }
    auto model = stan.compile(source);
    scope (exit) model.close();

    struct Survey { int N; int[] y; }
    auto data = Survey(10, [0, 1, 0, 0, 0, 0, 0, 0, 0, 1]);
    auto input = JsonFile(buildPath(root, "survey data.json"));
    writeStanJson(input.path, data);

    SampleOptions o;
    o.chains = o.parallelChains = 2;
    o.warmup = 100;
    o.samples = 31;
    o.thin = 2;
    o.saveWarmup = o.zeroInit = true;
    o.seed = 12345;

    // First exercise transient output, then read the same fit from retained files.
    auto transient = model.sample(data, o);
    assert(!transient.artifacts.directory.length);
    o.outputDir = args.length == 3 ? absolutePath(args[2]) : root;
    auto fit = model.sample(input, o);
    auto stem = stripExtension(baseName(model.executable));
    assert(fit.chain(0).comments.canFind("model = " ~ stem ~ "_model"));
    assert(stem != "fixed_draws");
    auto fixedSource = buildPath(root, "fixed_draws.stan");
    std.file.write(fixedSource, "generated quantities { real x = 42; }");
    auto fixedModel = stan.compile(fixedSource);
    scope (exit) fixedModel.close();
    auto fixedCsv = buildPath(root, "fixed.csv");
    auto fixedRun = execute([fixedModel.executable, "sample", "algorithm=fixed_param",
        "num_warmup=100", "save_warmup=1", "num_samples=3", "thin=2",
        "output", "file=" ~ fixedCsv], null, Config.none, size_t.max, root);
    enforce(fixedRun.status == 0, fixedRun.output);
    auto fixedChain = readSampleCsv(fixedCsv);
    assert(fixedChain.comments.canFind("model = fixed_draws_model"));
    assert(fixedChain.column("x") == [42, 42] && fixedChain.warmupCount == 0);
    auto files = runSample(model.executable, input, root, o);
    assert(fit.chainCount == 2 && fit.seed == o.seed);
    foreach (i; 0 .. fit.chainCount)
    {
        auto chain = fit.chain(i);
        auto id = to!string(i + 1);
        auto direct = buildPath(root, "direct " ~ id ~ ".csv");
        auto result = execute([model.executable, "sample", "num_samples=31", "num_warmup=100",
            "thin=2", "save_warmup=1", "init=0", "random", "seed=12345", "id=" ~ id,
            "data", "file=" ~ input.path, "output", "file=" ~ direct, "sig_figs=17", "refresh=0"],
            null, Config.none, size_t.max, root);
        enforce(result.status == 0, result.output);
        auto raw = readSampleCsv(direct);
        auto fileRun = readSampleCsv(files.chains[i].csv);
        assert(chain.sampleCount == 16 && chain.warmupCount == 50);
        assert(chain.chainId == i + 1 && chain.columnNames == raw.columnNames);
        foreach (name; chain.columnNames)
        {
            assert(chain.column(name) == raw.column(name));
            assert(chain.warmupColumn(name) == raw.warmupColumn(name));
            assert(chain.column(name) == transient.chain(i).column(name));
            assert(chain.column(name) == fileRun.column(name));
        }
        if (args.length == 3)
        {
            // Round-trip D's decoded values for comparison with Python's independent reader.
            auto refFile = File(buildPath(o.outputDir, "parsed-" ~ id ~ ".csv"), "w");
            import std.array : join;
            refFile.writeln(chain.columnNames.join(","));
            foreach (row; 0 .. chain.sampleCount)
            {
                foreach (col, name; chain.columnNames)
                {
                    if (col) refFile.write(",");
                    refFile.writef("%.17g", chain.column(name)[row]);
                }
                refFile.writeln();
            }
        }
    }
    assert(exists(input.path) && exists(fit.artifacts.chains[0].csv));
    model.close();
    assert(!exists(model.executable) && fit.chain(0).column("theta").length == 16);
    writeln("Validated CmdStan ", stan.versionString, " in ", fit.artifacts.directory);
}
