#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,re
ROOT=Path(__file__).resolve().parents[1]
provenance=json.loads((ROOT/'Vendor/FIDO2/provenance.json').read_text())
for name,digest in provenance['outputs'].items():
    path=ROOT/name
    assert hashlib.sha256(path.read_bytes()).hexdigest()==digest,name+' hash mismatch'
    arches=subprocess.check_output(['lipo','-archs',path],text=True).split()
    assert set(arches)=={'arm64','x86_64'},arches
assert not list((ROOT/'Vendor/FIDO2').rglob('*.dylib')),'Only static libraries permitted'
crypto=subprocess.check_output(['nm','-u',ROOT/'Vendor/FIDO2/lib/libcrypto.a'],text=True,stderr=subprocess.DEVNULL)
assert not re.search(r'(?m)^\s*_(?:socket|connect|dlopen|send|recv|getaddrinfo)$',crypto),'Crypto must not load modules or use sockets'
print('PASS: pinned universal FIDO2 libraries; no dynamic libraries or crypto network/module loading')
# Link the production C bridge for both targets; do not enumerate or touch keys.
import tempfile
with tempfile.TemporaryDirectory(prefix='consolinotes-fido-link-') as tmp:
    tmp=Path(tmp); main=tmp/'main.c';main.write_text('int main(void) { return 0; }\n')
    for arch in provenance['architectures']:
        subprocess.run(['xcrun','clang','-arch',arch,'-mmacosx-version-min=12.4','-I'+str(ROOT/'Vendor/FIDO2/include'),str(main),str(ROOT/'FSNotesCore/FIDO2/FIDO2Bridge.c'),*[str(ROOT/'Vendor/FIDO2/lib'/name) for name in ['libfido2.a','libcbor.a','libcrypto.a']],'-framework','IOKit','-framework','CoreFoundation','-framework','Security','-lz','-o',str(tmp/arch)],check=True)
        deps=subprocess.check_output(['otool','-L',tmp/arch],text=True)
        assert '/opt/homebrew' not in deps and '.dylib' not in deps.replace('/usr/lib/libSystem.B.dylib','').replace('/usr/lib/libz.1.dylib',''),deps
print('PASS: production FIDO2 bridge links for both Mac architectures using only system dynamic dependencies')
