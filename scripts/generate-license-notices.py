#!/usr/bin/env python3
"""Generate the app and web acknowledgements from checked-in license texts."""

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFESTS = ("Licenses/native/components.json", "Licenses/web/components.json")


def components():
    result = []
    for manifest in MANIFESTS:
        entries = json.loads((ROOT / manifest).read_text())
        for entry in entries:
            for field in ("name", "version", "license", "source", "file"):
                if not isinstance(entry.get(field), str) or not entry[field].strip():
                    raise ValueError(f"{manifest}: missing {field}: {entry}")
            source = (ROOT / entry["file"]).resolve()
            if not source.is_relative_to(ROOT / "Licenses"):
                raise ValueError(f"License file outside Licenses/: {source}")
            entry = dict(entry)
            entry["text"] = source.read_text().strip()
            if not entry["text"]:
                raise ValueError(f"Empty license: {source}")
            entry.setdefault("used_for", "Native app" if "/native/" in manifest else "Preview and web publishing")
            result.append(entry)
    return result


def generate():
    entries = components()
    base = (ROOT / "Licenses/BASE_NOTICES.md").read_text()
    # Native entries replace incomplete legacy sections; transitive web entries
    # can have several versions, each of which keeps its own full notice.
    replacing = {entry["name"] for entry in entries}
    preamble, body = base.split("## Licence texts\n", 1)
    sections = re.split(r"(?=^### )", body, flags=re.MULTILINE)
    sections = [section for section in sections if not any(
        section.startswith(f"### {name}\n") for name in replacing
    )]
    lines = preamble.splitlines()
    lines = [line for line in lines if not any(
        line.startswith(f"| [{name}](") for name in replacing
    )]
    while lines and not lines[-1].strip():
        lines.pop()
    for entry in entries:
        values = [f'[{entry["name"]}]({entry["source"]})', entry["version"], entry["license"], entry["used_for"]]
        lines.append("| " + " | ".join(value.replace("|", "\\|").replace("\n", " ") for value in values) + " |")
    notice = "\n".join(lines) + "\n\n## Licence texts\n" + "".join(sections).rstrip() + "\n"
    for entry in entries:
        notice += f'\n### {entry["name"]} ({entry["version"]})\n\n'
        notice += f'{entry["license"]}. Source: {entry["source"]}\n\n'
        if entry.get("notes"):
            notice += entry["notes"].strip() + "\n\n"
        notice += "````text\n" + entry["text"] + "\n````\n"
    license_text = (ROOT / "LICENSE").read_bytes()
    # Hosted publishing sends a standalone page without our sidecar files.
    # Preserve notices for inline FSNotes JavaScript and injected theme CSS.
    template_path = ROOT / "Resources/MPreview.bundle/index.html"
    template = template_path.read_text()
    start = "<!-- CONSOLINOTES-LICENSE-BEGIN\n"
    end = "\nCONSOLINOTES-LICENSE-END -->"
    mit_text = license_text.decode().split("\n---\n", 1)[0].strip()
    highlight = re.search(r"### highlight\.js\n.*?```text\n(.*?)\n```", base, re.DOTALL)
    if not highlight:
        raise ValueError("Missing highlight.js notice for standalone HTML")
    markdown_css = next(entry["text"] for entry in entries if entry["name"] == "github-markdown-css")
    inline_notices = mit_text + "\n\nhighlight.js theme CSS:\n" + highlight[1]
    inline_notices += "\n\ngithub-markdown-css:\n" + markdown_css
    if "--" in inline_notices:
        raise ValueError("Standalone page notices contain an invalid HTML comment sequence")
    comment = start + inline_notices + end
    if start in template:
        before, rest = template.split(start, 1)
        _, after = rest.split(end, 1)
        template = before + comment + after
    else:
        template = comment + "\n" + template
    return {
        ROOT / "THIRD_PARTY_NOTICES.md": notice.encode(),
        ROOT / "Resources/MPreview.bundle/THIRD_PARTY_NOTICES.md": notice.encode(),
        ROOT / "Resources/MPreview.bundle/LICENSE": license_text,
        template_path: template.encode(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if generated copies are absent or stale.")
    args = parser.parse_args()
    outputs = generate()
    stale = []
    for path, content in outputs.items():
        if not path.exists() or path.read_bytes() != content:
            stale.append(str(path.relative_to(ROOT)))
            if not args.check:
                path.write_bytes(content)
    if args.check and stale:
        print("Stale license outputs: " + ", ".join(stale), file=sys.stderr)
        print("Run python3 scripts/generate-license-notices.py", file=sys.stderr)
        return 1
    print(f"{'Verified' if args.check else 'Generated'} {len(outputs)} license outputs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
