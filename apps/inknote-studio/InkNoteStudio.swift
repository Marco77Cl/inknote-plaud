import SwiftUI
import AppKit
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

struct Recording: Codable, Identifiable, Hashable {
    let name: String
    let size: Int64
    let duration: Double
    var id: String { name }
    var time: String { String(format: "%02d:%02d", Int(duration)/60, Int(duration)%60) }
}
struct Listing: Decodable { let files: [Recording]; let next: Int? }
struct PairReply: Decodable { let token: String; let device: String; let api: Int }
struct TransferError: LocalizedError { let message: String; var errorDescription: String? { message } }
func sha256(_ url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
    var digest = SHA256()
    while let data = try h.read(upToCount: 1024*1024), !data.isEmpty { digest.update(data: data) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
// The delegate writes incrementally. Interrupted transfers leave a resumable .part file.
final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var session: URLSession!
    var continuation: CheckedContinuation<String, Error>?
    var handle: FileHandle?
    var failure: Error?
    var expectedHash = ""
    var received: Int64 = 0
    let offset: Int64, expected: Int64, part: URL
    let progress: (Double) -> Void
    init(part: URL, offset: Int64, expected: Int64, progress: @escaping (Double) -> Void) {
        self.part=part; self.offset=offset; self.expected=expected; self.progress=progress
    }
    func run(_ request: URLRequest) async throws -> String {
        try await withCheckedThrowingContinuation { c in
            continuation=c
            let cfg=URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest=300; cfg.timeoutIntervalForResource=3600
            session=URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session.dataTask(with: request).resume()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let r=response as? HTTPURLResponse, r.statusCode == (offset > 0 ? 206 : 200) else { throw TransferError(message: "下载被拒绝，请检查传输模式和配对状态。") }
            guard let hash=r.value(forHTTPHeaderField: "X-SHA256"), hash.count==64, hash.allSatisfy({ $0.isHexDigit }) else { throw TransferError(message: "设备未返回有效的文件校验值。") }
            if offset>0 {
                guard r.value(forHTTPHeaderField: "Content-Range")=="bytes \(offset)-\(expected-1)/\(expected)" else { throw TransferError(message: "续传范围不匹配。") }
            }
            expectedHash=hash.lowercased()
            if offset==0 { guard FileManager.default.createFile(atPath: part.path, contents: Data()) else { throw TransferError(message:"无法创建下载文件。") } }
            handle=try FileHandle(forWritingTo: part); try handle?.seekToEnd()
            completionHandler(.allow)
        } catch { failure=error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard offset+received+Int64(data.count)<=expected else { throw TransferError(message:"下载长度超出设备列表，已停止。") }
            try handle?.write(contentsOf: data); received+=Int64(data.count)
            progress(Double(offset+received)/Double(expected))
        } catch { failure=error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do {
            try handle?.synchronize(); try handle?.close(); handle=nil
            if let e=failure ?? error { throw e }
            guard offset+received==expected else { throw TransferError(message:"传输中断，重新下载将从断点继续。") }
            guard try sha256(part)==expectedHash else {
                // Quarantine mismatching content instead of publishing it as a completed recording.
                let bad=part.deletingPathExtension().appendingPathExtension("bad-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: part,to: bad)
                throw TransferError(message:"完整性校验失败，异常文件已隔离，请重试。")
            }
            continuation?.resume(returning: expectedHash)
        } catch { continuation?.resume(throwing: error) }
        continuation=nil; session.finishTasksAndInvalidate()
    }
}

@MainActor final class Studio: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published var usbPorts=USBTransport.ports()
    @Published var usbPort=""
    var usb:USBTransport?
    @Published var localFiles:[URL]=[]
    @Published var address=""
    @Published var code=""
    @Published var status="设备「阅读 → Wi-Fi 同步内容」开启传输模式。"
    @Published var recordings:[Recording]=[]
    @Published var devices:[String]=[]
    @Published var busy=false
    @Published var connected=false
    @Published var progress=0.0
    @Published var activeFile=""
    @Published var downloaded:Set<String>=[]
    @Published var folder=FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0].appendingPathComponent("InkNote",isDirectory:true)
    var token="", base:URL?
    let browser=NetServiceBrowser()
    var services:[NetService]=[]
    var player:AVAudioPlayer?
    override init() { super.init(); if let saved=UserDefaults.standard.string(forKey:"recordingsFolder"){folder=URL(fileURLWithPath:saved,isDirectory:true)};scanLocal(); browser.delegate=self; browser.searchForServices(ofType:"_inknote._tcp.",inDomain:"local.") }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) { services.append(service); service.delegate=self; service.resolve(withTimeout:5) }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host=sender.hostName else{return}; let item="\(host):\(sender.port)"
        if !devices.contains(item) { devices.append(item) }
        if address.isEmpty { address=item }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let host=service.hostName { devices.removeAll{$0=="\(host):\(service.port)"} }
        services.removeAll{$0==service}
    }
    func endpoint(_ path:String) throws -> URL {
        guard let base=base, let u=URL(string:path,relativeTo:base)?.absoluteURL else {throw TransferError(message:"请先连接设备。")};return u
    }
    func requestData(_ request:URLRequest) async throws -> (Data,URLResponse) {
        if let transport=usb {
            do {
                let result=try await Task.detached{try transport.request(request)}.value
                return(result.0,result.1)
            } catch {
                usb=nil;connected=false;token="";base=nil
                status="USB 连接已失效。设备保持「阅读 → USB 数据线传输」页面后，点击「USB 连接」重连。"
                throw error
            }
        }
        return try await URLSession.shared.data(for:request)
    }
    func connectUSB() async {
        busy=true;connected=false;usb=nil;recordings=[];downloaded=[];defer{busy=false}
        do {
            let port=usbPort.isEmpty ? usbPorts.first ?? "" : usbPort
            guard !port.isEmpty else{throw TransferError(message:"没有检测到 USB 设备，请连接支持数据传输的 USB 线并刷新。")}
            status="正在连接 USB…设备应停留在 USB 数据线传输页面。"
            let result=try await Task.detached{let transport=try USBTransport(path:port);return(transport,try transport.hello())}.value
            usb=result.0;token=result.1;base=URL(string:"http://inknote-usb:8081");connected=true
            try await refreshList();status="USB 已连接 · \(recordings.count) 段录音 · 可同步书籍"
        } catch {usb=nil;connected=false;status=error.localizedDescription}
    }
    func json<T:Decodable>(_ request:URLRequest,as type:T.Type) async throws -> T {
        let (data,response)=try await requestData(request)
        guard let r=response as? HTTPURLResponse,r.statusCode==200 else {throw TransferError(message:"连接失败：检查配对码，或重新开启设备传输模式。")}
        return try JSONDecoder().decode(type,from:data)
    }
    func connect() async {
        busy=true; usb=nil; connected=false; recordings=[]; downloaded=[]; defer{busy=false}
        do {
            var host=address.trimmingCharacters(in:.whitespacesAndNewlines)
            if !host.contains("://") {host="http://"+host}
            guard let u=URL(string:host),u.scheme=="http",u.host != nil,u.user==nil,u.password==nil else{throw TransferError(message:"请输入设备屏幕上的地址，例如 192.168.4.1:8081。")}
            base=u; var req=URLRequest(url:try endpoint("/api/pair"));req.httpMethod="POST";req.setValue("application/json",forHTTPHeaderField:"Content-Type")
            req.httpBody=try JSONSerialization.data(withJSONObject:["code":code]);req.timeoutInterval=15
            status="正在配对…";let reply=try await json(req,as:PairReply.self)
            guard reply.api==1 else{throw TransferError(message:"设备接口版本不兼容。")}
            token=reply.token; connected=true; try await refreshList(); status="已连接 · \(recordings.count) 段录音"
        } catch {status=error.localizedDescription;connected=false}
    }
    func refreshList() async throws {
        var all:[Recording]=[];var offset=0
        while true {
            var req=URLRequest(url:try endpoint("/api/recordings?offset=\(offset)"));req.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
            let list=try await json(req,as:Listing.self)
            for r in list.files {guard r.name.range(of:"^rec_[0-9a-fA-F]{8}\\.wav$",options:.regularExpression) != nil,r.size>=44,r.size<=115200044 else{throw TransferError(message:"设备返回了无效录音信息。")}}
            all+=list.files
            guard let next=list.next else{break};guard next>offset else{throw TransferError(message:"设备分页异常。")};offset=next
        }
        recordings=all.sorted{$0.name<$1.name}; downloaded=[]
        for r in recordings { if verifiedLocal(r) {downloaded.insert(r.name)} }
    }
    var deviceFolder:URL {folder.appendingPathComponent((base?.host ?? "device").replacingOccurrences(of:":",with:"_"),isDirectory:true)}
    func local(_ r:Recording)->URL {deviceFolder.appendingPathComponent(r.name)}
    func verifiedLocal(_ r:Recording)->Bool {
        let url=local(r),receipt=url.appendingPathExtension("sha256")
        guard let h=try? String(contentsOf:receipt,encoding:.utf8),let attrs=try? FileManager.default.attributesOfItem(atPath:url.path),(attrs[.size] as? NSNumber)?.int64Value==r.size else{return false}
        return (try? sha256(url))==h
    }
    func download(_ files:[Recording]) async {
        busy=true;defer{busy=false;activeFile="";scanLocal()}
        do {
            try FileManager.default.createDirectory(at:deviceFolder,withIntermediateDirectories:true)
            for r in files {
                if verifiedLocal(r) {downloaded.insert(r.name);continue}
                activeFile=r.name;progress=0;status="正在下载 \(r.name)"
                let dest=local(r),part=dest.appendingPathExtension("part")
                var offset=((try? FileManager.default.attributesOfItem(atPath:part.path)[.size]) as? NSNumber)?.int64Value ?? 0
                if offset>=r.size {try FileManager.default.moveItem(at:part,to:part.appendingPathExtension(UUID().uuidString));offset=0}
                var req=URLRequest(url:try endpoint("/api/file?name=\(r.name)"));req.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
                if offset>0{req.setValue("bytes=\(offset)-",forHTTPHeaderField:"Range")}
                let hash:String
                if usb != nil {
                    req.setValue(nil,forHTTPHeaderField:"Range")
                    let (data,response)=try await requestData(req)
                    guard let http=response as? HTTPURLResponse,http.statusCode==200,data.count==r.size,let expected=http.value(forHTTPHeaderField:"X-SHA256") else{throw TransferError(message:"USB 录音下载不完整。")}
                    hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
                    guard hash==expected else{throw TransferError(message:"USB 录音 SHA-256 校验失败。")}
                    try data.write(to:part,options:.atomic);progress=1
                } else {
                    let worker=Download(part:part,offset:offset,expected:r.size){[weak self] p in DispatchQueue.main.async{self?.progress=p}}
                hash=try await worker.run(req)
                }
                if FileManager.default.fileExists(atPath:dest.path){try FileManager.default.moveItem(at:dest,to:dest.appendingPathExtension("previous-\(UUID().uuidString)"))}
                try FileManager.default.moveItem(at:part,to:dest)
                try hash.write(to:dest.appendingPathExtension("sha256"),atomically:true,encoding:.utf8)
                downloaded.insert(r.name)
            }
            status="下载完成，SHA-256 校验通过。卡内原件已保留。"
        } catch {status=error.localizedDescription+" 设备保持传输模式后，可点击下载重试。"}
    }
    func chooseFolder(){let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;p.canCreateDirectories=true;if p.runModal() == .OK,let u=p.url{folder=u;UserDefaults.standard.set(u.path,forKey:"recordingsFolder");downloaded=[];scanLocal()}}
    func scanLocal() {
        guard let iterator=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else{localFiles=[];return}
        localFiles=iterator.compactMap{ $0 as? URL }.filter{ $0.pathExtension.lowercased()=="wav" && ((try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true) }.sorted{$0.lastPathComponent<$1.lastPathComponent}
    }
    func importAudio() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.wav];panel.allowsMultipleSelection=true
        guard panel.runModal() == .OK else{return}
        do {
            let target=folder.appendingPathComponent("Imported",isDirectory:true)
            try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            for source in panel.urls {
                var dest=target.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath:dest.path){
                    if try sha256(source)==sha256(dest){continue}
                    dest=target.appendingPathComponent(source.deletingPathExtension().lastPathComponent+"-"+UUID().uuidString.prefix(8)+".wav")
                }
                try FileManager.default.copyItem(at:source,to:dest)
            }
            scanLocal();status="录音已导入本地库，可以离线转写。"
        } catch {status="导入失败：\(error.localizedDescription)";scanLocal()}
    }
    func playLocal(_ url:URL){do{player=try AVAudioPlayer(contentsOf:url);player?.play();status="正在播放 \(url.lastPathComponent)"}catch{status=error.localizedDescription}}
    func play(_ r:Recording){do{player=try AVAudioPlayer(contentsOf:local(r));player?.play();status="正在播放 \(r.name)"}catch{status=error.localizedDescription}}
}

