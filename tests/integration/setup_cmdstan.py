"""Prepare one pinned CmdStan installation in the CI runner's temp directory."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
from urllib.request import urlretrieve

digests = {
    "2.39.0": "ffe03c29c9f139d77deeb156a2a0911ebf0742ae38311c739f4fcea3bc4f8909",
    "2.40.0": "26d21c9737b35728e926f9b7a5d7362b38dc23e2e7d5e166c890e1fa74dac90c",
}
version = sys.argv[1]
root = Path(os.environ["RUNNER_TEMP"])
cache = root / "cmdstan-archives"
cache.mkdir(exist_ok=True)
archive = cache / f"cmdstan-{version}.tar.gz"
if not archive.is_file():
    urlretrieve(
        f"https://github.com/stan-dev/cmdstan/releases/download/v{version}/{archive.name}",
        archive,
    )
with archive.open("rb") as stream:
    if hashlib.file_digest(stream, "sha256").hexdigest() != digests[version]:
        raise ValueError(f"Checksum mismatch for {archive}")
tar = Path(os.environ["SystemRoot"]) / "System32" / "tar.exe" if os.name == "nt" else "tar"
subprocess.run([tar, "-xzf", str(archive), "-C", str(root)], check=True)
installation = root / f"cmdstan-{version}"
make = "mingw32-make" if os.name == "nt" else "make"
subprocess.run([make, "-j2", "build"], cwd=installation, check=True)
with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as out:
    print(f"CMDSTAN={installation}", file=out)
