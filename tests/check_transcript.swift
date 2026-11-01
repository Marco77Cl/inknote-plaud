import Foundation
struct TransferError: LocalizedError {let message:String;var errorDescription:String?{message}}
@main struct CheckTranscript {
    @MainActor static func main() throws {
        let fixture=Data(#"{"transcription":[{"offsets":{"from":1234,"to":4567},"text":" 你好，InkNote。 "},{"offsets":{"from":4567,"to":5000},"text":" "}]}"#.utf8)
        var document=try TranscriptDocument.decodeWhisper(fixture,source:"test.wav",language:"zh")
        precondition(document.segments.count==1)
        precondition(document.subtitles=="1\n00:00:01,234 --> 00:00:04,567\n你好，InkNote。\n")
        precondition(TranscriptDocument.stamp(3600001)=="01:00:00,001")
        document.segments[0].text="修改后的文字"
        let decoded=try JSONDecoder().decode(TranscriptDocument.self,from:JSONEncoder().encode(document))
        precondition(decoded.plainText=="修改后的文字" && decoded.subtitles.contains("修改后的文字"))
        do {_=try TranscriptDocument.decodeWhisper(Data(#"{"transcription":[]}"#.utf8),source:"silent.wav",language:"zh");fatalError("Empty transcript accepted")} catch is TransferError {}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let audio=root.appendingPathComponent("test.wav")
        let model=Transcriber();model.open(audio);model.document=document;model.dirty=true
        precondition(model.save())
        let reopened=Transcriber();reopened.open(audio)
        precondition(reopened.document?.plainText=="修改后的文字" && !reopened.dirty)
        let broken=root.appendingPathComponent("broken.wav")
        try Data("broken preserved".utf8).write(to:broken.appendingPathExtension("inknote.json"))
        reopened.open(broken);reopened.start()
        precondition(!reopened.active)
        let preserved=try String(contentsOf:broken.appendingPathExtension("inknote.json"),encoding:.utf8)
        precondition(preserved=="broken preserved")
        print("PASS timestamp/SRT, edited JSON roundtrip, empty results, save/reopen, preserve unreadable transcript")
    }
}
