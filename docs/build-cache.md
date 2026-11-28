# When can CmdStanD reuse a compiled model?

**Recommendation for review.** Keep fresh compilation as the default. Let callers opt into reusing a previous build when they compile the same source again. A caller who already knows which executable to run can use `CompiledModel.open` today. Source-based reuse and forced rebuild are proposed behaviors for a future release.

| When a caller opts into reuse | Proposed behavior |
|---|---|
| The source resolves to the same staged bytes and the recorded build settings match. | Reuse the completed executable and its original build log. |
| A nested include changes, a different include wins the search, or the model name changes. | Resolve the source again and rebuild if the resulting staged bytes or model name differ. |
| The CmdStan installation path or release, requested options, or recorded effective settings change. | Rebuild. Record the ordered include directories, pedantic warnings and thread settings, including the effective settings inherited from Make. |
| The build record is missing or unreadable, required artifacts are missing, or the caller requests a rebuild. | Compile fresh. Publish a replacement only after the build succeeds. |

This is **best-effort reuse**. A system header, compiler, or library can be replaced in place while the recorded settings stay identical. A forced rebuild bypasses CmdStanD's saved model entry and compiles the model in a fresh staging directory. Upstream Make can still reuse the installation's main object, precompiled headers and libraries. After a native toolchain or dependency change, callers may need to rebuild CmdStan itself or select a freshly built installation before forcing a model rebuild. The timing probe below measures source checks on a small model. The full cost of validating a cache entry and the time saved on typical models still need measurement before reconsidering the default.

## What the probes established

The Linux runs used Ubuntu x86-64 under WSL with GNU Make 4.3 and GCC 13.3.0. The native Windows runs used x86-64 MSYS2 UCRT64 GCC 16.2.0 (Rev7), MinGW GNU Make 4.4.1 and MSYS2 shell utilities. Both used LDC 1.43.0. The Windows releases were extracted from the same SHA-256-verified archives as the Linux installations, using the bundled Windows stanc binaries. There was no custom `make/local` in the installations. Configuration experiments modified a private copy of the Make rules. Actual model builds used CmdStanD's public `CmdStan.compile`.

| Experiment on 2.39.0 and 2.40.0 | Observed result | Consequence |
|---|---|---|
| Compile a model which includes a file that itself includes a leaf function. Change its return value from 1 to 2, preserving the leaf's size and modification time. | Both includes appeared in `stanc --info`. Repeated expansion was identical before the edit. Expansion changed after the edit, and the two compiled executables produced draws of 1 and 2 respectively. | Re-run resolution and hash the exact bytes selected for staging. This covers changes in the contents selected by includes, including a change that timestamps miss. Retain the model stem separately. |
| Translate identical staged bytes under two absolute directories, keeping the model basename fixed. | Each generated header contained its own staged source path. With `--filename-in-msg=probe.stan` both headers were identical for this model. | A raw generated-header digest would miss across ordinary UUID staging directories. A cache needs a stable source location for diagnostics. Changing a display filename affects what users see in errors and does not establish native binary reproducibility. |
| Set `STAN_THREADS=true` on Make's command line, in `MAKEFLAGS`, and through a file included by `make/local`. Change only that included file to clear the setting. | The effective main object switched between `main_threads.o` and `main.o`. The top-level `make/local` bytes were identical across the last two queries. | Include the effective settings and resolved native artifacts. Hashing just the D options or the top-level local file can select the wrong executable. |
| Add `STANCFLAGS=--warn-pedantic` for a previously built model. | `print-STANCFLAGS` changed, `make compile_info` stayed identical and `make -q` returned success for the existing target. | Neither query proves build equivalence. A hit must also preserve the requested compiler diagnostics available through `buildLogPath`. |
| Point `CPATH` at two directories containing different versions of the same C++ header. | GCC preprocessing produced 1 and 2 while `make compile_info` was identical. This was an isolated compiler probe. | Compiler search paths and the files they resolve can be inputs even when the displayed command is identical. |

The release rules also identify inputs outside the model source. The link uses CmdStan's main object, Sundials, TBB and conditionally MPI. The model header can be precompiled, and `--allow-undefined` can introduce a user C++ header. The default POSIX model dependency scan uses `-MM`, which excludes system headers. On Windows the link recipe can copy a TBB DLL next to the executable depending on the runtime search path. On both tested Windows releases we observed an adjacent `tbb.dll` in the build directory and the saved directory. On Windows and Linux, after closing the original model and checking that its executable was gone, the saved executable produced the expected draw for each include value. This establishes relocation on the same machine with the same runtime environment. [CmdStan build rules](https://github.com/stan-dev/cmdstan/blob/v2.40.0/make/program)

