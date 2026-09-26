#!/usr/bin/env python3
"""Verify checked-in license inputs, Xcode resource membership and built apps."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
NOTICES = {"LICENSE": ROOT / "LICENSE", "THIRD_PARTY_NOTICES.md": ROOT / "THIRD_PARTY_NOTICES.md"}
SOURCES = {"SOURCE_CODE.md": ROOT / "SOURCE_CODE.md", "libgit2-source.tar.gz": ROOT / "Resources/libgit2-source.tar.gz"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_project():
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(ROOT / "FSNotes.xcodeproj/project.pbxproj")
    ]))
    objects = project["objects"]
    targets = [obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget"]
    if {target["name"] for target in targets} != {"FSNotes"}:
        raise ValueError("Expected only the macOS application target")
    for target in targets:
        resources = []
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            if phase.get("isa") == "PBXResourcesBuildPhase":
                for file_id in phase["files"]:
                    resource = objects[objects[file_id]["fileRef"]]
                    # Localized storyboards are PBXVariantGroups with a name,
                    # rather than a single file-reference path.
                    resources.append(resource.get("path", resource.get("name", "")))
        names = [Path(path).name for path in resources]
        required = set(NOTICES)
        if target["productType"] == "com.apple.product-type.application":
            required.update(SOURCES)
            required.add("MPreview.bundle")
        for name in required:
            if names.count(name) != 1:
                raise ValueError(f'{target["name"]}: expected exactly one resource {name}')
        if any("Avenir" in path for path in resources):
            raise ValueError(f'{target["name"]}: restricted Avenir font resource remains')
        print(f'Verified Xcode resources: {target["name"]}')


def check_app(app):
    resources = app / "Contents/Resources"
    if not resources.is_dir():
        raise ValueError(f"{app}: expected a macOS application bundle")
    expected = dict(NOTICES)
    expected.update(SOURCES)
    for name, original in NOTICES.items():
        expected["MPreview.bundle/" + name] = original
    expected["MPreview.bundle/index.html"] = ROOT / "Resources/MPreview.bundle/index.html"
    for name, original in expected.items():
        packaged = resources / name
        if not packaged.is_file() or digest(packaged) != digest(original):
            raise ValueError(f"{app}: missing or stale {name}")
    for font_license in (ROOT / "Resources/MPreview.bundle/fonts").glob("*-OFL.txt"):
        packaged = resources / "MPreview.bundle/fonts" / font_license.name
        if not packaged.is_file() or digest(packaged) != digest(font_license):
            raise ValueError(f"{app}: missing or stale {font_license.name}")
    if any("Avenir" in path.name for path in resources.rglob("*")):
        raise ValueError(f"{app}: Avenir font remains in built app")
    print(f"Verified packaged licenses and source archive: {app}")


def check_tracked():
    paths = [ROOT / "LICENSE", ROOT / "THIRD_PARTY_NOTICES.md", *SOURCES.values()]
    for directory in ("Licenses", "scripts", "Resources/Fonts", "Resources/MPreview.bundle"):
        paths += [path for path in (ROOT / directory).rglob("*") if path.is_file() and "__pycache__" not in path.parts]
    tracked = set(subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0"))
    missing = sorted({str(path.relative_to(ROOT)) for path in paths} - tracked)
    if missing:
        raise ValueError("Release inputs are not tracked by Git:\n" + "\n".join(missing))
    print("Verified license and font inputs are tracked by Git.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", action="append", type=Path, default=[], help="Verify a built .app; can be repeated.")
    parser.add_argument("--require-tracked", action="store_true", help="Also reject untracked release inputs.")
    args = parser.parse_args()
    try:
        subprocess.run([sys.executable, str(ROOT / "scripts/generate-license-notices.py"), "--check"], check=True)
        subprocess.run([sys.executable, str(ROOT / "scripts/package-libgit2-source.py"), "--check"], check=True)
        check_project()
        for app in args.app:
            check_app(app.resolve())
        if args.require_tracked:
            check_tracked()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"License distribution check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
