#!/usr/bin/env python3
"""Collect packages only when all three platforms identify the same version and revision."""
import argparse
import hashlib
import json
from pathlib import Path

PLATFORMS = {"android": ".apk", "windows": ".msi", "linux": ".deb"}


def sha256(path):
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
        return digest.hexdigest()


def stamp(folder, platform, version, revision):
    files = list(folder.glob("*" + PLATFORMS[platform]))
    if len(files) != 1:
        raise ValueError(f"Expected exactly one {platform} package, got {len(files)}")
    document = {"platform": platform, "version": version, "revision": revision,
                "file": files[0].name, "sha256": sha256(files[0])}
    (folder / f"{platform}.json").write_text(json.dumps(document, indent=2) + "\n")


def collect(folder, version, revision):
    manifests = [json.loads(p.read_text()) for p in folder.rglob("*.json") if p.name in {f"{key}.json" for key in PLATFORMS}]
    if len(manifests) != 3 or {m["platform"] for m in manifests} != set(PLATFORMS):
        raise ValueError("A coordinated output requires Android, Windows and Linux to succeed")
    for manifest in manifests:
        if manifest["version"] != version or manifest["revision"] != revision:
            raise ValueError("Packages do not come from the requested version/revision")
        name = manifest["file"]
        if Path(name).name != name or not name.endswith(PLATFORMS[manifest["platform"]]):
            raise ValueError("Invalid package filename")
        files = list(folder.rglob(name))
        if len(files) != 1 or sha256(files[0]) != manifest["sha256"]:
            raise ValueError("Package missing, duplicated or hash mismatch")
    (folder / "delivery.json").write_text(json.dumps({"version": version, "revision": revision, "packages": manifests}, indent=2) + "\n")
    (folder / "SHA256SUMS").write_text("".join(f'{m["sha256"]}  {m["file"]}\n' for m in sorted(manifests, key=lambda m: m["platform"])))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["stamp", "collect"])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--platform", choices=PLATFORMS)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    if args.command == "stamp":
        if not args.platform:
            parser.error("stamp requires --platform")
        stamp(args.folder, args.platform, args.version, args.revision)
    else:
        collect(args.folder, args.version, args.revision)
