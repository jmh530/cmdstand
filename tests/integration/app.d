import cmdstan;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file;
import std.path;
import std.process : Config, environment, execute;
import std.stdio;
import std.uuid : randomUUID;

private void checkPedanticWarnings(CmdStan stan, string directory)
{
    auto source = buildPath(directory, "pedantic.stan");
    enum prior = "y ~ normal(0, 1000);\n";
    std.file.write(buildPath(directory, "prior.stan"), prior);
    // Give these fixture builds known effective flags, independent of make/local.
    auto hadMakeFlags = "MAKEFLAGS" in environment;
    auto previous = environment.get("MAKEFLAGS", "");
    scope (exit)
    {
        if (hadMakeFlags) environment["MAKEFLAGS"] = previous;
        else environment.remove("MAKEFLAGS");
    }
    foreach (inherited; [false, true])
    foreach (body; [prior, "#include prior.stan\n"])
    {
        environment["MAKEFLAGS"] = inherited ? "STANCFLAGS=--warn-pedantic" : "STANCFLAGS=";
        std.file.write(source, "parameters { real y; }\nmodel {\n" ~ body ~ "}\n");
        foreach (enabled; [false, true])
        {
            CompileOptions options;
            options.warnPedantic = enabled;
            auto model = stan.compile(source, options);
            scope (exit) model.close();
            auto log = readText(model.buildLogPath);
            assert(log.canFind("Argument 1000 suggests") == (inherited || enabled), log);
            assert(!log.canFind("Duplicated flag '--warn-pedantic'"), log);
            model.close();
            assert(!exists(model.buildLogPath));
        }
    }
}

private void checkWithinChainThreads(CmdStan stan, string root)
{
    import std.exception : collectException;
    import std.math : isClose;
    auto source = buildPath(root, "threaded_sum.stan");
    std.file.write(source, `functions {
        real partial_sum(array[] int chunk, int start, int end, real scale) {
            return sum(chunk) * scale;
        }
    }
    data { array[8] int weights; }
    parameters { real x; }
    model { target += -0.5 * reduce_sum(partial_sum, weights, 1, square(x)); }
    generated quantities { real total = reduce_sum(partial_sum, weights, 1, 1.0); }`);
    auto data = JsonFile(buildPath(root, "thread weights.json"));
    std.file.write(data.path, `{"weights":[1,2,3,4,5,6,7,8]}`);
    SampleOptions options;
    options.threadsPerChain = 2;
    options.seed = 77;
    options.warmup = 30;
    options.samples = 4;
    options.zeroInit = true;

    CompileOptions build;
    build.enableThreads = true;
    auto threaded = stan.compile(source, build);
    scope (exit) threaded.close();
    CompiledModel ordinary;
    {
        // Override only threading; preserve Make's options and variable assignments.
        auto hadFlags = "MAKEFLAGS" in environment;
        auto flags = environment.get("MAKEFLAGS", "");
        scope (exit)
        {
            if (hadFlags) environment["MAKEFLAGS"] = flags;
            else environment.remove("MAKEFLAGS");
        }
        environment["MAKEFLAGS"] = flags ~ " STAN_THREADS=";
        ordinary = stan.compile(source);
    }
    scope (exit) ordinary.close();
    auto failure = collectException!SamplingException(runSample(ordinary.executable, data, root, options));
    assert(failure !is null && failure.msg.canFind("num_threads"), "Expected an unthreaded model to reject two threads");

    auto fit = threaded.sample(data, options);
    auto csv = buildPath(root, "direct threaded.csv");
    auto direct = execute([threaded.executable, "sample", "num_samples=4", "num_warmup=30",
        "init=0", "random", "seed=77", "num_threads=2", "data", "file=" ~ data.path,
        "output", "file=" ~ csv, "sig_figs=17"], ["STAN_NUM_THREADS": "2"], Config.none, size_t.max, root);
    enforce(direct.status == 0, direct.output);
    auto reference = readSampleCsv(csv);
    foreach (chain; [fit.chain(0), reference])
    {
        assert(chain.comments.canFind("num_threads = 2") || chain.comments.canFind("num_threads = 2 (Default)"));
        assert(chain.column("total") == [36, 36, 36, 36]);
        foreach (i, x; chain.column("x"))
            assert(isClose(chain.column("lp__")[i], -18 * x * x));
    }
}

