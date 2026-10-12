#!/usr/bin/env python3
"""Download and validate the exact sources recorded for the FIDO2 libraries."""
from pathlib import Path
import hashlib,json,tarfile,urllib.request
ROOT=Path(__file__).resolve().parents[1]
base=ROOT/'build/fido-sources';base.mkdir(parents=True,exist_ok=True)
for source in json.loads((ROOT/'Vendor/FIDO2/provenance.json').read_text())['sources']:
    archive=base/(source['name']+'.tar.gz')
    if not archive.exists(): urllib.request.urlretrieve(source['url'],archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=source['sha256']: raise ValueError('Source hash mismatch: '+source['name'])
    if not (base/source['directory']).exists():
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                target=(base/member.name).resolve()
                if not target.is_relative_to(base.resolve()) or not (member.isdir() or member.isfile()): raise ValueError('Unsafe archive member: '+member.name)
            tar.extractall(base)
    print('Verified source:',source['name'],source['version'])
