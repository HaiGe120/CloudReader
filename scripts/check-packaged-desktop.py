#!/usr/bin/env python3
"""Exercise the actual jpackage launcher/runtime, not the build host's full JDK."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
output = Path(sys.argv[2]).resolve()
names = {"CloudReader", "CloudReader.exe"}
launchers = [p for p in root.rglob("*") if p.is_file() and p.name in names]
if len(launchers) != 1:
    raise SystemExit(f"Expected one packaged launcher, found {launchers}")
subprocess.run([str(launchers[0].resolve()), "--runtime-check", str(output)], check=True, timeout=100)
proof = json.loads((output / "runtime-check.json").read_text())
if not all(proof.get(k) is True for k in ("pdfRender", "webkitLoad", "webkitPageTurn", "isolatedLibrary")):
    raise SystemExit("Packaged runtime verification failed")
print("Bundled runtime: PDF rendered; WebKit loaded and turned a page in an isolated library.")
