# CmdStanD

CmdStanD is an independent D interface to existing CmdStan installations. The DUB package is `cmdstand` and the import is `cmdstan`. Its core requires Phobos. Reading a saved chain or writing data works without CmdStan.

## Start with files

```d
import cmdstan.csv : readSampleCsv;

auto chain = readSampleCsv("draws.csv");
const(double)[] theta = chain.column("theta");
auto warmup = chain.warmupColumn("theta");
```

Columns use the exact labels in the CSV, including one-based Stan indices such as `beta.1`. Both accessors return views into owned D storage. The input file can be closed or removed after reading.

For a dense variable, use the base variable name. The first axis is saved iteration, followed by one axis per numeric index in the CSV label. Variable coordinates use zero-based D indices.

```d
auto m = chain.variable("m");          // For a 2-by-3 matrix with n draws:
auto shape = m.shape;                  // [n, 2, 3]
auto strides = m.strides;              // [1, n, 2*n], in doubles
assert(m.series(1, 2) is chain.column("m.2.3"));
auto warmup = chain.warmupVariable("m");
```

`data` exposes the flat read-only slice for just this variable and phase. The view keeps that storage alive. Look up a view once before looping over its elements.

### Reopen saved sampling chains

Pass the chain CSVs from a run to `readSampleFit` in the order you want to analyze them. It returns the same `SampleFit` as `model.sample` and works without a CmdStan installation.

```d
import cmdstan.sampling : readSampleFit;

auto fit = readSampleFit("chain-1/draws.csv", "chain-2/draws.csv");
auto theta = fit.chain(1).column("theta");  // Second file supplied
auto warmup = fit.chain(1).warmupColumn("theta");
```

You can also pass an array of paths. For multiple files the reader checks distinct recorded chain IDs (including zero), the model name, column names and order, sampler algorithm and engine, iteration counts, thinning, and warmup retention. For native multi-chain runs, CmdStan records the starting ID in every header. Keep the original output filenames so the importer can identify each chain, even when you pass a subset or change the order. Choose files from the same analysis: two runs on different data can have identical headers. The fit owns its draws and leaves the CSVs in place. Its `seed` is the common recorded seed, or zero when seeds differ or are missing.

### Analyze and plot a chain

The [draw traces example](examples/draws/app.d) follows a scalar parameter through a chain and computes a second trace by taking the determinant of a 2×2 matrix at each saved draw. From the repository root, run:

```sh
dub run --quiet --root=examples/draws -- examples/draws/square.csv > traces.csv
```

For the hand-authored example, the scalar trace is `[1, 4, 7]` (mean 4) and the determinant trace is `[5, -2, 6]` (mean 3). The CSV on standard output has one row per saved draw. For example, to plot both traces in gnuplot:

```gnuplot
set datafile separator ","
set xlabel "Saved draw"
plot "traces.csv" using 1:2 with linespoints title "theta", \
     "traces.csv" using 1:3 with linespoints title "det(A)"
```

### How draws are stored

CmdStan writes one saved draw per CSV row. Within that row it walks down each matrix column before moving to the next column. Here are the matrix columns from the example:

| Saved draw | A.1.1 | A.2.1 | A.1.2 | A.2.2 |
|---|---:|---:|---:|---:|
| 1 | 2 | 1 | 3 | 4 |
| 2 | 1 | 3 | 2 | 4 |
| 3 | 3 | 0 | 1 | 2 |

**To follow a coefficient, read down the table.** CmdStanD stores each of these columns contiguously, so `a.series(0, 1)` gives a view of `[3, 2, 1]`, the trace for Stan's `A[1, 2]`. Stan indices start at one and D indices start at zero.

**To work with a whole draw, read across the table.** For draw 1, the matrix rows are `[2, 3]` and `[1, 4]`, giving determinant `2*4 - 3*1 = 5`. In CmdStanD's buffer, the first value of each coefficient trace belongs to that draw. For a numerical routine that accepts strides, the distances between adjacent rows and adjacent columns are `N` and `N*R` doubles, respectively, for `N` saved draws and `R` matrix rows. A routine that requires a packed row-major matrix needs the entries copied in row order. The example computes directly from the traces.

**What about an array of matrices?** Suppose the model declares `array[2] matrix[3, 4] A`, one matrix per group. The axes of the view are saved draw, group, row, and column. To follow the bottom-right entry of the second group's matrix through the chain:

