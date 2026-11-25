# CmdStanD development

- Keep CSV reading, JSON writing, and execution of an existing model independently usable. Build convenience APIs on these operations.
- Use DUB. Run `dub test` and `dub run --root=tests/process` for core changes. Run the actual CmdStan integration for argument, build, sampling, or file-format changes.
- Consult the shared Codex D compiler inventory when present. Verify and pass the explicit selected compiler path. Compare the same compiler release across platforms.
- Group D overloads and their Ddoc examples and unittests together. Document public inputs, outputs, relevant defaults, ownership, and failure modes.
- Preserve exact upstream fixtures or document hand-authored values. Use non-square deterministic examples for shape and layout changes.
- Keep the core Phobos-only. Track reviewed design and milestone decisions in docs/design.md and ROADMAP.md.