struct ContentView:View {
    @StateObject var model=Studio()
    @StateObject var speech=Transcriber()
    @State private var libraryTab=0
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            HStack{Image(systemName:"waveform").font(.largeTitle);VStack(alignment:.leading){Text("InkNote Studio").font(.largeTitle.bold());Text("录音整理 · 书籍与笔记").foregroundStyle(.secondary)};Spacer();Text(model.connected ? "已连接" : "等待连接").foregroundStyle(model.connected ? .green : .secondary)}
            GroupBox("连接设备"){
                VStack(alignment:.leading,spacing:12){
                    HStack{Picker("USB 设备",selection:$model.usbPort){Text("自动选择").tag("");ForEach(model.usbPorts,id:\.self){Text($0).tag($0)}};Button("刷新 USB"){model.usbPorts=USBTransport.ports()};Button("USB 连接"){Task{await model.connectUSB()}}.buttonStyle(.borderedProminent)}.disabled(model.busy)
                    Text("数据线直连：设备「阅读 → USB 数据线传输」，无需 Wi-Fi 或配对码。").font(.callout).foregroundStyle(.secondary)
                    if !model.devices.isEmpty{HStack{Text("发现设备");ForEach(model.devices,id:\.self){d in Button(d){model.address=d}.disabled(model.busy)}}}
                    HStack{Button("热点直连地址"){model.address="192.168.4.1:8081"}.disabled(model.busy);TextField("设备地址 · 例如 192.168.4.1:8081",text:$model.address);TextField("屏幕上的六位配对码",text:$model.code).frame(width:170);Button("连接"){Task{await model.connect()}}.buttonStyle(.borderedProminent)}.disabled(model.busy)
                    Text("设备「阅读 → Wi-Fi 同步内容」→ Mac 连接 InkNote 热点 → 输入六位配对码。").font(.callout).foregroundStyle(.secondary)
                }.padding(8)
            }
            Picker("录音库",selection:$libraryTab){Text("设备录音").tag(0);Text("本地录音与文字").tag(1);Text("阅读 · 书籍与笔记").tag(2)}.pickerStyle(.segmented)
            if libraryTab==0 {
            HStack{Text("录音库").font(.title2.bold());Text("\(model.recordings.count) 段").foregroundStyle(.secondary);Spacer();Button("刷新"){Task{do{try await model.refreshList()}catch{model.status=error.localizedDescription}}}.disabled(!model.connected || model.busy);Button("下载全部新录音"){Task{await model.download(model.recordings)}}.disabled(!model.connected || model.busy || model.recordings.isEmpty)}
            List(model.recordings){r in HStack(spacing:16){Image(systemName:model.downloaded.contains(r.name) ? "checkmark.circle.fill":"waveform").foregroundStyle(model.downloaded.contains(r.name) ? .green : .secondary);VStack(alignment:.leading){Text(r.name).font(.system(.body,design:.monospaced));Text("\(r.time) · \(ByteCountFormatter.string(fromByteCount:r.size,countStyle:.file))").font(.caption).foregroundStyle(.secondary)};Spacer();if model.downloaded.contains(r.name){Button("播放"){model.play(r)};Button("转文字"){speech.open(model.local(r))}.disabled(speech.active)};Button(model.downloaded.contains(r.name) ? "已下载":"下载"){Task{await model.download([r])}}.disabled(model.busy || model.downloaded.contains(r.name))}.padding(.vertical,5)}.listStyle(.inset).overlay{if model.recordings.isEmpty{Text("连接后显示设备中已保存的录音").foregroundStyle(.secondary)}}
            } else if libraryTab==1 {
                HStack{Text("本地录音 · \(model.localFiles.count) 段").font(.title2.bold());Spacer();Button("导入 WAV"){model.importAudio()}.disabled(model.busy);Button("刷新本地库"){model.scanLocal()}}
                List(model.localFiles,id:\.path){url in
                    HStack {Image(systemName:"waveform");VStack(alignment:.leading){Text(url.lastPathComponent).font(.body.monospaced());Text(url.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)};Spacer();Button("播放"){model.playLocal(url)};Button(FileManager.default.fileExists(atPath:url.appendingPathExtension("inknote.json").path) ? "查看文字" : "转文字"){speech.open(url)}.disabled(speech.active)}.padding(.vertical,5)
                }.overlay{if model.localFiles.isEmpty{Text("下载设备录音或导入 WAV 后，即可离线转文字。").foregroundStyle(.secondary)}}
                Text("离线转写 · 说话人区分 · 会议纪要 · 支持编辑与导出").font(.caption).foregroundStyle(.secondary)
            }
            if libraryTab==2 {BookLibraryView(studio:model)}
            if speech.active {HStack{ProgressView().controlSize(.small);Text(speech.status);Spacer();Button("查看转写"){speech.presenting=true}}}
            if !model.activeFile.isEmpty{ProgressView(value:model.progress);Text("\(model.activeFile) · \(Int(model.progress*100))%").font(.caption)}
            Text(model.status).font(.callout).textSelection(.enabled)
            Divider()
            HStack{Image(systemName:"folder");Text(model.folder.path).font(.caption).lineLimit(1);Spacer();Button("更改位置"){model.chooseFolder()}.disabled(model.busy);Button("打开文件夹"){NSWorkspace.shared.open(model.folder)};Button("停止播放"){model.player?.stop()}}
        }.padding(28).frame(minWidth:900,minHeight:720).sheet(isPresented:$speech.presenting){TranscriptView(engine:speech)}
    }
}
@main struct InkNoteStudioApp:App {var body:some Scene{WindowGroup{ContentView()}}}