```d
auto a = chain.variable("A");
auto n = chain.sampleCount;
assert(a.shape == [n, 2, 3, 4]);
assert(a.strides == [1, n, 2*n, 6*n]);
assert(a.series(1, 2, 3) is chain.column("A.2.3.4"));
```

**What can a CSV tell you about the Stan type?** The labels give the indexed extents. The model declaration tells you what each axis means. For example, a `vector[3]`, a `row_vector[3]`, and an `array[3] real` all produce the labels `x.1, x.2, x.3`. Use the declaration to choose row or column orientation for linear algebra. See the [CmdStan CSV format](https://mc-stan.org/docs/cmdstan-guide/stan_csv_apdx.html).

### Select a matrix with Mir

Add the optional DUB dependency `cmdstand:mir` and import `cmdstan.mir : asSlice`. Use one selector for each axis, starting with the saved draw. An integer fixes one coordinate. A range keeps that axis, and `0 .. $` keeps its full length. For the array of matrices above:

```d
import cmdstan.mir : asSlice;

auto draws = a.asSlice;                         // [draw, group, row, column]
auto trace = draws[0 .. $, 1, 2, 3];            // One entry across all draws
auto matrices = draws[0 .. $, 1, 0 .. $, 0 .. $]; // All matrices for group 1 (zero-based)
foreach (matrix; matrices) { /* use matrix[row, col] */ }
assert(matrices[0][2, 3] == trace[0]);         // Random access to the first matrix
```

The first bracket expression returns a native Mir slice with one axis per range, or a single value if every selector is an integer. A slice shares the draw buffer, keeps it alive, and exposes its elements as read-only. The selected matrix retains its row and column strides. To call an in-place factorization, copy the selected matrix into a writable workspace of the layout that routine expects. You can reuse the workspace for successive draws.

The [Mir example](examples/mir-draws/app.d) follows a scalar trace and computes a determinant directly from each strided 2×2 matrix. Run it from the repository root to produce the same three plotting columns as the core example:

```sh
dub run --quiet --root=examples/mir-draws -- examples/draws/square.csv > traces.csv
```

## Compile and sample

Install [CmdStan](https://mc-stan.org/docs/cmdstan-guide/installation.html) and its GNU Make/C++ toolchain. The initial target releases are 2.39.0 and 2.40.0. Set `CMDSTAN` to the installation root or put a release under `~/.cmdstan/cmdstan-X.Y.Z`. An explicit installation uses `CmdStan.at(path)`. On Windows, make `mingw32-make`, the GNU toolchain and its runtime libraries available on PATH. Build staging and installation directories must have Make-compatible paths. Set `CompileOptions.stagingRoot` when the default temporary path contains spaces.

```d
import cmdstan;

struct Survey { int N; int[] y; }
auto stan = CmdStan.discover();
auto model = stan.compile("bernoulli.stan");
scope (exit) model.close();

SampleOptions options;
options.chains = options.parallelChains = 2;
options.seed = 12345;

auto fit = model.sample(Survey(10, [0, 1, 0, 0, 0, 0, 0, 0, 0, 1]), options);
auto theta = fit.chain(0).column("theta");
```

Run the example from `examples/bernoulli` with `dub run`. The model compiles once per handle. Call `sample` again to reuse it. `SampleOptions` defaults to one chain, 1,000 warmup and 1,000 sampling iterations, thinning by one, and discarded warmup. Set `zeroInit` for zero initialization on the unconstrained scale. A positive seed applies to every chain, with independent chain IDs starting at one. The fit exposes the seed used.

For direct control, use `writeStanJson(path, data)` and `runSample(executable, JsonFile(path), outputParent, options)`. The latter retains per-chain CSV, configuration, stdout and stderr below a unique run directory. The convenience API accepts the same `JsonFile`, a struct, string-keyed associative array, or named `JSONValue` object. Set `options.outputDir` to retain its artifacts. Otherwise it removes successful run files after parsing. Exceptions identify failed build or run directories for inspection and removal. Cooperative cancellation uses a `Cancellation` object in the options.

### Choose initial parameter values

Pass a named object as the third argument to `sample` to share one starting point across chains. Pass an array with one object for each chain to choose distinct starting points. Use the parameter names and constrained values from the Stan model. For example, a Bernoulli probability `theta` can start at 0.25:

```d
struct Init { double theta; }
SampleOptions options;
options.chains = 2;
auto sharedFit = model.sample(data, options, Init(0.25));
auto separateFit = model.sample(data, options, [Init(0.25), Init(0.75)]);
```

Entry zero belongs to chain ID 1, even when chains run one at a time. Structs, string-keyed associative arrays, and JSON objects use the same serializer as model data. CmdStanD writes these initial values inside the run directory, which follows the usual `outputDir` retention rules.

For existing files, pass a `JsonFile` or an array of them to either `model.sample(data, options, initial)` or `runSample(executable, dataFile, outputParent, options, initial)`. Initialization filenames must end in lowercase `.json`. Relative file paths start at the caller's working directory, and the caller retains ownership. Omit the argument for CmdStan's default initialization, or set `zeroInit` for zero on the unconstrained scale. Combining `zeroInit` with explicit values raises `SamplingException`.

### Inspect compiler warnings

Set `warnPedantic` to request extra checks from stanc, such as warnings about distribution arguments on unusually large scales. If your CmdStan installation already enables pedantic warnings, both settings preserve them. Read `buildLogPath` while the model is open. Every successful build has a log, and `close()` removes it along with the executable.

```d
import std.file : readText;

CompileOptions build;
build.warnPedantic = true;
auto model = stan.compile("models/survey.stan", build);
scope (exit) model.close();
auto diagnostics = readText(model.buildLogPath);
```

### Models with Stan includes

If `models/survey.stan` contains `#include helpers/centered.stan`, put the helper at `models/helpers/centered.stan` and call `stan.compile("models/survey.stan")` as usual. For shared libraries, add directories in the order you want them searched:

```d
CompileOptions build;
build.includePaths = ["shared Stan functions", "vendor/stan"];
auto model = stan.compile("models/survey.stan", build);
scope (exit) model.close();
```

The model's directory is searched first for every include, including nested ones. Relative entries in `includePaths` resolve from the calling program's working directory. Spaces are supported. An additional directory's absolute path must fit in stanc's comma-separated list, so it cannot contain a comma. For a model with includes, runtime line numbers refer to the expanded `.stan` file alongside `model.executable`.

### Summarize saved chains

Pass the chain CSVs from a single fit to the selected installation. The resulting table includes one row per parameter element and retains the tool's statistic labels.

```d
import cmdstan;

auto stan = CmdStan.discover();
auto stats = stan.summary("runs/chain-1/draws.csv", "runs/chain-2/draws.csv");
double mean = stats["theta", "Mean"];
double rHat = stats["theta", "R_hat"];
```

For a run retained with `SampleOptions.outputDir`, use the paths in `fit.artifacts.chains[i].csv`. Inspect `stats.rowNames` and `stats.columnNames` to discover available entries. For a matrix element, use the upstream label, for example `stats["A[1,2]", "Mean"]`. If you already have a summary CSV from `stansummary`, open it with `readSummaryCsv(path)` without a CmdStan installation.

### Check sampler diagnostics

Pass the saved chains from one HMC fit to `diagnose` to check for divergences, maximum tree depth, and other sampling problems. A completed check returns CmdStan's report, including any findings. A failed invocation raises `DiagnoseException` with the tool's error output.

```d
import cmdstan;
import std.stdio : write;

auto stan = CmdStan.discover();
write(stan.diagnose("runs/chain-1/draws.csv", "runs/chain-2/draws.csv"));
```

## Development

- `dub test` runs fixture, discovery, and data tests.
- `dub test :mir` runs the optional ndslice adapter tests from the repository root.
- `dub run --root=tests/process` exercises subprocess scheduling and cleanup without CmdStan.
- With `CMDSTAN` set, run `dub run --root=tests/integration -- examples/bernoulli/bernoulli.stan` from the repository root.
- An additional empty output parent argument makes the integration suite export D-decoded columns. Run `python tests/cross_interface/check.py OUTPUT_PARENT` with CmdStanPy 1.3.2 installed to compare them independently.
- `dub run --root=benchmarks --build=release -- CHAIN.csv COLUMN` reports parser throughput and column traversal time. Use `--json ROWS` as the benchmark arguments to time typed matrix serialization. Measure peak RSS externally and record input dimensions and compiler alongside results.

See [design](docs/design.md) and [roadmap](ROADMAP.md). Code is licensed under BSD-3-Clause. Stan is a registered trademark of NumFOCUS.
