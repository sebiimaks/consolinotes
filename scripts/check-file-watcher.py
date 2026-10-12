#!/usr/bin/env python3
"""Production FSEvents startup failures, release/retry, and copied-library events."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
FIXTURE=r'''
import Cocoa
import Darwin
func expect(_ test: @autoclosure () -> Bool,_ message:String) { if !test(){ fatalError(message) } }
let root = URL(fileURLWithPath: CommandLine.arguments[1],isDirectory:true)
var creations = 0
let empty = FileWatcher([], streams:.init(create:{_,_,_ in creations += 1; return nil},start:{_ in fatalError("empty stream started")}))
expect(!empty.start() && creations == 0,"Empty paths reached FSEvents")
empty.stop()
var failCreation = true
let retry = FileWatcher([root.path],streams:.init(create:{ callback,context,paths in
    if failCreation { return nil }
    return FileWatcher.Streams.system.create(callback,context,paths)
},start:FileWatcher.Streams.system.start))
expect(!retry.start(),"Creation failure not returned")
retry.stop(); failCreation = false
expect(retry.start(),"Retry after creation failure failed")
expect(retry.start(),"Start not idempotent")
retry.stop();retry.stop()
weak var released: FileWatcher?
do {
 let failing = FileWatcher([root.path],streams:.init(create:FileWatcher.Streams.system.create,start:{_ in false}))
 released = failing
 expect(!failing.start(),"Start failure not returned")
 failing.stop()
 expect(!failing.start(),"Failed stream retained as running")
}
expect(released == nil,"Failed stream retained its callback context")
weak var stopped: FileWatcher?
do {
 let watcher = FileWatcher([root.path])
 stopped = watcher
 expect(watcher.start(),"Real watch failed")
 watcher.stop()
}
expect(stopped == nil,"Stopped stream retained its callback context")
let source=root.appendingPathComponent("Source",isDirectory:true)
try FileManager.default.createDirectory(at:source,withIntermediateDirectories:false)
try Data("synthetic original".utf8).write(to:source.appendingPathComponent("note.md"))
let manager=PrivateLibraryManager(directory:root.appendingPathComponent("ConsolinotesLibraries.noindex",isDirectory:true))
for included in [false,true] {
 let library=try manager.copy(source:source,backupIncluded:included)
 expect(try library.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup == !included,"Backup preference lost")
 let marker=library.appendingPathComponent("new \(UUID().uuidString).md")
 var observed=false
 let watcher=FileWatcher([library.path,library.path]) { event in
   if URL(fileURLWithPath:event.path).standardizedFileURL == marker.standardizedFileURL { observed=true }
 }
 expect(watcher.filePaths.count == 1,"Watch roots not deduplicated")
 expect(watcher.start(),"Copied library monitoring failed")
 try Data("synthetic event".utf8).write(to:marker)
 let deadline=Date().addingTimeInterval(8)
 while !observed && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
 watcher.stop()
 expect(observed,"No event in copied private library")
}
expect(try String(contentsOf:source.appendingPathComponent("note.md")) == "synthetic original","Original changed")
print("PASS: empty/create/start failures, retries, callback release and actual events after copy with backup inclusion/exclusion")
'''
# Throwing expressions cannot be captured by a nonthrowing assertion autoclosure.
FIXTURE=FIXTURE.replace('expect(try library.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup == !included,','let excluded = try library.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup\n expect(excluded == !included,').replace('expect(try String(contentsOf:source.appendingPathComponent("note.md")) == "synthetic original",','let original = try String(contentsOf:source.appendingPathComponent("note.md"))\nexpect(original == "synthetic original",')
with tempfile.TemporaryDirectory(prefix='consolinotes-watcher-') as temp:
 work=Path(temp);(work/'main.swift').write_text(FIXTURE)
 subprocess.run(['swiftc','-module-cache-path',str(work/'modules'),str(ROOT/'FSNotes/Helpers/FileWatcher.swift'),str(ROOT/'FSNotes/Helpers/FileWatcherEvent.swift'),str(ROOT/'FSNotesCore/PrivateLibraryManager.swift'),str(work/'main.swift'),'-o',str(work/'test')],check=True)
 subprocess.run([str(work/'test'),str(work)],check=True,timeout=25)
