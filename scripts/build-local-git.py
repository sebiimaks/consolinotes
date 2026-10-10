#!/usr/bin/env python3
"""Build the pinned local-only libgit2 XCFramework from source, without networking.

Requires Xcode and CMake 3.31.10. Set CMAKE to the executable if not on PATH.
The source-delivery archive also carries this standalone recipe.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.9.7"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, **kwargs):
    subprocess.run([str(value) for value in args], check=True, **kwargs)


def source_build_inputs_hash(source):
    """Bind provenance to exact, unpatched production input paths and bytes."""
    digest = hashlib.sha256()
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if len(relative.parts) > 1 and relative.parts[0] not in {"src", "include", "cmake", "deps"}:
            continue
        if path.is_symlink():
            raise SystemExit("Symlinks are not allowed in native production build inputs")
        if path.is_file():
            data = path.read_bytes()
            digest.update(relative.as_posix().encode() + b"\0" + len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, help="Unmodified libgit2 source (standalone archive rebuild)")
    parser.add_argument("--patch", type=Path, help="Local-only source patch for a standalone rebuild")
    parser.add_argument("--output", type=Path, default=ROOT / "Vendor/LocalGit2/libgit2.xcframework")
    parser.add_argument("--manifest", type=Path, help="Write build provenance and per-file hashes here")
    args = parser.parse_args()
    cmake = os.environ.get("CMAKE") or shutil.which("cmake")
    bundled_tool = ROOT / "build/tools/cmake/data/bin/cmake"
    if not cmake and bundled_tool.is_file():
        cmake = str(bundled_tool)
    if not cmake:
        raise SystemExit("Install CMake 3.31.10 or set CMAKE to its executable; no build tool is downloaded automatically.")
    cmake_version = subprocess.check_output([cmake, "--version"], text=True).splitlines()[0]
    if cmake_version != "cmake version 3.31.10":
        raise SystemExit("Use CMake 3.31.10 for the pinned build recipe.")
    if args.output.exists():
        raise SystemExit("Output already exists; choose a new --output path for a safe rebuild/comparison.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="consolinotes-libgit2-") as tmp:
        work = Path(tmp)
        source = work / "libgit2"
        if args.source_dir:
            if not args.patch:
                raise SystemExit("--source-dir requires --patch")
            shutil.copytree(args.source_dir, source, symlinks=True)
            patch = args.patch.resolve()
        else:
            archive = ROOT / "Resources/libgit2-source.tar.gz"
            manifest = json.loads((ROOT / "Licenses/libgit2-source.json").read_text())
            if sha256(archive) != manifest["archive_sha256"]:
                raise SystemExit("Source archive checksum mismatch")
            # Only extract build inputs; the complete archive includes test fixture
            # symlinks that are irrelevant to this production library build.
            with tarfile.open(archive, "r:gz") as package:
                for member in package:
                    parts = Path(member.name).parts
                    if not parts or parts[0] != "libgit2-source" or ".." in parts:
                        raise SystemExit("Unexpected source archive path")
                    relative = Path(*parts[1:])
                    selected = (relative == Path("local-only.patch") or
                                (len(relative.parts) > 1 and relative.parts[0] == "libgit2" and
                                 (relative.parts[1] in {"src", "include", "cmake", "deps"} or len(relative.parts) == 2)))
                    if not selected or member.isdir():
                        continue
                    if not member.isfile():
                        raise SystemExit("Unexpected non-regular build input")
                    destination = work / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(package.extractfile(member).read())
            patch = work / "local-only.patch"
        version_header = (source / "include/git2/version.h").read_text()
        if not re.search(r'^#define LIBGIT2_VERSION\s+"' + re.escape(VERSION) + '"$', version_header, re.MULTILINE):
            raise SystemExit("Unexpected libgit2 source version")
        source_hash = source_build_inputs_hash(source)
        run(["/usr/bin/patch", "-p1", "--batch", "--forward", "-i", patch], cwd=source)
        env = dict(os.environ, ZERO_AR_DATE="1")
        for key in list(env):
            if key.startswith("CMAKE_") or key in {
                "CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LD", "AR", "RANLIB",
                "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "CPATH", "C_INCLUDE_PATH", "LIBRARY_PATH",
                "PKG_CONFIG_PATH", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH"
            }:
                del env[key]
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        compiler = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
        options = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=12.4",
                   "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTS=OFF", "-DBUILD_CLI=OFF",
                   "-DUSE_SSH=OFF", "-DUSE_HTTPS=OFF", "-DUSE_GSSAPI=OFF", "-DUSE_NTLMCLIENT=OFF",
                   "-DUSE_SHA1=CollisionDetection", "-DUSE_SHA256=Builtin", "-DREGEX_BACKEND=regcomp",
                   "-DUSE_BUNDLED_ZLIB=OFF", "-DENABLE_REPRODUCIBLE_BUILDS=OFF",
                   "-DCMAKE_C_COMPILER=" + compiler, "-DCMAKE_TOOLCHAIN_FILE=", "-DCMAKE_C_COMPILER_LAUNCHER=",
                   "-DCMAKE_MAKE_PROGRAM=/usr/bin/make",
                   "-DCMAKE_OSX_SYSROOT=" + sdk,
                   "-DCMAKE_C_FLAGS=-ffile-prefix-map=" + str(work) + "=/consolinotes-libgit2"]
        libraries = []
        for arch in ("arm64", "x86_64"):
            build = work / arch
            run([cmake, "-S", source, "-B", build, "-DCMAKE_OSX_ARCHITECTURES=" + arch, *options], env=env)
            run([cmake, "--build", build, "--parallel", "8"], env=env)
            library = build / "libgit2.a"
            symbols = subprocess.check_output(["xcrun", "nm", "-u", library], text=True)
            if re.search(r"(?m)^_(?:libssh2_|SSL_|OPENSSL_|EVP_|socket$|connect$|getaddrinfo$|send$|recv$)", symbols):
                raise SystemExit("Network or legacy crypto linkage unexpectedly remains")
            libraries.append(library)
        combined = work / "libgit2.a"
        run(["xcrun", "lipo", "-create", *libraries, "-output", combined])
        run(["xcodebuild", "-create-xcframework", "-library", combined,
             "-headers", work / "arm64/include", "-output", args.output.resolve()])
        provenance = {
            "libgit2_version": VERSION,
            "architectures": ["arm64", "x86_64"], "minimum_macos": "12.4",
            "cmake": cmake_version,
            "compiler": subprocess.check_output([compiler, "--version"], text=True).splitlines()[0],
            "compiler_path": compiler,
            "source_build_inputs_sha256": source_hash,
            "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
            "sdk_version": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip(),
            "options": [value for value in options if not value.startswith(("-DCMAKE_C_FLAGS=", "-DCMAKE_OSX_SYSROOT="))],
            "archive_timestamps": "ZERO_AR_DATE=1 (Apple ar/ranlib)",
            "source_paths": "-ffile-prefix-map=<temporary build root>=/consolinotes-libgit2",
            "patch_sha256": sha256(patch),
            "files": {str(path.relative_to(args.output)): sha256(path)
                      for path in sorted(args.output.rglob("*")) if path.is_file()}
        }
        if args.manifest:
            args.manifest.write_text(json.dumps(provenance, indent=2) + "\n")
        print("Built local-only libgit2 " + VERSION + " for arm64 and x86_64: " + str(args.output))


if __name__ == "__main__":
    main()
