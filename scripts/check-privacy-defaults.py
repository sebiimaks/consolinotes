#!/usr/bin/env python3
"""Check session-only search history and redacted, bounded diagnostics."""
from pathlib import Path
import subprocess, tempfile, re
ROOT = Path(__file__).resolve().parents[1]
source=(ROOT/'FSNotesCore/UserDefaultsManagement.swift').read_text()
a=source.index('    private static var sessionRecentSearches:');b=source.index('    static var searchHighlight:',a)
fixture='''import Foundation
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
enum UserDefaultsManagement {
 static let shared: UserDefaults? = UserDefaults(suiteName: "consolinotes-privacy-test-" + UUID().uuidString)
 enum Constants { static let RecentSearches = "recentSearches" }
'''+source[a:b]+'''}
let defaults=UserDefaultsManagement.shared!
defaults.set(["old private query"],forKey:"recentSearches")
expect(UserDefaultsManagement.recentSearches == nil,"Persisted search leaked into session")
expect(defaults.object(forKey:"recentSearches") == nil,"Old search history remains on disk")
UserDefaultsManagement.recentSearches=["session-only query"]
expect(UserDefaultsManagement.recentSearches == ["session-only query"],"Session recents lost")
expect(defaults.object(forKey:"recentSearches") == nil,"New search history persisted")
UserDefaultsManagement.recentSearches=nil
expect(UserDefaultsManagement.recentSearches == nil,"Lock failed to clear recents")
for _ in 0..<250 { PrivacyLog.record("synthetic.operation-failed") }
let log=PrivacyLog.snapshot()
expect(log.components(separatedBy:"synthetic.operation-failed").count == 201,"Diagnostics ring is not bounded")
expect(!log.contains("query"),"Search leaked into diagnostics")
print("Verified removal of persistent search history, session-only recents and bounded static diagnostics.")
'''
with tempfile.TemporaryDirectory(prefix='consolinotes-privacy-defaults-') as temp:
 p=Path(temp);(p/'main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-module-cache-path',str(p/'modules'),str(ROOT/'FSNotesCore/PrivacyLog.swift'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
for base in ['FSNotes','FSNotesCore']:
 for path in (ROOT/base).rglob('*.swift'):
  for line in path.read_text().splitlines():
   if re.match(r'^\s*(Swift\.)?(print|NSLog)\(',line):
    raise AssertionError(f'Unredacted logging in {path.relative_to(ROOT)}')
print('Verified application sources contain no direct stdout diagnostics.')
