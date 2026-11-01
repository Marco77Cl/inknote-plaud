import Foundation
struct TransferError:LocalizedError {let message:String;var errorDescription:String?{message}}
@main struct CheckMeeting {
 @MainActor static func main() throws {
  var doc=TranscriptDocument(source:"会议测试.wav",model:"test",language:"zh",created:Date(),segments:[
   TranscriptSegment(id:0,startMS:0,endMS:5000,text:"今天讨论 InkNote 试用安排。我们决定先邀请五位同事试用，下周一开始。"),
   TranscriptSegment(id:1,startMS:5000,endMS:9000,text:"我叫小李，我负责在周五前整理试用说明。"),
   TranscriptSegment(id:2,startMS:9000,endMS:13000,text:"云端同步这次先不做，下一次会议再讨论。")])
  let old=try JSONDecoder().decode(TranscriptDocument.self,from:Data(#"{"source":"old.wav","model":"small","language":"zh","created":0,"segments":[{"id":0,"startMS":0,"endMS":1000,"text":"旧数据"}]}"#.utf8))
  precondition(old.summary==nil && old.segments[0].speaker==nil)
  doc.applySpeakers([SpeakerTurn(startMS:0,endMS:5000,speaker:1),SpeakerTurn(startMS:5000,endMS:9000,speaker:2),SpeakerTurn(startMS:9000,endMS:11000,speaker:1),SpeakerTurn(startMS:11000,endMS:13000,speaker:2)])
  precondition(doc.segments[0].speaker=="说话人 1" && doc.segments[2].speaker=="待确认")
  doc.segments[0].speaker="主持人";doc.segments[0].speakerManual=true;doc.applySpeakers([SpeakerTurn(startMS:0,endMS:13000,speaker:2)])
  precondition(doc.segments[0].speaker=="主持人")
  let points=try MeetingOutput.parse(Data(#"{"points":[{"kind":"action","text":"整理试用说明","sources":[1]}]}"#.utf8),validIDs:[0,1,2])
  doc.summary=MeetingSummary(created:Date(),model:"test",fingerprint:doc.fingerprint,points:points,chunkCount:1)
  precondition(!doc.summaryStale && doc.meetingMarkdown.contains("原文段落 2"))
  doc.segments[0].text+="补充";precondition(doc.summaryStale)
  do {_=try MeetingOutput.parse(Data(#"{"points":[{"kind":"key","text":"假引用","sources":[99]}]}"#.utf8),validIDs:[0,1,2]);fatalError("Invalid citation accepted")}catch is TransferError{}
  let categorized=try MeetingOutput.parse(Data(#"{"key_points":[],"decisions":[{"text":"试用决定","sources":[0]}],"actions":[{"text":"小李整理说明","sources":[1]}]}"#.utf8),validIDs:[0,1,2])
  precondition(categorized.map{$0.kind}==["decision","action"])
  let chunks=MeetingOutput.chunks(doc.segments,limit:20)
  precondition(chunks.flatMap{$0}.map{$0.text}.joined()==doc.segments.map{$0.text}.joined())
  try MeetingOutput.prompt(doc.segments).write(toFile:"/tmp/inknote-summary-prompt.txt",atomically:true,encoding:.utf8)
  print("PASS old JSON compatibility, speaker overlap, manual labels retained, stale summary, citation validation, complete chunk coverage")
 }
}
