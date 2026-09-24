#!/usr/bin/env python3
"""Package the exact upstream libgit2 source trees; no network or build steps."""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_COMMIT = "ab1a18d82002b185c1c73b0daaa4174bb6b4f29c"
RELEASE_COMMIT = "d7368c04a5cfe2c06fa1c8040d547e86aa4e02ee"
LIBGIT2_COMMIT = "6c78fd06e3cedec818122ecc7f90e6c81e497354"
ISSH2_COMMIT = "f9b8f8b913614ed5d5875d7b734b8aad8a2c13d3"
BINARY_URL = "https://github.com/glushchenko/swift-cgit2/releases/download/1.2.0/libgit2.xcframework.zip"
BINARY_SHA256 = "cbf67a82594267aecc5cc4d021059cf0165f38566df0dcf0c52e065f1d6f1358"
PREFIX = "libgit2-source/"


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def source_entries(repo, commit, prefix):
    """Read committed bytes, including tests and build files, without .git data."""
    archive = git(repo, "archive", "--format=tar", commit)
    entries = {}
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        for item in source:
            if item.isdir():
                continue
            if not (item.isfile() or item.issym()):
                raise ValueError(f"Unexpected source entry type: {item.name}")
            if item.name.startswith("/") or ".." in Path(item.name).parts:
                raise ValueError(f"Unsafe source path: {item.name}")
            data = source.extractfile(item).read() if item.isfile() else b""
            entries[prefix + item.name] = (item.mode, item.linkname, data)
    return entries


def generate(checkout, artifacts):
    pins = json.loads((ROOT / "FSNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())["pins"]
    pin = next(pin for pin in pins if pin["identity"] == "swift-cgit2")
    if pin["state"]["revision"] != PACKAGE_COMMIT:
        raise ValueError("swift-cgit2 changed; review and update the source pins first")
    package = git(checkout, "show", f"{PACKAGE_COMMIT}:Package.swift")
    if BINARY_URL.encode() not in package or BINARY_SHA256.encode() not in package:
        raise ValueError("Unexpected swift-cgit2 binary URL or checksum")
    if (checkout / "Package.swift").read_bytes() != package:
        raise ValueError("The resolved Package.swift differs from the pinned source")
    for name, commit in (("libgit2", LIBGIT2_COMMIT), ("iSSH2", ISSH2_COMMIT)):
        for parent in (PACKAGE_COMMIT, RELEASE_COMMIT):
            if git(checkout, "rev-parse", f"{parent}:{name}").decode().strip() != commit:
                raise ValueError(f"Unexpected {name} submodule in {parent}")
    if git(checkout, "diff", PACKAGE_COMMIT, RELEASE_COMMIT, "--", "bin"):
        raise ValueError("Build scripts differ between binary release and package")

    components = [
        {"name": "swift-cgit2", "repository": "https://github.com/glushchenko/swift-cgit2", "commit": PACKAGE_COMMIT, "path": "swift-cgit2"},
        {"name": "libgit2", "repository": "https://github.com/libgit2/libgit2", "commit": LIBGIT2_COMMIT, "path": "swift-cgit2/libgit2"},
        {"name": "iSSH2", "repository": "https://github.com/sharplet/iSSH2", "commit": ISSH2_COMMIT, "path": "swift-cgit2/iSSH2"},
    ]
    entries = {}
    for component, repo in zip(components, (checkout, checkout / "libgit2", checkout / "iSSH2")):
        component["tree"] = git(repo, "rev-parse", component["commit"] + "^{tree}").decode().strip()
        exported = source_entries(repo, component["commit"], component["path"] + "/")
        component["files"] = len(exported)
        entries.update(exported)

    binary_files = []
    for binary in sorted(artifacts.glob("*/libgit2.a")):
        headers = sorted((binary.parent / "Headers").rglob("*.h"))
        if not headers:
            raise ValueError(f"Missing artifact headers: {binary.parent}")
        for header in headers:
            relative = header.relative_to(binary.parent / "Headers").as_posix()
            committed = entries["swift-cgit2/libgit2/include/" + relative][2]
            if header.read_bytes() != committed:
                raise ValueError(f"Artifact header differs from source: {header}")
        binary_files.append({"path": binary.relative_to(artifacts).as_posix(), "sha256": digest(binary.read_bytes()), "matching_source_headers": len(headers)})
    if len(binary_files) != 3:
        raise ValueError("Expected all three libgit2 XCFramework slices")

    manifest = {
        "format": 1,
        "archive": "Resources/libgit2-source.tar.gz",
        "archive_root": PREFIX.rstrip("/"),
        "binary": {
            "package_version": "1.2.2", "url": BINARY_URL, "sha256_from_package_manifest": BINARY_SHA256,
            "release_tag": "1.2.0", "release_commit": RELEASE_COMMIT,
            "release_url": "https://github.com/glushchenko/swift-cgit2/releases/tag/1.2.0",
            "local_xcframework_files": binary_files,
        },
        "components": components,
        "correspondence": {
            "status": "upstream-pinned-source; binary-build-attestation-unavailable",
            "verified": ["Package.resolved pins the stated swift-cgit2 commit", "Package.swift pins the stated release ZIP and checksum", "Release 1.2.0 and package 1.2.2 share the same libgit2, iSSH2 and build scripts", "All 87 public headers in each of the three local binary slices match the libgit2 source"],
            "limits": ["Upstream provides no build attestation or complete release build log", "The original iSSH2 build script discovers external OpenSSL and libssh2 versions dynamically", "The prebuilt XCFramework has not been independently reproduced byte for byte", "The historical build scripts have not been tested with current Xcode"],
        },
    }
    entries["SOURCE_CODE.md"] = (0o644, "", (ROOT / "SOURCE_CODE.md").read_bytes())
    entries["SOURCE_MANIFEST.json"] = (0o644, "", json_bytes(manifest))
    entries["package-libgit2-source.py"] = (0o755, "", Path(__file__).read_bytes())
    entries["binary-release-Package.swift"] = (0o644, "", git(checkout, "show", f"{RELEASE_COMMIT}:Package.swift"))
    output = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=output, compresslevel=9, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for name, (mode, link, data) in sorted(entries.items()):
                item = tarfile.TarInfo(PREFIX + name)
                item.mode = mode
                item.uid = item.gid = item.mtime = 0
                item.uname = item.gname = ""
                item.type = tarfile.SYMTYPE if link else tarfile.REGTYPE
                item.linkname = link
                item.size = 0 if link else len(data)
                archive.addfile(item, None if link else io.BytesIO(data))
    data = output.getvalue()
    manifest["archive_sha256"] = digest(data)
    manifest["archive_bytes"] = len(data)
    manifest["archive_entries"] = len(entries)
    return data, json_bytes(manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, default=ROOT / "build/DerivedData/SourcePackages/checkouts/swift-cgit2")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "build/DerivedData/SourcePackages/artifacts/swift-cgit2/libgit2/libgit2.xcframework")
    parser.add_argument("--check", action="store_true", help="verify the archive and manifest without writing")
    args = parser.parse_args()
    archive, manifest = generate(args.checkout.resolve(), args.artifacts.resolve())
    for path, data in ((ROOT / "Resources/libgit2-source.tar.gz", archive), (ROOT / "Licenses/libgit2-source.json", manifest)):
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                raise SystemExit(f"Outdated source delivery file: {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    print(f"{'Verified' if args.check else 'Packaged'} libgit2 source: {len(archive):,} bytes, SHA-256 {digest(archive)}")


if __name__ == "__main__":
    main()
