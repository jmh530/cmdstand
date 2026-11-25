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
