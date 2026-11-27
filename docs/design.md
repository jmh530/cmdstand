# Design and source record

## Layers

The file contracts are the foundation. A CSV reader owns numeric buffers and knows nothing about model compilation. A streaming JSON writer accepts named D data or a JSON object. A synchronous process supervisor accepts an executable and existing JSON, then returns artifact paths. The model convenience method composes these pieces and manages temporary files.

An explicit installation snapshots the selected root and release. Compilation invokes its stanc and GNU Make, using a fresh staging directory. The target retains the source basename for ordinary identifiers. Other filenames use a Make-compatible identifier with a digest of the original name so the CSV records a distinguishable model name. The build directory holds the executable, its runtime companions, model info and compiler log. The model records its source and installation. Closing the handle removes the directory. Builds against one installation use a lock across wrapper processes sharing a temp directory. Calls to close must occur after active uses of that model have finished.

CmdStanD runs `stanc --info` in the original model directory with an ordered include search path. When the metadata lists included files, it runs `stanc --auto-format --canonicalize=includes` with the same source, working directory and search path, and writes the expanded program into staging. Make translates that file using the installation's build settings. This lets stanc resolve nested includes and report missing files against the original sources. Runtime diagnostics refer to the staged program's line numbers. Single-file models are copied verbatim.

When requested, pedantic warnings are enabled during Stan-to-C++ translation. A second Make file appends the flag after CmdStan loads its configuration, preserving installation flags. The model handle exposes the combined compiler and Make log through `buildLogPath` until close.

Persistent caching needs the resolved transitive include graph, effective options, installation and compiler identity, platform, and build-local settings. An executable timestamp alone cannot capture these inputs. Explicit model-handle reuse avoids this ambiguity.

## Chain and file ownership

A fresh directory per run and per-chain working directories isolate auxiliary outputs. Each child receives an argv vector, numeric chain ID, and shared seed. Log files avoid pipe backpressure. Cancellation stops and reaps direct model children. Compiler process-tree cancellation is future work. A failed run is retained, and the exception includes its location. Callers own existing input files and retained outputs.

The file-oriented sampler resolves all caller-owned initialization files before launching any chain. One file is shared, and an array is checked against the requested chain count and indexed by launch order. The model API also accepts named D values, which it serializes once per shared value or once per chain into the run directory. An explicit initialization and zero initialization are mutually exclusive.

Stan data is a named JSON object. Arrays use logical nested indexing, matrices enter by row, and real nonfinite values use quoted Stan spellings. Sampling CSV uses one-based labels and enumerates the first parameter index fastest. The reader validates expected thinned row counts from configuration, independently of adaptation comments, and preserves original comments. It allocates a flat table per chain per phase with offset `column * savedIterations + iteration`. Each column view keeps its buffer alive. Fits use zero-based D indexing in launch order for live runs and in caller-supplied file order for imports. A saved-fit import decodes each chain once. It validates the recorded model, sampler and draw layout, accepts zero and nonconsecutive IDs and differing seeds, and leaves process artifacts empty. For native multi-chain output, the recorded output names and chain count identify each file within the range beginning at the recorded ID. Ambiguous names are rejected. Source files remain caller-owned.

For a parameter with shape 2 by 3, the first two CSV columns are `m.1.1` and `m.2.1`. The core `DrawView` exposes axes [iteration, row, column] and element strides [1, n, 2*n] for n saved iterations. Sampling and warmup views use their own phase lengths. A lookup scans the header and validates the requested block's rank, contiguity, indices and ordering. The resulting view holds small shape and stride arrays and a read-only slice of the original draw buffer. Coordinate access requires no further header lookup.

The header establishes indexed extents for dense numeric outputs of any rank. The last label in a canonical block gives its extents, including singleton axes. The reader checks their product against the observed column count by successive division, then verifies every label with the first index varying fastest. A vector, row vector and one-dimensional array can have identical CSV labels. Variables that emitted no columns have no recoverable shape. Other output encodings remain accessible by exact column label.

The optional DUB subpackage `cmdstand:mir` exposes a runtime-rank indexing handle through `DrawView.asSlice`. The first bracket expression supplies one integer or half-open range per input axis. The number of ranges determines the compile-time rank of the native Mir result, a `Slice!(const(double)*, N, Universal)`. All-integer selection returns a scalar. The adapter checks dimensions, bounds and strides against the buffer, and shares the GC-owned numeric storage. The resulting slice supports Mir iteration and random access.

## Posterior summaries

`CmdStan.summary` passes chain CSV paths to the selected installation's `bin/stansummary`. CmdStan computes the statistics and writes its machine-readable CSV at 17 significant digits. Each invocation owns a temporary directory for the output and process log. The caller owns the chain files. The returned table owns its data, so callers can query it after removing those files. A transient fit must be sampled with output retention enabled if its chain CSVs will be needed later.

`readSummaryCsv` is independently usable. It preserves upstream row and statistic labels, including bracketed parameter indices and percentile columns. Undefined diagnostics retain their upstream floating-point values. The parser shares the sampling reader's locale-independent numeric conversion.

## Upstream evidence

- [CmdStan 2.40.0 build rules](https://github.com/stan-dev/cmdstan/blob/v2.40.0/make/program) and [upstream multi-chain tests](https://github.com/stan-dev/cmdstan/blob/v2.40.0/src/test/interface/multi_chain_test.cpp) define the actual process contract. Inspected 2.39.0, 2.40.0 and development revision 11c2e3d1.
- [CmdStanPy 1.3.2 compiler](https://github.com/stan-dev/cmdstanpy/blob/v1.3.2/cmdstanpy/compilation.py) and [fit implementation](https://github.com/stan-dev/cmdstanpy/blob/v1.3.2/cmdstanpy/stanfit/mcmc.py) inform include discovery, toolchain handling and separate warmup access. The development snapshot was 6b280445.
- [CmdStanR 0.9.0 runner](https://github.com/stan-dev/cmdstanr/blob/v0.9.0/R/run.R) and [development compilation note](https://github.com/stan-dev/cmdstanr/blob/fb57d0826c7bb4f743ea1b37ddaf08e971aa7a56/dev-notes/compilation-state.md) inform failure reporting and future persistent caching.
- [Stan.jl 10.8.4](https://github.com/StanJulia/Stan.jl/tree/v10.8.4), StanBase 4.12.4 and [StanSample 7.10.3](https://github.com/StanJulia/StanSample.jl/blob/v7.10.3/src/stansamples/read_csv_files.jl) distinguish the numerical storage layer from downstream adapters.
- [Stan JSON](https://mc-stan.org/docs/cmdstan-guide/json_apdx.html) and [CSV](https://mc-stan.org/docs/cmdstan-guide/stan_csv_apdx.html) specify different multidimensional orders. The checked-in matrix fixture is hand-authored with distinguishable coordinates.

The Bernoulli CSV fixture is chain 1 from the CmdStan 2.39.0 integration run using the release's Bernoulli model and data, seed 12345, zero initialization, 100 warmup iterations, 31 sampling iterations, thinning by two and 17 significant digits. The two file paths and trailing whitespace were normalized. The cross-interface test compares every saved sampling column with CmdStanPy.
