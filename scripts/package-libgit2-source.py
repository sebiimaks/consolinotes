#!/usr/bin/env python3
"""Package or verify the reviewed, local-only libgit2 source and build material."""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_VERSION = "1.9.7"
UPSTREAM_COMMIT = "49e408b3208bc3093757a1c2db938d3590f3f412"
UPSTREAM_URL = "https://github.com/libgit2/libgit2/archive/refs/tags/v1.9.7.tar.gz"
UPSTREAM_SHA256 = "1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7"
UPSTREAM_BUILD_INPUTS_SHA256 = "62f0cb5fd386c17ae79f23af8501e4580c4411b9f11832430edaa877da4bc3f3"
ARCHIVE = ROOT / "Resources/libgit2-source.tar.gz"
MANIFEST = ROOT / "Licenses/libgit2-source.json"
PREFIX = "libgit2-source/"
INPUTS = {
    "SOURCE_CODE.md": ROOT / "SOURCE_CODE.md",
    "local-only.patch": ROOT / "Vendor/LocalGit2/local-only.patch",
    "build-local-git.py": ROOT / "scripts/build-local-git.py",
    "package-libgit2-source.py": Path(__file__),
    "build-provenance.json": ROOT / "Vendor/LocalGit2/build-provenance.json",
    "Package.swift": ROOT / "Vendor/LocalGit2/Package.swift",
    "Sources/Cgit2/include/Cgit2.h": ROOT / "Vendor/LocalGit2/Sources/Cgit2/include/Cgit2.h",
    "Sources/Cgit2/git2.c": ROOT / "Vendor/LocalGit2/Sources/Cgit2/git2.c",
    "CONSOLINOTES_LICENSE": ROOT / "LICENSE",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def check_binary():
    binary = ROOT / "Vendor/LocalGit2/libgit2.xcframework"
    provenance = json.loads(INPUTS["build-provenance.json"].read_text())
    actual = {str(path.relative_to(binary)): digest(path.read_bytes())
              for path in sorted(binary.rglob("*")) if path.is_file()}
    if actual != provenance["files"]:
        raise ValueError("libgit2 XCFramework differs from the recorded source build")
    if provenance["patch_sha256"] != digest(INPUTS["local-only.patch"].read_bytes()):
        raise ValueError("libgit2 patch changed without rebuilding the binary")
    if provenance.get("source_build_inputs_sha256") != UPSTREAM_BUILD_INPUTS_SHA256:
        raise ValueError("libgit2 was not built from the reviewed upstream production source inputs")
    return provenance


def generate(upstream):
    data = upstream.read_bytes()
    if digest(data) != UPSTREAM_SHA256:
        raise ValueError("Official upstream archive checksum mismatch")
    entries = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as source:
        for item in source:
            parts = Path(item.name).parts
            if not parts or parts[0] != "libgit2-" + UPSTREAM_VERSION or ".." in parts:
                raise ValueError("Unexpected upstream source path")
            if item.isdir():
                continue
            if not (item.isfile() or item.issym()):
                raise ValueError("Unexpected upstream source entry type")
            relative = Path(*parts[1:]).as_posix()
            entries["libgit2/" + relative] = (item.mode, item.linkname,
                source.extractfile(item).read() if item.isfile() else b"")
    provenance = check_binary()
    for name, path in INPUTS.items():
        entries[name] = (0o755 if name.endswith(".py") else 0o644, "", path.read_bytes())
    output = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=output, compresslevel=9, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for name, (mode, link, content) in sorted(entries.items()):
                item = tarfile.TarInfo(PREFIX + name)
                item.mode = mode
                item.uid = item.gid = item.mtime = 0
                item.uname = item.gname = ""
                item.type = tarfile.SYMTYPE if link else tarfile.REGTYPE
                item.linkname = link
                item.size = 0 if link else len(content)
                archive.addfile(item, None if link else io.BytesIO(content))
    result = output.getvalue()
    manifest = {
        "format": 2, "archive": "Resources/libgit2-source.tar.gz", "archive_root": PREFIX.rstrip("/"),
        "upstream": {"version": UPSTREAM_VERSION, "commit": UPSTREAM_COMMIT,
                     "repository": "https://github.com/libgit2/libgit2", "archive_url": UPSTREAM_URL,
                     "archive_sha256": UPSTREAM_SHA256},
        "patch": {"path": "Vendor/LocalGit2/local-only.patch", "sha256": provenance["patch_sha256"],
                  "description": "Only filesystem transport compiled; all socket, HTTP, Git, SSH transports and HTTP parser excluded."},
        "binary_manifest": "Vendor/LocalGit2/build-provenance.json",
        "binary_manifest_sha256": digest(INPUTS["build-provenance.json"].read_bytes()),
        "archive_sha256": digest(result), "archive_bytes": len(result), "archive_entries": len(entries),
        "correspondence": {
            "status": "locally-built-from-reviewed-pinned-source",
            "limits": ["Binary identity across different compiler/SDK versions is not promised.",
                       "Local Git history is not an encrypted vault; existing historical plaintext is not rewritten."]}
    }
    return result, (json.dumps(manifest, indent=2) + "\n").encode()


def check():
    manifest = json.loads(MANIFEST.read_text())
    if manifest["upstream"]["archive_sha256"] != UPSTREAM_SHA256 or manifest["upstream"]["commit"] != UPSTREAM_COMMIT:
        raise ValueError("Source manifest differs from the reviewed upstream pin")
    if digest(ARCHIVE.read_bytes()) != manifest["archive_sha256"]:
        raise ValueError("Bundled source archive checksum mismatch")
    if digest(INPUTS["build-provenance.json"].read_bytes()) != manifest["binary_manifest_sha256"]:
        raise ValueError("Build provenance differs from the source manifest")
    check_binary()
    with tarfile.open(ARCHIVE, "r:gz") as archive:
        for name, path in INPUTS.items():
            if archive.extractfile(PREFIX + name).read() != path.read_bytes():
                raise ValueError("Source delivery file is stale: " + name)
        if archive.extractfile(PREFIX + "libgit2/COPYING").read() != (ROOT / "Licenses/native/libgit2.txt").read_bytes():
            raise ValueError("libgit2 licence differs from the source archive")
    print("Verified pinned local-only libgit2 source, recipe, licences and XCFramework hashes.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-archive", type=Path, default=ROOT / "build/native-sources/libgit2-v1.9.7.tar.gz")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        check()
    else:
        archive, manifest = generate(args.upstream_archive)
        ARCHIVE.write_bytes(archive)
        MANIFEST.write_bytes(manifest)
        print("Packaged local-only libgit2 source: " + str(len(archive)) + " bytes")


if __name__ == "__main__":
    main()
