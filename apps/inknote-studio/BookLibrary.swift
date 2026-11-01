import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

struct LibraryBook:Identifiable {let id:String;let metadata:BookMetadata;let directory:URL}
@MainActor final class BookLibrary:ObservableObject {
    @Published var books:[LibraryBook]=[]
    @Published var selected:String?=nil
    @Published var preview=""
    @Published var status="支持无 DRM 的流式 EPUB、UTF-8 / UTF-16 TXT。仅显示文字与插图占位，不保留复杂表格和原书排版。"
    @Published var busy=false
    let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("InkNote/Books",isDirectory:true)
    init(){reload()}
    var current:LibraryBook? {books.first{$0.id==selected}}
    func reload(){books=((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []).compactMap{url in guard let data=try? Data(contentsOf:url.appendingPathComponent("meta.json")),let meta=try? JSONDecoder().decode(BookMetadata.self,from:data),let id=meta.id,id==url.lastPathComponent else{return nil};return LibraryBook(id:id,metadata:meta,directory:url)}.sorted{$0.metadata.title.localizedStandardCompare($1.metadata.title) == .orderedAscending}}
    func select(_ id:String?){selected=id;preview=current.flatMap{try? String(contentsOf:$0.directory.appendingPathComponent("book.txt"),encoding:.utf8)}.map{String($0.prefix(20000))} ?? ""}
    func importFile(kind:String){
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"epub") ?? .data,.plainText];if kind=="note" {panel.allowedContentTypes.append(UTType(filenameExtension:"md") ?? .plainText)};panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return};busy=true;status="正在解析书籍…"
        Task {
            do {
                let book=try await Task.detached{try BookImporter.convert(url,kind:kind)}.value
                let dest=root.appendingPathComponent(book.id,isDirectory:true)
                if !FileManager.default.fileExists(atPath:dest.path){
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    let staging=root.appendingPathComponent(".import-"+UUID().uuidString,isDirectory:true)
                    try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
                    do {
                        try book.package.write(to:staging.appendingPathComponent("book.inkbook"),options:.atomic)
                        try book.text.write(to:staging.appendingPathComponent("book.txt"),options:.atomic)
                        var metadata=book.metadata;metadata.id=book.id
                        try JSONEncoder().encode(metadata).write(to:staging.appendingPathComponent("meta.json"),options:.atomic)
                        try FileManager.default.copyItem(at:url,to:staging.appendingPathComponent("original."+url.pathExtension.lowercased()))
                        try FileManager.default.moveItem(at:staging,to:dest)
                    } catch {try? FileManager.default.removeItem(at:staging);throw error}
                }
                reload();select(book.id);status="已导入 \(book.metadata.title) · \(book.metadata.chapters.count) 章。已导入 Mac 书库，尚需点击「同步所选到设备」后才会出现在设备书架。原始文件已保留。"
            } catch {status="导入失败："+error.localizedDescription}
            busy=false
        }
    }
    func sync(_ studio:Studio)async {
        guard let book=current,!studio.busy else{return};busy=true;studio.busy=true;defer{busy=false;studio.busy=false}
        do {
            let package=try Data(contentsOf:book.directory.appendingPathComponent("book.inkbook"))
            let hash=SHA256.hash(data:package).map{String(format:"%02x",$0)}.joined()
            guard hash==book.id else{throw BookFailure(message:"本地阅读包校验失败，请重新导入原始书籍。")}
            var request=URLRequest(url:try studio.endpoint("/api/books?id="+hash));request.httpMethod="POST";request.httpBody=package;request.timeoutInterval=180
            request.setValue("Bearer "+studio.token,forHTTPHeaderField:"Authorization");request.setValue(hash,forHTTPHeaderField:"X-SHA256");request.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
            status="正在同步 \(book.metadata.title)…"
            let (data,response)=try await studio.requestData(request)
            guard let response=response as? HTTPURLResponse,response.statusCode==200 else{throw BookFailure(message:"设备未接受阅读包，请检查连接、TF 卡空间和固件版本。")}
            struct Reply:Decodable{let id:String;let sha256:String;let status:String}
            let reply=try JSONDecoder().decode(Reply.self,from:data)
            guard reply.id==hash,reply.sha256==hash,["saved","exists"].contains(reply.status) else{throw BookFailure(message:"设备返回的阅读包校验值不匹配。")}
            status="\(reply.status=="exists" ? "设备已有该书" : "同步完成") · SHA-256 校验通过。退出设备传输模式后进入阅读。"
        } catch {status="同步失败："+error.localizedDescription}
    }
    func exportTF(){
        guard let book=current else{return};let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.message="选择 TF 卡根目录，将生成 books/书籍ID 文件夹。"
        guard panel.runModal() == .OK,let target=panel.url else{return}
        do {
            let books=target.appendingPathComponent("books",isDirectory:true),dest=books.appendingPathComponent(book.id,isDirectory:true)
            guard !FileManager.default.fileExists(atPath:dest.path) else{status="目标已存在同一本书，未覆盖阅读进度。";return}
            try FileManager.default.createDirectory(at:books,withIntermediateDirectories:true)
            let staging=books.appendingPathComponent(".import-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
            do {for name in ["book.txt","meta.json"]{try FileManager.default.copyItem(at:book.directory.appendingPathComponent(name),to:staging.appendingPathComponent(name))};try FileManager.default.moveItem(at:staging,to:dest)}catch{try? FileManager.default.removeItem(at:staging);throw error}
            status="已导出到 \(dest.path)。安全推出 TF 卡后插回设备。"
        } catch {status="导出失败："+error.localizedDescription}
    }
}
struct BookLibraryView:View {
    @ObservedObject var studio:Studio
    @StateObject var library=BookLibrary()
    @State var category="book"
    var body:some View {
        VStack(alignment:.leading,spacing:10){
            HStack{Picker("分类",selection:$category){Text("书籍").tag("book");Text("笔记").tag("note")}.frame(width:180);Spacer();Button(category=="book" ? "导入 EPUB / TXT":"导入笔记 TXT / MD"){library.importFile(kind:category)}.disabled(library.busy);Button("打开书库"){try? FileManager.default.createDirectory(at:library.root,withIntermediateDirectories:true);NSWorkspace.shared.open(library.root)}}
            HSplitView {
                List(selection:$library.selected){ForEach(library.books.filter{$0.metadata.kind==category}){book in VStack(alignment:.leading){Text(book.metadata.title);Text("\(book.metadata.author) · \(book.metadata.chapters.count) 章").font(.caption).foregroundStyle(.secondary)}.tag(book.id)}}.frame(minWidth:230)
                ScrollView{Text(library.preview.isEmpty ? "选择书籍预览正文，或导入 EPUB / TXT。":library.preview).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding()}.frame(minWidth:350)
            }.onChange(of:library.selected){library.select($0)}.onChange(of:category){_ in library.select(nil)}
            HStack{Button("同步所选到设备"){Task{await library.sync(studio)}}.disabled(library.current==nil || !studio.connected || studio.busy || library.busy);Button("导出所选到 TF 卡"){library.exportTF()}.disabled(library.current==nil || library.busy);if library.busy{ProgressView().controlSize(.small)};Text("预览最多 20,000 字；设备保存完整正文。 ").font(.caption).foregroundStyle(.secondary)}
            Text(library.status).font(.callout).textSelection(.enabled)
            Text("笔记支持 TXT / Markdown；会议纪要可先导出 Markdown 再导入。阅读包不覆盖同内容书籍的设备进度。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
