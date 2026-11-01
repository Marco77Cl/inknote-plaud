import Foundation
import CryptoKit

struct BookFailure: LocalizedError { let message:String; var errorDescription:String? {message} }
struct BookChapter: Codable { let title:String; let offset:Int }
struct BookMetadata: Codable { var version=1; let title:String; let author:String; let kind:String; let chapters:[BookChapter]; var id:String?=nil }
struct ImportedBook {
    let metadata:BookMetadata; let text:Data; let package:Data
    var id:String {SHA256.hash(data:package).map{String(format:"%02x",$0)}.joined()}
}
private func fail(_ text:String)->BookFailure {BookFailure(message:text)}
private extension Data {
    func u16(_ p:Int)->Int {Int(self[p]) | Int(self[p+1])<<8}
    func u32(_ p:Int)->Int {u16(p) | u16(p+2)<<16}
}
// Validate the central directory before launching unzip. No archive is extracted to disk.
private struct SafeEPUB {
    let url:URL; let entries:[String:Int]
    init(_ url:URL) throws {
        let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size>22,size<=64*1024*1024 else{throw fail("EPUB 文件大小必须小于 64 MiB。")}
        let d=try Data(contentsOf:url); var end:Int?=nil
        for p in stride(from:d.count-22,through:max(0,d.count-65557),by:-1) {if d.u32(p)==0x06054b50 && p+22+d.u16(p+20)==d.count {end=p;break}}
        guard let e=end,d.u16(e+4)==0,d.u16(e+6)==0,d.u16(e+8)==d.u16(e+10),d.u16(e+10)>0,d.u16(e+10)<=4096 else{throw fail("损坏或不支持的 EPUB ZIP 文件。")}
        var p=d.u32(e+16);let directoryEnd=p+d.u32(e+12)
        guard directoryEnd==e else{throw fail("EPUB ZIP 目录异常。")}
        var found:[String:Int]=[:];var total=0
        for _ in 0..<d.u16(e+10) {
            guard p+46<=e,d.u32(p)==0x02014b50 else{throw fail("EPUB ZIP 目录损坏。")}
            let n=d.u16(p+28),extra=d.u16(p+30),comment=d.u16(p+32),expanded=d.u32(p+24),compressed=d.u32(p+20),flags=d.u16(p+8),method=d.u16(p+10)
            guard p+46+n+extra+comment<=e,let name=String(data:d.subdata(in:p+46..<p+46+n),encoding:.utf8), !name.isEmpty else{throw fail("EPUB 路径编码无效。")}
            let mode=(d.u32(p+38)>>16)&0xf000
            guard !name.hasPrefix("/"),!name.contains("\\"),!name.contains("\0"),!name.contains(":"),!name.contains("\n"),!name.contains("\r"),!name.contains("*"),!name.contains("?"),!name.contains("["),!name.split(separator:"/").contains(".."),!name.split(separator:"/").contains("."),mode != 0xa000,found[name]==nil,flags&1==0,(method==0 || method==8),expanded<=16*1024*1024,expanded<=max(1048576,compressed*1000) else{throw fail("EPUB 包含不安全路径、加密内容或过大条目。")}
            total+=expanded;guard total<=64*1024*1024 else{throw fail("EPUB 解压后超过 64 MiB。")}
            found[name]=expanded;p+=46+n+extra+comment
        }
        guard p==directoryEnd,found["META-INF/encryption.xml"]==nil else{throw fail("不支持加密或 DRM EPUB，请导入无 DRM 的书籍。")}
        self.url=url;self.entries=found
    }
    func read(_ name:String) throws->Data {
        guard let limit=entries[name] else{throw fail("EPUB 缺少文件：\(name)")}
        let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");task.arguments=["-p",url.path,name];task.standardOutput=pipe;task.standardError=FileHandle.nullDevice
        try task.run();var result=Data()
        while true {let chunk=pipe.fileHandleForReading.readData(ofLength:65536);if chunk.isEmpty{break};result.append(chunk);if result.count>limit {task.terminate();task.waitUntilExit();throw fail("EPUB 解压大小与目录不一致。")}}
        task.waitUntilExit();guard task.terminationStatus==0,result.count==limit else{throw fail("EPUB 文件损坏或校验失败。")};return result
    }
}
private final class BookXML:NSObject,XMLParserDelegate {
    var rootfile="",title="",author="",items:[String:(String,String)]=[:],spine:[String]=[],fixed=false,text="",depth=0,skip=0,current="",value="",imageCount=0,heading="",headingDepth=0
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes a:[String:String]) {
        let n=name.components(separatedBy:":").last!.lowercased();depth+=1
        if n=="h1",heading.isEmpty{headingDepth=depth}
        if n=="rootfile",rootfile.isEmpty {rootfile=a["full-path"] ?? ""}
        if n=="item",let id=a["id"],let href=a["href"] {items[id]=(href,a["media-type"] ?? "")}
        if (a["properties"] ?? "").contains("rendition:layout-pre-paginated"){fixed=true}
        if n=="itemref",let id=a["idref"],a["linear"] != "no" {spine.append(id)}
        if n=="meta",a["property"]=="rendition:layout" {current="layout";value=""}
        if n=="meta",a["name"]=="fixed-layout",a["content"]=="true" {fixed=true}
        if n=="title" || n=="creator" {current=n;value=""}
        if n=="script" || n=="style" || n=="head" {if skip==0{skip=depth}}
        if skip==0 {
            if ["p","div","section","h1","h2","h3","h4","li","br","blockquote","tr"].contains(n){text+="\n"}
            if n=="img" || n=="image" {imageCount+=1;text+="\n[插图：\(a["alt"] ?? "本版仅显示文字")]\n"}
        }
    }
    func parser(_ parser:XMLParser,foundCharacters s:String) {if headingDepth>0{heading+=s};if !current.isEmpty{value+=s};if skip==0{text+=s}}
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
        let n=name.components(separatedBy:":").last!.lowercased()
        if n=="title",current=="title" {if title.isEmpty{title=value.trimmingCharacters(in:.whitespacesAndNewlines)};current=""}
        if n=="creator",current=="creator" {if !author.isEmpty{author+=", "};author+=value.trimmingCharacters(in:.whitespacesAndNewlines);current=""}
        if n=="meta",current=="layout" {fixed = fixed || value.trimmingCharacters(in:.whitespacesAndNewlines)=="pre-paginated";current=""}
        if headingDepth==depth{headingDepth=0};if skip==depth {skip=0};if skip==0,["p","div","section","h1","h2","h3","h4","li","blockquote","tr"].contains(n){text+="\n"};depth-=1
    }
    static func parse(_ data:Data)throws->BookXML {
        // External entities and DTDs are unnecessary for EPUB 3 and disallowed.
        if let s=String(data:data,encoding:.utf8),s.range(of:"<!ENTITY",options:.caseInsensitive) != nil {throw fail("EPUB 不支持自定义 XML 实体。")}
        let sanitized=String(data:data,encoding:.utf8).map{$0.replacingOccurrences(of:"&nbsp;",with:"&#160;")}.map{Data($0.utf8)} ?? data
        let result=BookXML(),p=XMLParser(data:sanitized);p.shouldResolveExternalEntities=false;p.delegate=result
        guard p.parse() else{throw fail("EPUB XML/XHTML 解析失败：\(p.parserError?.localizedDescription ?? "格式错误")")};return result
    }
}
enum BookImporter {
    static let maxText=8*1024*1024
    static func convert(_ url:URL,kind:String="book")throws->ImportedBook {
        guard kind=="book" || kind=="note" else{throw fail("内容分类无效。")}
        var title=url.deletingPathExtension().lastPathComponent,author="",text=Data(),chapters:[BookChapter]=[]
        if url.pathExtension.lowercased()=="epub" {
            let archive=try SafeEPUB(url),container=try BookXML.parse(archive.read("META-INF/container.xml"))
            let opf=container.rootfile;guard !opf.isEmpty else{throw fail("EPUB 缺少内容索引。")}
            let doc=try BookXML.parse(archive.read(opf));guard !doc.fixed else{throw fail("暂不支持固定版式 EPUB，请使用文字流式排版电子书。")}
            guard !doc.spine.isEmpty,doc.spine.count<=512 else{throw fail("EPUB 章节数必须为 1–512。")}
            if !doc.title.isEmpty{title=doc.title};author=doc.author
            let base=(opf as NSString).deletingLastPathComponent
            for id in doc.spine {
                guard let (href,mime)=doc.items[id],mime=="application/xhtml+xml" || mime=="text/html" else{throw fail("EPUB 阅读顺序引用了不支持的章节。")}
                guard let decoded=href.components(separatedBy:"#")[0].removingPercentEncoding,!decoded.hasPrefix("/"),!decoded.contains(":"),!decoded.contains("\\") else{throw fail("EPUB 章节路径无效。")}
                let path=((base.isEmpty ? "" : base+"/")+decoded as NSString).standardizingPath
                guard !path.hasPrefix("../"),path != ".." else{throw fail("EPUB 章节路径越界。")}
                let chapter=try BookXML.parse(archive.read(path)),body=normalize(chapter.text)
                if body.isEmpty{continue}
                chapters.append(BookChapter(title:chapter.title.isEmpty ? (chapter.heading.isEmpty ? "第 \(chapters.count+1) 章" : chapter.heading) : chapter.title,offset:text.count))
                text.append(Data((body+"\n\n").utf8));guard text.count<=maxText else{throw fail("书籍正文超过 8 MiB。")}
            }
        } else if url.pathExtension.lowercased()=="txt" || (kind=="note" && url.pathExtension.lowercased()=="md") {
            let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0;guard size<=maxText*2 else{throw fail("TXT 文件过大。")}
            let data=try Data(contentsOf:url);var value=String(data:data,encoding:.utf8)
            if data.starts(with:[0xff,0xfe]) || data.starts(with:[0xfe,0xff]) {value=String(data:data,encoding:.utf16)}
            guard let string=value else{throw fail("TXT 编码暂不支持，请在 Mac 上另存为 UTF-8 或带 BOM 的 UTF-16。")}
            text=Data(normalize(string.replacingOccurrences(of:"\u{feff}",with:"")).utf8);chapters=[BookChapter(title:title,offset:0)]
        } else {throw fail("请选择 EPUB 或 TXT 文件。")}
        guard !text.contains(0),!text.isEmpty,text.count<=maxText,!chapters.isEmpty else{throw fail("没有可阅读正文，或正文超过 8 MiB。")}
        let meta=BookMetadata(title:truncate(title),author:truncate(author),kind:kind,chapters:chapters.map{BookChapter(title:truncate($0.title),offset:$0.offset)})
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];let json=try encoder.encode(meta);guard json.count<=65536 else{throw fail("章节目录过大。")}
        var package=Data("INKBOOK1".utf8);let n=UInt32(json.count);package.append(contentsOf:[UInt8(n&255),UInt8((n>>8)&255),UInt8((n>>16)&255),UInt8(n>>24)]);package.append(json);package.append(text)
        return ImportedBook(metadata:meta,text:text,package:package)
    }
    static func truncate(_ value:String)->String {var result="";for c in value {if result.utf8.count+String(c).utf8.count>240{break};result.append(c)};return result}
    static func normalize(_ text:String)->String {text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").components(separatedBy:"\n").map{$0.replacingOccurrences(of:"[\\t ]+",with:" ",options:.regularExpression).trimmingCharacters(in:.whitespaces)}.joined(separator:"\n").replacingOccurrences(of:"\n{3,}",with:"\n\n",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)}
}
