# Roadmap

1. **File primitives and Bernoulli sampling.** Read saved CSVs, write named data, run existing executables, discover installations, compile standalone models, supervise parallel chains, and compose a convenience fit. Validate against direct CmdStan 2.39.0 and 2.40.0 and CmdStanPy 1.3.2.
2. **General sampling.** Dense scalar, vector and matrix draw views expose shape, strides and shared storage per chain and phase. Next add optional Mir ndslice views. Remaining work covers Stan source includes, compiler options and verified build caching, shared and per-chain initialization values, within-chain threading, richer fit import and upstream diagnostics.
3. **Additional methods.** Begin each method with file-oriented execution and output fixtures. Add optimization, standalone generated quantities, variational inference, Pathfinder and Laplace with method-specific results.
4. **Scale and conveniences.** Use throughput and memory measurements to evaluate selective reading, file-backed fits and alternate decimal parsers. Consider an opt-in installer and reference-validated native diagnostics. Resolve public naming with the Stan Governing Body before publishing.