private void checkSummary(CmdStan stan, string[] paths, string directory)
{
    import std.exception : assertThrown;
    import std.math : isClose, isNaN;
    auto table = stan.summary(paths);
    double total = 0;
    size_t count;
    foreach (path; paths)
        foreach (theta; readSampleCsv(path).column("theta"))
        {
            total += theta;
            ++count;
        }
    assert(isClose(table["theta", "Mean"], total / count));

    version (Windows) enum tool = "stansummary.exe";
    else enum tool = "stansummary";
    auto csv = buildPath(directory, "direct summary.csv");
    auto direct = execute([buildPath(stan.path, "bin", tool), "--sig_figs=17",
        "--csv_filename=" ~ csv] ~ paths);
    enforce(direct.status == 0, direct.output);
    auto expected = readSummaryCsv(csv);
    assert(table.rowNames == expected.rowNames && table.columnNames == expected.columnNames);
    foreach (row; expected.rowNames)
        foreach (column; expected.columnNames)
        {
            auto value = expected[row, column];
            assert(value.isNaN ? table[row, column].isNaN : table[row, column] == value);
        }
    assertThrown!SummaryException(stan.summary());
    assertThrown!SummaryException(stan.summary(paths[0], paths[0]));
    assertThrown!SummaryException(stan.summary(buildPath(directory, "missing.csv")));
    auto invalid = buildPath(directory, "invalid chain.csv");
    std.file.write(invalid, "not a sampling CSV\n");
    assertThrown!SummaryException(stan.summary(invalid));
}

private void checkDiagnose(CmdStan stan, string directory)
{
    import std.exception : assertThrown, collectException;
    // Hand-authored projection of the divergent__ sampler column: four
    // transitions per chain, with one divergence in the second chain.
    auto first = buildPath(directory, "clean chain.csv");
    auto second = buildPath(directory, "divergent chain.csv");
    enum header = "# method = sample\n# algorithm = hmc\n# num_samples = 4\n";
    std.file.write(first, header ~ "# id = 1\ndivergent__\n0\n0\n0\n0\n");
    std.file.write(second, header ~ "# id = 2\ndivergent__\n0\n1\n0\n0\n");
    version (Windows) enum tool = "diagnose.exe";
    else enum tool = "diagnose";
    foreach (paths; [[first], [first, second]])
    {
        auto direct = execute([buildPath(stan.path, "bin", tool)] ~ paths);
        enforce(direct.status == 0, direct.output);
        auto report = stan.diagnose(paths);
        assert(report == direct.output);
        assert(report.canFind(paths.length == 1 ? "no problems detected" :
            "1 of 8 (12.50%) transitions ended with a divergence"));
    }
    assertThrown!DiagnoseException(stan.diagnose());
    assertThrown!DiagnoseException(stan.diagnose(first, first));
    assertThrown!DiagnoseException(stan.diagnose(first, buildPath(directory, "missing.csv")));
    std.file.write(second, "# save_warmup = true\n# num_warmup = 4\ndivergent__\n0\n");
    assertThrown!DiagnoseException(stan.diagnose(second));
    std.file.write(second, "123\n");
    auto failure = collectException!DiagnoseException(stan.diagnose(first, second));
    assert(failure !is null && failure.msg.canFind("Cannot parse input csv file"), "Expected diagnose parse failure");
}

