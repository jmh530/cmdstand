# Design and source record

## Layers

The file contracts are the foundation. A CSV reader owns numeric buffers and knows nothing about model compilation. A streaming JSON writer accepts named D data or a JSON object. A synchronous process supervisor accepts an executable and existing JSON, then returns artifact paths. The model convenience method composes these pieces and manages temporary files.

An explicit installation snapshots the selected root and release. Compilation invokes its stanc and GNU Make, using a fresh staging directory. The original source may contain spaces in its path. The staged target uses a fixed Make-compatible name. The build directory holds the executable, its runtime companions, model info and compiler log. The model records its source and installation; closing the handle removes the directory. Builds against one installation use a lock across wrapper processes sharing a temp directory. Calls to close must occur after active uses of that model have finished.

The milestone supports standalone sources. Persistent caching needs the resolved transitive include graph, effective options, installation and compiler identity, platform, and build-local settings. An executable timestamp alone cannot capture these inputs. Explicit model-handle reuse avoids this ambiguity.

## Chain and file ownership

A fresh directory per run and per-chain working directories isolate auxiliary outputs. Each child receives an argv vector, numeric chain ID, and shared seed. Log files avoid pipe backpressure. Cancellation stops and reaps direct model children. Compiler process-tree cancellation is future work. A failed run is retained, and the exception includes its location. Callers own existing input files and retained outputs.

Stan data is a named JSON object. Arrays use logical nested indexing, matrices enter by row, and real nonfinite values use quoted Stan spellings. Sampling CSV uses one-based labels and enumerates the first parameter index fastest. The reader validates expected thinned row counts from configuration, independently of adaptation comments, and preserves original comments. It allocates a flat table per chain per phase with offset `column * savedIterations + iteration`. Each column view keeps its buffer alive. High-level chains use zero-based D indexing in launch order.

For a parameter with shape 2 by 3, the first two CSV columns are `m.1.1` and `m.2.1`. A future adapter viewing this variable with axes [iteration, row, column] needs strides [1, n, 2*n] for n iterations. A future Mir subpackage can construct a strided view after validating the header. The core exposes the raw values today. Reading a CSV alone cannot recover the declared shape of a variable which emitted no columns.

## Upstream evidence

- [CmdStan 2.40.0 build rules](https://github.com/stan-dev/cmdstan/blob/v2.40.0/make/program) and [upstream multi-chain tests](https://github.com/stan-dev/cmdstan/blob/v2.40.0/src/test/interface/multi_chain_test.cpp) define the actual process contract. Inspected 2.39.0, 2.40.0 and development revision 11c2e3d1.
- [CmdStanPy 1.3.2 compiler](https://github.com/stan-dev/cmdstanpy/blob/v1.3.2/cmdstanpy/compilation.py) and [fit implementation](https://github.com/stan-dev/cmdstanpy/blob/v1.3.2/cmdstanpy/stanfit/mcmc.py) inform include discovery, toolchain handling and separate warmup access. The development snapshot was 6b280445.
- [CmdStanR 0.9.0 runner](https://github.com/stan-dev/cmdstanr/blob/v0.9.0/R/run.R) and [development compilation note](https://github.com/stan-dev/cmdstanr/blob/fb57d0826c7bb4f743ea1b37ddaf08e971aa7a56/dev-notes/compilation-state.md) inform failure reporting and future persistent caching.
- [Stan.jl 10.8.4](https://github.com/StanJulia/Stan.jl/tree/v10.8.4), StanBase 4.12.4 and [StanSample 7.10.3](https://github.com/StanJulia/StanSample.jl/blob/v7.10.3/src/stansamples/read_csv_files.jl) distinguish the numerical storage layer from downstream adapters.
- [Stan JSON](https://mc-stan.org/docs/cmdstan-guide/json_apdx.html) and [CSV](https://mc-stan.org/docs/cmdstan-guide/stan_csv_apdx.html) specify different multidimensional orders. The checked-in matrix fixture is hand-authored with distinguishable coordinates.

The Bernoulli CSV fixture is chain 1 from the CmdStan 2.39.0 integration run using the release's Bernoulli model and data, seed 12345, zero initialization, 100 warmup iterations, 31 sampling iterations, thinning by two and 17 significant digits. The two file paths and trailing whitespace were normalized. The cross-interface test compares every saved sampling column with CmdStanPy.
