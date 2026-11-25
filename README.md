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

For a dense scalar, vector, or matrix, use the base variable name. The first axis is saved iteration. Variable coordinates use zero-based D indices.

```d
auto m = chain.variable("m");          // For a 2-by-3 matrix with n draws:
auto shape = m.shape;                  // [n, 2, 3]
auto strides = m.strides;              // [1, n, 2*n], in doubles
assert(m.series(1, 2) is chain.column("m.2.3"));
auto warmup = chain.warmupVariable("m");
```

`data` exposes the flat read-only slice for just this variable and phase. The view keeps that storage alive. Look up a view once before looping over its elements.

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

**What can a CSV tell you about the Stan type?** The labels `x.1, x.2, x.3` tell you that each draw has three indexed values. A `vector[3]`, a `row_vector[3]`, and an `array[3] real` all produce those labels. Use the model declaration to choose row or column orientation for linear algebra. The current shaped view handles up to two variable indices; higher-dimensional outputs are accessible by exact column label. See the [CmdStan CSV format](https://mc-stan.org/docs/cmdstan-guide/stan_csv_apdx.html).

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

## Development

- `dub test` runs fixture, discovery, and data tests.
- `dub run --root=tests/process` exercises subprocess scheduling and cleanup without CmdStan.
- With `CMDSTAN` set, run `dub run --root=tests/integration -- examples/bernoulli/bernoulli.stan` from the repository root.
- An additional empty output parent argument makes the integration suite export D-decoded columns. Run `python tests/cross_interface/check.py OUTPUT_PARENT` with CmdStanPy 1.3.2 installed to compare them independently.
- `dub run --root=benchmarks --build=release -- CHAIN.csv COLUMN` reports parser throughput and column traversal time. Use `--json ROWS` as the benchmark arguments to time typed matrix serialization. Measure peak RSS externally and record input dimensions and compiler alongside results.

See [design](docs/design.md) and [roadmap](ROADMAP.md). Code is licensed under BSD-3-Clause. Stan is a registered trademark of NumFOCUS.
