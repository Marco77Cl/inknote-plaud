import Foundation
struct TransferError:LocalizedError {let message:String;var errorDescription:String?{message}}
@main struct CheckCancel {
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("InkNote-Cancel-Test-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:root)}
  let executable=root.appendingPathComponent("llama-completion")
  try "#!/bin/sh\nexec /bin/sleep 30\n".write(to:executable,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
  let worker=MeetingWorker(resourceDirectory:root)
  let doc=TranscriptDocument(source:"fixture.wav",model:"fixture",language:"zh",created:Date(),segments:[TranscriptSegment(id:0,startMS:0,endMS:1000,text:"测试取消")])
  let task=Task{try await worker.summarize(doc)}
  try await Task.sleep(nanoseconds:150_000_000)
  precondition(worker.active);worker.cancel()
  do{_=try await task.value;fatalError("Cancel did not throw")}catch is CancellationError{}
  precondition(!worker.active)
  print("PASS cancellation terminates subprocess and clears busy state without producing summary")
 }
}