private void checkImportedChainIds(CompiledModel model, JsonFile data, string root)
{
    import std.exception : assertThrown;
    void sample(string output, string id, string count)
    {
        auto result = execute([model.executable, "sample", "num_samples=3", "num_warmup=0",
            "num_chains=" ~ count, "adapt", "engaged=0", "id=" ~ id, "random", "seed=369",
            "data", "file=" ~ data.path, "output", "file=" ~ output], null, Config.none, size_t.max, root);
        enforce(result.status == 0, result.output);
    }
    sample("native.csv", "7", "2");
    auto a = buildPath(root, "native_7.csv");
    auto b = buildPath(root, "native_8.csv");
    auto native = readSampleFit(b, a);
    assert(native.chain(0).chainId == 8 && native.chain(1).chainId == 7);
    assert(native.chain(0).column("theta") == readSampleCsv(b).column("theta"));
    assert(readSampleFit(b).chain(0).chainId == 8);
    assertThrown!SamplingException(readSampleFit(b, b));
    sample("left.csv,right.csv", "7", "2");
    auto named = readSampleFit(buildPath(root, "right.csv"), buildPath(root, "left.csv"));
    assert(named.chain(0).chainId == 8 && named.chain(1).chainId == 7);
    sample("zero.csv", "0", "1");
    sample("one.csv", "1", "1");
    auto singletons = readSampleFit(buildPath(root, "zero.csv"), buildPath(root, "one.csv"));
    assert(singletons.chain(0).chainId == 0 && singletons.chain(1).chainId == 1);
}

private void checkInitialValues(CompiledModel model, JsonFile data, string root)
{
    struct Init { double theta; }
    auto starts = [Init(0.25), Init(0.75)];
    SampleOptions o;
    o.chains = 2;
    o.seed = 12345;
    o.warmup = 30;
    o.samples = 8;
    {
        import std.exception : assertThrown;
        import std.json : parseJSON;
        import std.range : empty;
        o.outputDir = buildPath(root, "invalid initial values");
        auto values = [parseJSON(`{"theta":0.25}`), parseJSON("[]")];
        assertThrown!StanDataException(model.sample(data, o, values));
        assert(dirEntries(o.outputDir, SpanMode.shallow).empty);
    }
    foreach (sharedStart; [true, false])
    {
        o.outputDir = sharedStart ? null : root;
        auto fit = sharedStart ? model.sample(data, o, starts[0]) : model.sample(data, o, starts);
        assert((fit.artifacts.directory.length == 0) == sharedStart);
        foreach (i; 0 .. starts.length)
        {
            auto init = buildPath(root, "reference init.json");
            writeStanJson(init, starts[sharedStart ? 0 : i]);
            if (!sharedStart)
                assert(readText(buildPath(fit.artifacts.directory, "init-" ~ (i + 1).to!string ~ ".json"))
                       == readText(init));
            auto csv = buildPath(root, "reference init draws.csv");
            auto result = execute([model.executable, "sample", "num_warmup=30", "num_samples=8",
                "init=" ~ init, "id=" ~ (i + 1).to!string, "random", "seed=12345",
                "data", "file=" ~ data.path, "output", "file=" ~ csv, "sig_figs=17", "refresh=0"],
                null, Config.none, size_t.max, root);
            enforce(result.status == 0, result.output);
            auto direct = readSampleCsv(csv);
            foreach (name; direct.columnNames)
                assert(fit.chain(i).column(name) == direct.column(name), name);
        }
    }
}

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
    checkDiagnose(stan, root);
    checkWithinChainThreads(stan, root);
    checkPedanticWarnings(stan, root);
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
    checkImportedChainIds(model, input, root);
    checkInitialValues(model, input, root);

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
    checkSummary(stan, [files.chains[0].csv, files.chains[1].csv], root);
    auto reopened = readSampleFit(files.chains[1].csv, files.chains[0].csv);
    assert(reopened.chainCount == 2 && reopened.seed == o.seed);
    assert(fit.chainCount == 2 && fit.seed == o.seed);
    foreach (i; 0 .. fit.chainCount)
    {
        auto chain = fit.chain(i);
        auto imported = reopened.chain(1 - i);
        assert(imported.chainId == chain.chainId);
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
            assert(imported.column(name) == raw.column(name));
            assert(imported.warmupColumn(name) == raw.warmupColumn(name));
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
