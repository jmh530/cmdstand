"""Probe CmdStan build reuse with GNU Make, a C++ compiler and LDC."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time


def run(args, cwd, **kwargs):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args} exited with {result.returncode}\n{result.stdout}{result.stderr}")
    return result.stdout


def probe_model(root, work, driver, stanc):
    model = work / "probe.stan"
    middle = work / "middle.stan"
    leaf = work / "leaf.stan"
    model.write_text("functions {\n#include middle.stan\n}\ngenerated quantities { real value = f(); }\n")
    middle.write_text("#include leaf.stan\n")
    leaf.write_text("real f() { return 1; }\n")

    def expand():
        return run([stanc, "--include-paths=.", "--auto-format", "--canonicalize=includes", model], work)

    info = json.loads(run([stanc, "--info", "--include-paths=.", model], work))
    assert {Path(p).name for p in info["included_files"]} == {middle.name, leaf.name}
    original = expand()
    assert expand() == original
    print(run([driver, root, model, work, "1"], work).strip(), flush=True)
    times = leaf.stat()
    leaf.write_text("real f() { return 2; }\n")
    os.utime(leaf, ns=(times.st_atime_ns, times.st_mtime_ns))
    assert leaf.stat().st_mtime_ns == times.st_mtime_ns and leaf.stat().st_size == times.st_size
    assert expand() != original
    print(run([driver, root, model, work, "2"], work).strip(), flush=True)

    # Time the source portion of lookup separately from Make and compilation.
    # Hash stanc's raw output so text-mode newline conversion is excluded.
    durations = []
    for _ in range(5):
        start = time.perf_counter()
        metadata = json.loads(run([stanc, "--info", "--include-paths=.", model], work))
        assert metadata["included_files"]
        expanded = subprocess.check_output(
            [stanc, "--include-paths=.", "--auto-format", "--canonicalize=includes", model], cwd=work)
        hashlib.sha256(expanded).digest()
        durations.append(1000 * (time.perf_counter() - start))
    print(f"Source resolution and hash (median of five): {statistics.median(durations):.1f} ms", flush=True)

    return original


def probe_stage_paths(root, work, stanc, original):
    # Make invokes stanc with the absolute staged model path. Check whether
    # relocating identical source changes the generated header.
    headers = []
    stable_headers = []
    for name in ("stage-a", "stage-b"):
        directory = work / name
        directory.mkdir()
        staged = directory / "probe.stan"
        staged.write_text(original)
        header = staged.with_suffix(".hpp")
        run([stanc, "--o=" + header.as_posix(), staged.as_posix()], root)
        headers.append(header.read_text())
        assert staged.as_posix() in headers[-1]
        run([stanc, "--filename-in-msg=probe.stan", "--o=" + header.as_posix(), staged.as_posix()], root)
        stable_headers.append(header.read_text())
    assert headers[0] != headers[1]
    assert stable_headers[0] == stable_headers[1]


def probe_make_settings(root, work):
    windows = os.name == "nt"
    # Exercise the stock build rules with a private make/local. Only inspect
    # Make variables here; model compilation uses the real installation.
    shadow = work / "shadow"
    shadow.mkdir()
    shutil.copytree(root / "make", shadow / "make")
    shutil.copyfile(root / "makefile", shadow / "makefile")
    if windows:
        # Junctions work without symbolic-link privileges. Pass the installation
        # path as data so shell metacharacters never become part of the command.
        run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
             "$ErrorActionPreference = 'Stop'; foreach ($name in 'stan','src','bin','lib') {"
             "New-Item -ItemType Junction -Path $name -Target (Join-Path $env:PROBE_ROOT $name) | Out-Null }"],
            shadow, env=dict(os.environ, PROBE_ROOT=str(root)))
    else:
        for name in ("stan", "src", "bin", "lib"):
            (shadow / name).symlink_to(root / name)
    local = shadow / "make/local"
    local.write_text("")

    def make(*args, env=None):
        return run(["mingw32-make" if windows else "make", "-s", *args], shadow, env=env)

    base = make("compile_info")
    assert make("compile_info") == base
    assert make("STANCFLAGS=--warn-pedantic", "compile_info") == base
    assert "--warn-pedantic" in make("STANCFLAGS=--warn-pedantic", "print-STANCFLAGS")
    assert "main_threads.o" in make("STAN_THREADS=true", "print-CMDSTAN_MAIN_O")
    assert "main_threads.o" in make("print-CMDSTAN_MAIN_O", env=dict(os.environ, MAKEFLAGS="STAN_THREADS=true"))
    local.write_text("include make/probe-settings\n")
    settings = shadow / "make/probe-settings"
    settings.write_text("STAN_THREADS=true\n")
    assert "main_threads.o" in make("print-CMDSTAN_MAIN_O")
    settings.write_text("STAN_THREADS=\n")
    assert "main.o" in make("print-CMDSTAN_MAIN_O")

    # The compiler also consults inputs absent from the displayed command.
    source = work / "header.cc"
    source.write_text("#include <probe-value.hpp>\nPROBE_VALUE\n")
    for value in ("1", "2"):
        directory = work / ("headers-" + value)
        directory.mkdir()
        (directory / "probe-value.hpp").write_text("#define PROBE_VALUE " + value + "\n")
        env = dict(os.environ, CPATH=directory.as_posix())
        assert make("compile_info", env=env) == base
        compiler = "clang++" if sys.platform == "darwin" else "g++"
        assert run([compiler, "-E", "-P", source], work, env=env).strip() == value


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    if not __debug__:
        parser.error("Run with Python assertions enabled so all probes execute.")
    parser.add_argument("--ldc", type=Path, required=True)
    parser.add_argument("installations", type=Path, nargs="+")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="cmdstand-cache-probe-") as tmp:
        directory = Path(tmp).resolve()
        driver = directory / ("compile-probe.exe" if os.name == "nt" else "compile-probe")
        run([args.ldc.resolve(), "-i", "-Isource", "-of=" + str(driver),
             "tests/build-cache/compile_probe.d"], repo)
        for i, installation in enumerate(args.installations):
            work = directory / str(i)
            work.mkdir()
            root = installation.resolve()
            stanc = root / "bin" / ("stanc.exe" if os.name == "nt" else "stanc")
            print(run([stanc, "--version"], work).strip(), flush=True)
            probe_make_settings(root, work)
            original = probe_model(root, work, driver, stanc)
            probe_stage_paths(root, work, stanc, original)
            print("PASS: nested include, saved executable, staged path, threaded main, Make settings,"
                  " compiler search path; stanc SHA-256", hashlib.sha256(stanc.read_bytes()).hexdigest(),
                  flush=True)
