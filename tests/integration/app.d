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
    std.file.write(broken, "functions {\n#include missing-helper.stan\n}\n");
    try { stan.compile(broken); assert(0, "missing include was accepted"); }
    catch (CompilationException error)
    {
        assert(readText(buildPath(error.directory, "build.log")).canFind("missing-helper.stan"));
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
    auto models = buildPath(root, "model sources");
    auto first = buildPath(root, "first library");
    auto second = buildPath(root, "second library");
    mkdirRecurse(buildPath(models, "helpers"));
    mkdir(first);
    mkdir(second);
    std.file.write(buildPath(models, "helpers", "functions.stan"),
        "#include midpoint.stan\n#include centered.stan\n");
    std.file.write(buildPath(models, "midpoint.stan"), "real midpoint() { return 3; }\n");
    std.file.write(buildPath(first, "midpoint.stan"), "real midpoint() { return 100; }\n");
    std.file.write(buildPath(first, "centered.stan"),
        "real centered(real x) { return x - midpoint(); }\n");
    std.file.write(buildPath(second, "centered.stan"), "real centered(real x) { return 999; }\n");
    auto fixedSource = buildPath(models, "fixed_draws.stan");
    std.file.write(fixedSource, `functions {
        #include helpers/functions.stan
    }
    generated quantities {
        real included_value = centered(8);
        real x = 42;
        vector[3] v;
        matrix[2, 3] m;
        array[2] matrix[3, 4] A;
        for (j in 1:3) {
            v[j] = 100 + j;
            for (i in 1:2) m[i, j] = 10 * i + j;
        }
        for (g in 1:2)
            for (r in 1:3)
                for (c in 1:4) A[g, r, c] = 100 * g + 10 * r + c;
    }`);
    CompileOptions build;
    // Relative include paths start at the caller, independently of the model directory.
    build.includePaths = [baseName(first), baseName(second)];
    version (Posix)
    {
        // link/.. reaches the first library. Lexically collapsing it would
        // select the decoy in the caller's working directory instead.
        auto child = buildPath(first, "child");
        mkdir(child);
        symlink(child, buildPath(root, "library link"));
        std.file.write(buildPath(root, "centered.stan"), "real centered(real x) { return -1; }\n");
        build.includePaths[0] = buildPath("library link", "..");
    }
    CompiledModel fixedModel;
    {
        auto previous = getcwd();
        chdir(root);
        scope (exit) chdir(previous);
        fixedModel = stan.compile(fixedSource, build);
    }
    scope (exit) fixedModel.close();
    auto fixedCsv = buildPath(root, "fixed.csv");
    auto fixedRun = execute([fixedModel.executable, "sample", "algorithm=fixed_param",
        "num_warmup=100", "save_warmup=1", "num_samples=3", "thin=2",
        "output", "file=" ~ fixedCsv], null, Config.none, size_t.max, root);
    enforce(fixedRun.status == 0, fixedRun.output);
    auto fixedChain = readSampleCsv(fixedCsv);
    assert(fixedChain.comments.canFind("model = fixed_draws_model"));
    assert(fixedChain.column("included_value") == [5, 5]);
    assert(fixedChain.column("x") == [42, 42] && fixedChain.warmupCount == 0);
    assert(fixedChain.variable("x").series() is fixedChain.column("x"));
    auto v = fixedChain.variable("v");
    auto m = fixedChain.variable("m");
    assert(v.shape == [2, 3] && v.strides == [1, 2]);
    assert(m.shape == [2, 2, 3] && m.strides == [1, 2, 4]);
    foreach (j; 0 .. 3)
    {
        assert(v.series(j) == [101 + j, 101 + j]);
        foreach (i; 0 .. 2)
        {
            auto expected = 10 * (i + 1) + j + 1;
            assert(m.series(i, j) == [expected, expected]);
            assert(m.series(i, j) is fixedChain.column("m." ~ (i + 1).to!string ~ "." ~ (j + 1).to!string));
        }
    }
    auto a = fixedChain.variable("A");
    auto warmA = fixedChain.warmupVariable("A");
    auto n = fixedChain.sampleCount;
    assert(a.shape == [n, 2, 3, 4] && a.strides == [1, n, 2*n, 6*n]);
    assert(warmA.shape == [0, 2, 3, 4] && warmA.strides == [1, 0, 0, 0]);
    foreach (g; 0 .. 2)
        foreach (r; 0 .. 3)
            foreach (c; 0 .. 4)
            {
                auto label = "A." ~ (g + 1).to!string ~ "." ~ (r + 1).to!string ~ "." ~ (c + 1).to!string;
                auto trace = a.series(g, r, c);
                assert(trace is fixedChain.column(label));
                auto expected = 100 * (g + 1) + 10 * (r + 1) + c + 1;
                assert(trace == [expected, expected]);
                assert(warmA.series(g, r, c).length == 0);
            }
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
