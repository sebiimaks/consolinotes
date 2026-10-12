#!/usr/bin/env python3
"""Exercise the production structured clipboard codec and ownership cleanup in AppKit."""
from pathlib import Path
import subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'FSNotesCore/Extensions/NSMutableAttributedString+.swift').read_text()
a=source.index('    public func unloadTasks()'); b=source.index('\n    public func loadTasks()',a)
helper='import Cocoa\nextension NSMutableAttributedString {\n'+source[a:b]+'\n}\n'
fixture=r'''
import Cocoa
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally() }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let file = root.appendingPathComponent("私的 100%.png")
let bytes = Data([1,2,3,4])
try bytes.write(to: file)
let content = NSMutableAttributedString(string: "private ")
let attachment = NSAttributedString(attachment: NSTextAttachment())
content.append(attachment)
content.addAttributes([.attachmentUrl:file, .attachmentTitle:"private", .attachmentPath:"i/private.png"], range:NSRange(location:8,length:1))
let task = NSMutableAttributedString(attachment: NSTextAttachment())
task.addAttribute(.todo, value:1, range:NSRange(location:0,length:1))
content.append(task)
let encoded = NotePasteboardCodec.encode(content)!
let decoded = NotePasteboardCodec.decode(encoded)!
expect(decoded.string == "private \u{fffc}- [x]", "Task/attachment round trip changed text")
expect(decoded.attribute(.attachmentSave,at:8,effectiveRange:nil) as? Data == bytes,"Embedded attachment bytes lost")
expect((decoded.attribute(.attachmentUrl,at:8,effectiveRange:nil) as? URL)?.lastPathComponent == file.lastPathComponent,"Filename lost")
expect(!(String(data:encoded,encoding:.utf8)!.contains(root.path)),"Clipboard exposed source path")
let memoryContent = NSMutableAttributedString(attributedString: content)
memoryContent.addAttributes([.attachmentUrl: URL(string:"consolinotes-memory://synthetic/assets/memory.png")!, .attachmentMemoryData: bytes], range:NSRange(location:8,length:1))
let memoryEncoded = NotePasteboardCodec.encode(memoryContent)!
let memoryDecoded = NotePasteboardCodec.decode(memoryEncoded)!
expect(memoryDecoded.attribute(.attachmentSave,at:8,effectiveRange:nil) as? Data == bytes,"Memory attachment bytes lost")
expect(!String(data:memoryEncoded,encoding:.utf8)!.contains("consolinotes-memory"),"Clipboard exposed memory capability")
let badNames=["../private", "/etc/passwd", "..", "a\\b", "a\u{0}b"]
for name in badNames {
 let payload=NotePasteboardCodec.Payload(version:1,text:"\u{fffc}",attachments:[.init(location:0,filename:name,title:"",data:bytes)])
 expect(NotePasteboardCodec.decode(try! JSONEncoder().encode(payload)) == nil,"Unsafe filename accepted")
}
for location in [-1,1,Int.max] {
 let payload=NotePasteboardCodec.Payload(version:1,text:"\u{fffc}",attachments:[.init(location:location,filename:"a",title:"",data:bytes)])
 expect(NotePasteboardCodec.decode(try! JSONEncoder().encode(payload)) == nil,"Invalid location accepted")
}
let duplicate=NotePasteboardCodec.Attachment(location:0,filename:"a",title:"",data:bytes)
expect(NotePasteboardCodec.decode(try! JSONEncoder().encode(NotePasteboardCodec.Payload(version:1,text:"\u{fffc}",attachments:[duplicate,duplicate]))) == nil,"Duplicate attachment accepted")
let oldArchive=try NSKeyedArchiver.archivedData(withRootObject:NSAttributedString(string:"legacy"),requiringSecureCoding:false)
expect(NotePasteboardCodec.decode(oldArchive) == nil,"Legacy object archive decoded")
expect(NotePasteboardCodec.decode(Data(repeating:0,count:NotePasteboardCodec.maximumBytes+1)) == nil,"Oversize clipboard accepted")
SensitiveClipboard.writeString("secret",to:board)
expect(board.string(forType:.string)=="secret","Copy failed")
expect(board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))==true,"Privacy marker missing")
SensitiveClipboard.clearOwned()
expect(board.string(forType:.string)==nil,"Owned clipboard survived lock")
SensitiveClipboard.writeString("secret",to:board)
board.clearContents(); board.setString("newer user copy",forType:.string)
SensitiveClipboard.clearOwned()
expect(board.string(forType:.string)=="newer user copy","Cleanup erased unrelated copy")
SensitiveClipboard.writeString("expires",to:board,expiresAfter:0.02)
RunLoop.main.run(until:Date().addingTimeInterval(0.06))
expect(board.string(forType:.string)==nil,"Clipboard timer did not expire")
SensitiveClipboard.write(content,plainText:"private attachment",to:board)
expect(NotePasteboardCodec.decode(board.data(forType:NSPasteboard.attributed)!) != nil,"Rich copy failed")
SensitiveClipboard.clearOwned()
print("Verified bounded clipboard format, attachments/tasks, invalid ranges/names/archives, privacy markers and ownership cleanup.")
'''
with tempfile.TemporaryDirectory(prefix='consolinotes-private-clipboard-') as temp:
 work=Path(temp); (work/'main.swift').write_text(fixture); (work/'Tasks.swift').write_text(helper)
 command=['xcrun','swiftc','-module-cache-path',str(work/'modules'),str(ROOT/'FSNotesCore/Extensions/NSAttributedStringKey+.swift'),str(ROOT/'FSNotesCore/Extensions/Pasteboard.swift'),str(work/'Tasks.swift'),str(work/'main.swift'),'-o',str(work/'tests')]
 subprocess.run(command,check=True)
 subprocess.run([str(work/'tests'),str(work)],check=True)
# Plain paste must not enter rich decoding or fall back to ordinary paste.
editor=(ROOT/'FSNotes/View/EditTextView.swift').read_text()
plain=editor[editor.index('    override func pasteAsPlainText('):editor.index('    override func cut(')]
assert 'NotePasteboardCodec.decode' not in plain and 'paste(sender)' not in plain
for path in ['FSNotes/View/EditTextView.swift','FSNotes/View/EditTextView+DragOperation.swift']:
 assert 'unarchiveTopLevelObjectWithData' not in (ROOT/path).read_text()
assert 'NSPasteboard(name: .find)' not in (ROOT/'FSNotes/View/MPreviewContainerView.swift').read_text()
