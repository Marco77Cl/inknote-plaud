import SwiftUI
import AppKit

struct TranscriptSegment: Codable, Identifiable {
    var id: Int
    var startMS: Int
    var endMS: Int
    var text: String
    var speaker: String? = nil
    var speakerManual: Bool? = nil
}
struct TranscriptDocument: Codable {
    var source: String
    var model: String
    var language: String
    var created: Date
    var segments: [TranscriptSegment]
    var speakerTurns: [SpeakerTurn]? = nil
    var summary: MeetingSummary? = nil
    var plainText: String { segments.map { ($0.speaker.map { "[\($0)] " } ?? "") + $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n") }
    static func stamp(_ ms: Int, srt: Bool = true) -> String {
        let n=max(0,ms)
        return String(format:"%02d:%02d:%02d%@%03d", n/3600000, (n/60000)%60, (n/1000)%60, srt ? "," : ".", n%1000)
    }
    var subtitles: String {
        segments.enumerated().map { i,s in "\(i+1)\n\(Self.stamp(s.startMS)) --> \(Self.stamp(s.endMS))\n\(s.speaker.map { "[\($0)] " } ?? "")\(s.text.trimmingCharacters(in:.whitespacesAndNewlines))\n" }.joined(separator:"\n")
    }
    static func decodeWhisper(_ data: Data, source: String, language: String) throws -> Self {
        struct Output: Decodable {
            struct Segment: Decodable { struct Offsets: Decodable { let from: Int; let to: Int }; let offsets: Offsets; let text: String }
            let transcription: [Segment]
        }
        let result=try JSONDecoder().decode(Output.self,from:data)
        let segments=result.transcription.enumerated().compactMap { i,s -> TranscriptSegment? in
            let text=s.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !text.isEmpty else{return nil}
            return TranscriptSegment(id:i,startMS:max(0,s.offsets.from),endMS:max(s.offsets.from,s.offsets.to),text:text)
        }
        guard !segments.isEmpty else {throw TransferError(message:"未识别到可用文字。请试听录音，确认有清晰讲话。")}
        return Self(source:source,model:"Whisper small multilingual / whisper.cpp 1.8.7",language:language,created:Date(),segments:segments)
    }
}

@MainActor final class Transcriber: ObservableObject {
    @Published var document: TranscriptDocument?
    @Published var active=false
    @Published var status="所有转写均在本机完成，音频不会上传。"
    @Published var language="zh"
    @Published var progress: Double=0
    @Published var source: URL?
    @Published var presenting=false
    @Published var dirty=false
    private var process: Process?
    private var cancelled=false
    private var timer: Timer?
    var resources: URL { Bundle.main.resourceURL!.appendingPathComponent("Speech") }
    var ready: Bool { FileManager.default.isExecutableFile(atPath:resources.appendingPathComponent("whisper-cli").path) && FileManager.default.fileExists(atPath:resources.appendingPathComponent("ggml-small.bin").path) }
    var documentURL: URL? {source?.appendingPathExtension("inknote.json")}
    func open(_ url: URL) {
        guard !active else {presenting=true;return}
        guard save() else {presenting=true;return}
        source=url;document=nil;dirty=false;progress=0;presenting=true
        if let path=documentURL,FileManager.default.fileExists(atPath:path.path) {
            do {document=try JSONDecoder().decode(TranscriptDocument.self,from:Data(contentsOf:path));status="已打开保存的文字，可编辑后导出。"}
            catch {status="已有文字文件无法读取，已保留原文件：\(error.localizedDescription)"}
        } else {status="准备转写 \(url.lastPathComponent)。请选择语言并开始。"}
    }
    @discardableResult func save() -> Bool {
        guard dirty,let document=document,let url=documentURL else{return true}
        do {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(document).write(to:url,options:.atomic);dirty=false;status="文字已保存。";return true}
        catch {status="保存失败：\(error.localizedDescription)";return false}
    }
    func start() {
        guard !active,document==nil,let source=source else{return}
        if let path=documentURL,FileManager.default.fileExists(atPath:path.path){status="已有文字文件无法读取，请先在 Finder 中备份或重命名该文件再重试。";return}
        guard ready else {status="本地转写引擎或模型缺失，请重新安装完整 InkNote Studio。";return}
        let run=FileManager.default.temporaryDirectory.appendingPathComponent("InkNote-ASR-\(UUID().uuidString)",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
            let log=run.appendingPathComponent("engine.log"),output=run.appendingPathComponent("result")
            guard FileManager.default.createFile(atPath:log.path,contents:nil) else {throw TransferError(message:"无法创建转写日志。")}
            let handle=try FileHandle(forWritingTo:log)
            let task=Process();task.executableURL=resources.appendingPathComponent("whisper-cli")
            task.arguments=["-m",resources.appendingPathComponent("ggml-small.bin").path,"-f",source.path,"-l",language,"-oj","-of",output.path,"-pp","-t","4","-ng","-ml","48","-sow"]
            task.standardOutput=handle;task.standardError=handle
            let selectedLanguage=language
            task.terminationHandler={ [weak self] task in
                try? handle.close()
                Task { @MainActor in self?.finished(code:task.terminationStatus,run:run,source:source,language:selectedLanguage) }
            }
            cancelled=false;progress=0;active=true;process=task;status="正在本地转写，首次加载模型可能需要片刻…"
            do {try task.run()} catch {try? handle.close();throw error}
            timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
                Task { @MainActor in
                    guard let self=self,self.active,let text=try? String(contentsOf:log,encoding:.utf8) else{return}
                    if let match=text.range(of:"progress = [0-9]+%",options:.regularExpression,range:nil,locale:nil) {
                        let matches=text.components(separatedBy:"progress = ").dropFirst()
                        if let last=matches.last,let n=Double(last.prefix(while:{$0.isNumber})) {self.progress=min(1,n/100);self.status="正在本地转写 · \(Int(n))%"}
                        _=match
                    }
                }
            }
        } catch {active=false;process=nil;status="无法启动转写：\(error.localizedDescription)";try? FileManager.default.removeItem(at:run)}
    }
    private func finished(code:Int32,run:URL,source:URL,language:String) {
        timer?.invalidate();timer=nil;process=nil;active=false
        defer {try? FileManager.default.removeItem(at:run)}
        if cancelled {status="已取消转写，原始录音保留。";return}
        guard code==0 else {status="转写失败（引擎代码 \(code)）。请确认录音为有效 WAV，并重新尝试。";return}
        do {
            document=try TranscriptDocument.decodeWhisper(Data(contentsOf:run.appendingPathComponent("result.json")),source:source.lastPathComponent,language:language)
            dirty=true;progress=1
            if save(){status="转写完成并保存。请核对人名、数字和专业词汇；可直接编辑各段文字。"}
        } catch {status="读取转写结果失败：\(error.localizedDescription)"}
    }
    func cancel(){guard active else{return};cancelled=true;status="正在取消…";process?.terminate()}
    func export(srt:Bool) {
        guard let document=document,save() else{return}
        let panel=NSSavePanel();panel.nameFieldStringValue=(source?.deletingPathExtension().lastPathComponent ?? "转写")+(srt ? ".srt" : ".txt")
        if panel.runModal() == .OK,let url=panel.url {
            do {try (srt ? document.subtitles : document.plainText).write(to:url,atomically:true,encoding:.utf8);status="已导出 \(url.lastPathComponent)"}
            catch {status="导出失败：\(error.localizedDescription)"}
        }
    }
}

struct TranscriptView: View {
    @ObservedObject var engine: Transcriber
    @StateObject var meeting=MeetingWorker()
    @State private var speakerCount=0
    @State private var page=0
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {VStack(alignment:.leading){Text("本地转文字").font(.title.bold());Text(engine.source?.lastPathComponent ?? "").font(.caption).foregroundStyle(.secondary)};Spacer();Button("关闭"){if engine.save(){engine.presenting=false}}.disabled(meeting.active)}
            HStack {
                Picker("录音语言",selection:$engine.language){Text("中文").tag("zh");Text("自动识别").tag("auto");Text("英语").tag("en")}.frame(width:210).disabled(engine.active || engine.document != nil)
                if engine.active {Button("取消转写"){engine.cancel()}}
                else if engine.document==nil {Button("开始转写"){engine.start()}.buttonStyle(.borderedProminent).disabled(!engine.ready)}
                Spacer();Text("离线处理 · 音频不上传").font(.caption).foregroundStyle(.secondary)
            }
            if engine.active {ProgressView(value:engine.progress)}
            Text(engine.status).font(.callout).textSelection(.enabled)
            if let document=engine.document {
                HStack {
                    Picker("人数",selection:$speakerCount){Text("自动估计（试验）").tag(0);ForEach(1..<9){n in Text("\(n) 人").tag(n)}}.frame(width:150)
                    Button("区分说话人") {Task { guard let audio=engine.source else{return};do{let turns=try await meeting.speakers(audio:audio,count:speakerCount);engine.document?.applySpeakers(turns);engine.dirty=true;if engine.save(){engine.status="说话人区分完成。标签仅为声音分组，可手动修正；混合段落标为待确认。"}}catch{engine.status=error is CancellationError ? "已取消说话人区分。" : error.localizedDescription}}}
                    Button(document.summary == nil ? "生成会议纪要" : "重新生成纪要") {Task {do{let summary=try await meeting.summarize(document);engine.document?.summary=summary;engine.dirty=true;if engine.save(){engine.status="会议纪要已生成并保存，请核对引用原文。";page=1}}catch{engine.status=error is CancellationError ? "已取消纪要生成。" : error.localizedDescription}}}
                }.disabled(meeting.active || !meeting.ready)
                if meeting.active {HStack{ProgressView().controlSize(.small);Text(meeting.status);Spacer();Button("取消处理"){meeting.cancel()}}}
                Picker("内容",selection:$page){Text("文字与说话人").tag(0);Text("会议纪要").tag(1)}.pickerStyle(.segmented)
                if page==0 {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:16) {
                        ForEach(document.segments.indices,id:\.self){index in
                            VStack(alignment:.leading,spacing:5){
                                HStack {Text("[\(document.segments[index].id+1)] \(TranscriptDocument.stamp(document.segments[index].startMS,srt:false))").font(.caption.monospaced()).foregroundStyle(.secondary)
                                TextField("说话人（可编辑）",text:Binding(get:{engine.document?.segments[index].speaker ?? ""},set:{guard $0 != (engine.document?.segments[index].speaker ?? "") else{return};engine.document?.segments[index].speaker=$0.isEmpty ? nil : $0;engine.document?.segments[index].speakerManual=true;engine.dirty=true})).frame(width:180);Button("自动"){engine.document?.segments[index].speakerManual=false;if let turns=engine.document?.speakerTurns{engine.document?.applySpeakers(turns)};engine.dirty=true}.disabled(engine.document?.speakerTurns==nil)}
                                TextEditor(text:Binding(get:{engine.document?.segments[index].text ?? ""},set:{engine.document?.segments[index].text=$0;engine.dirty=true})).font(.body).frame(minHeight:65).border(Color.secondary.opacity(0.2))
                            }
                        }
                    }.padding(4)
                    if let turns=document.speakerTurns {DisclosureGroup("声音分段 · \(Set(turns.map{$0.speaker}).count) 位说话人（自动标签）") {ForEach(turns){t in Text("\(TranscriptDocument.stamp(t.startMS,srt:false))–\(TranscriptDocument.stamp(t.endMS,srt:false))  说话人 \(t.speaker)").font(.caption.monospaced()).frame(maxWidth:.infinity,alignment:.leading)}}.padding(4)}
                }.disabled(meeting.active)
                } else {MeetingSummaryView(engine:engine).disabled(meeting.active)}
                HStack {Text("\(document.segments.count) 段 · \(engine.dirty ? "有未保存修改" : "已保存")").font(.caption);Spacer();Button("保存修改"){engine.save()}.disabled(!engine.dirty);Button("导出 TXT"){engine.export(srt:false)};Button("导出 SRT"){engine.export(srt:true)}}.disabled(meeting.active)
            } else {Spacer();Text(engine.ready ? "开始后会显示带时间码的文字，可编辑和导出。" : "转写模型尚未安装完整。").foregroundStyle(.secondary);Spacer()}
        }.padding(24).frame(minWidth:820,minHeight:680).interactiveDismissDisabled()
    }
}