The Windows compiler distribution matters even when the GCC version matches. In separate fresh release trees, w64devkit GCC 16.2.0 compiled the CmdStan main object but failed at link time on both releases with an unresolved `std::istream::seekg(std::fpos<_Mbstatet>)`. Record the toolchain and runtime identity alongside its version. This observation is specific to the tested configurations.

## macOS validation

The macOS integration jobs for CmdStan 2.39.0 and 2.40.0 run the same probes against the installation each job has just built. After the integration and CmdStanPy checks, the step named `Probe model build reuse on macOS` records LDC, Make and Clang versions, both Make freshness results, the fixed-parameter results, timings and the stanc digest. For each `make -q` query the probe records 0 (current) or 1 (would rebuild) and fails on a Make error. Both hosted results are pending. Timings are observations and have no pass threshold.

## Cost on the probe model

| Platform | CmdStan | Resolve source and hash | Fresh compile after the include edit |
|---|---|---:|---:|
| Windows, MSYS2 UCRT64 | 2.39.0 | 58.9 ms | 5.92 s |
| Windows, MSYS2 UCRT64 | 2.40.0 | 84.2 ms | 7.43 s |
| Linux, Ubuntu under WSL | 2.39.0 | 36.5 ms | 7.69 s |
| Linux, Ubuntu under WSL | 2.40.0 | 31.4 ms | 6.76 s |

The source check is the median of five iterations. Each iteration starts stanc twice (metadata, then include expansion) and hashes the expanded bytes with SHA-256. The compile column is one timed call to `CmdStan.compile` per release after its shared build products existed. It excludes saving and sampling. These observations cover a small model with two nested includes. A complete cache lookup would also need to check build settings and artifacts. The measurements do not establish a cache-hit time or a general speedup.

## What a first implementation would need

- Reuse the existing source-resolution and staging logic at lookup time. Store a versioned build record with the digest of the staged bytes, effective model name, installation identity, platform and build settings. Define which settings can be read reliably from supported installations. If a required setting cannot be determined, compile fresh.
- Keep the executable, runtime companions and original build log together. A cache hit should preserve the warnings a caller can read through `buildLogPath`. Coordinate concurrent builders and keep each completed build usable while a reader has it open. Closing one model must leave other users of the entry unaffected.
- Before enabling reuse, exercise an unchanged model, an edited nested include, reversed include precedence, changed thread or pedantic settings, a missing artifact and a forced rebuild. Check both the reuse decision and the observable draws or diagnostics. Validate on Windows and macOS as well as Linux.

A stronger guarantee that a hit is equivalent to a fresh build would require identifying the effective native inputs, including the tools, headers, objects and libraries actually used. A controlled immutable build environment is one possible way to establish that guarantee. These probes establish why a source digest and Make's freshness check alone cannot provide it.

## Repeat the investigation

From the repository root, use two stock CmdStan installations with their platform's stanc binary in `bin` and pass the native LDC executable explicitly. Run without custom Make or compiler search overrides. The probe uses temporary source and staging directories and does not edit either installation's configuration. As with any model build, upstream Make may update installation build products.

```sh
python3 tests/build-cache/probe.py --ldc /path/to/ldc2 /path/to/cmdstan-2.39.0 /path/to/cmdstan-2.40.0
```

On Windows, use native Python with the MSYS2 UCRT64 toolchain from the repository's CI. Set `MSYSTEM=UCRT64`, put UCRT64's `bin` and MSYS2's `usr/bin` first on the process PATH, and use a Make-compatible path for both installations and the temporary directory. The private Make experiment uses directory junctions on Windows. A PowerShell invocation with example paths follows.

```powershell
python tests/build-cache/probe.py --ldc 'C:/Program Files/LDC 1.43/bin/ldc2.exe' C:/stan/cmdstan-2.39.0 C:/stan/cmdstan-2.40.0
```

| CmdStan | Linux stanc SHA-256 | Windows stanc SHA-256 |
|---|---|---|
| 2.39.0 | `7a6652d03bb0e4a9f0e9ff75d3bd57981fdcf9eceeb19af893515ddb0b61fa36` | `f37a630c77e6c284b7818f7c2796555c72f47b6977cf8821f24661980626b79e` |
| 2.40.0 | `29306a35092c7f6c1aa20df903ddb9dcd83af5995ba37630324a2e019d05e6f4` | `ae112bf8c8a2e3834decc0fc942c910b2976db46b8519596999ed0c97947719d` |
