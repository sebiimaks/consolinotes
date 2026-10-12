#!/usr/bin/env python3
"""Verify shipped preview hashes and the pinned local Markdown parser source."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def verify(path, expected):
    actual = hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
    assert actual == expected, 'Dependency input changed without provenance: ' + path

web = json.loads((ROOT / 'Licenses/web/provenance.json').read_text())
verify(web['bundle_path'], web['bundle_sha256'])
for field in ['recipe', 'lockfile']:
    verify(web[field], web[field + '_sha256'])
verify('Vendor/Preview/entry.js', web['entry_sha256'])
for path, digest in web['assets'].items():
    verify(path, digest)
embedded = {item['name']: item for item in web['embedded_packages']}
assert set(embedded) == {'fastdom', 'js-yaml'}, 'Review embedded package inventory'
assert embedded['js-yaml']['shipped_version'] == '4.3.2'
assert embedded['fastdom']['shipped_version'] == '1.0.12'
components = json.loads((ROOT / 'Licenses/web/components.json').read_text())
for package in web['packages']:
    display = {'mermaid': 'Mermaid', 'mathjax': 'MathJax'}.get(package['name'], package['name'])
    component = next(item for item in components if item['name'] == display and item['version'] == package['version'])
    verify(component['file'], package['license_sha256'])
bundle = (ROOT / web['bundle_path']).read_text()
assert '3.4.16' in bundle and '3.4.12' not in bundle, 'Bundled DOMPurify must use the patched resolved package'
assert '0.18.2' in bundle and '0.16.47' not in bundle, 'Bundled KaTeX must use the patched resolved package'
cmark = json.loads((ROOT / 'Vendor/CMark/provenance.json').read_text())
for path, entry in cmark['files'].items():
    verify('Vendor/CMark/' + path, entry['sha256'])
for path, digest in cmark['generated_headers'].items():
    verify('Vendor/CMark/' + path, digest)
pins = json.loads((ROOT / 'FSNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
assert not any(pin['identity'] == 'libcmark_gfm' for pin in pins['pins']), 'Stale remote Markdown parser pin'
subprocess.run(['python3', 'scripts/generate-license-notices.py', '--check'], cwd=ROOT, check=True)
print('PASS: web bundles, lockfile, licences and vendored cmark source match pinned provenance')
