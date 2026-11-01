import Foundation
import Darwin

/// Bounded line framing over the board's existing USB serial interface.
/// File operations still use the same SHA-256 checked HTTP API inside the device.
final class USBTransport: @unchecked Sendable {
    let path:String
    private var fd:Int32 = -1
    private var received=Data()
    private let lock=NSLock()
    init(path:String)throws {
        self.path=path
        fd=Darwin.open(path,O_RDWR|O_NOCTTY|O_NONBLOCK)
        guard fd>=0 else{throw TransferError(message:"无法打开 USB：请关闭串口监视器，确认数据线已连接。")}
        var options=termios()
        guard tcgetattr(fd,&options)==0 else{Darwin.close(fd);fd = -1;throw TransferError(message:"USB 串口不可用。")}
        cfmakeraw(&options);options.c_cflag |= tcflag_t(CLOCAL|CREAD);options.c_cflag &= ~tcflag_t(HUPCL)
        cfsetispeed(&options,speed_t(B115200));cfsetospeed(&options,speed_t(B115200))
        guard tcsetattr(fd,TCSANOW,&options)==0 else{Darwin.close(fd);fd = -1;throw TransferError(message:"无法设置 USB 串口。")}
        tcflush(fd,TCIFLUSH)
    }
    deinit{if fd>=0{Darwin.close(fd)}}
    static func ports()->[String]{((try? FileManager.default.contentsOfDirectory(atPath:"/dev")) ?? []).filter{$0.hasPrefix("cu.usbmodem")}.sorted().map{"/dev/"+$0}}
    private func command(_ op:String,_ argument:String="",timeout:TimeInterval=12)throws->(String,String) {
        let seq=UUID().uuidString.replacingOccurrences(of:"-",with:"")
        let data=Data("INKUSB1 \(seq) \(op) \(argument)\n".utf8),deadline=Date().addingTimeInterval(timeout)
        var offset=0
        while offset<data.count {
            let n=data.withUnsafeBytes{Darwin.write(fd,$0.baseAddress!.advanced(by:offset),data.count-offset)}
            if n>0{offset+=n}else if errno != EAGAIN && errno != EINTR {throw TransferError(message:"USB 已断开，请重新连接。")}
            if Date()>deadline{throw TransferError(message:"USB 写入超时。")};if n<=0{usleep(1000)}
        }
        while Date()<deadline {
            while let end=received.firstIndex(of:10) {
                let line=String(decoding:received[..<end],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines);received.removeSubrange(...end)
                let parts=line.split(separator:" ",maxSplits:3,omittingEmptySubsequences:true)
                if parts.count>=3,parts[0]=="INKUSB1",parts[1]==Substring(seq) {
                    if parts[2]=="ERR"{throw TransferError(message:"设备 USB 传输失败：\(parts.count>3 ? String(parts[3]):"未知错误")。退出传输页后重试。")}
                    return (String(parts[2]),parts.count>3 ? String(parts[3]):"")
                }
            }
            var buffer=[UInt8](repeating:0,count:4096)
            let n=Darwin.read(fd,&buffer,buffer.count)
            if n>0{received.append(contentsOf:buffer.prefix(n));if received.count>65536{received.removeAll()}}
            else if n<0 && errno != EAGAIN && errno != EINTR {throw TransferError(message:"USB 已断开。")}
            else {usleep(1000)}
        }
        throw TransferError(message:"USB 未响应。请在设备进入「阅读 → USB 数据线传输」，保持该页面，再点击 USB 连接。")
    }
    func hello()throws->String {
        lock.lock();defer{lock.unlock()}
        let (status,token)=try command("HELLO",timeout:6)
        guard status=="OK",token.count==32,token.allSatisfy({$0.isHexDigit}) else{throw TransferError(message:"USB 设备版本不兼容。")};return token
    }
    func request(_ request:URLRequest)throws->(Data,HTTPURLResponse) {
        lock.lock();defer{lock.unlock()}
        guard let url=request.url else{throw TransferError(message:"无效请求。")}
        let method=request.httpMethod ?? "GET",body=request.httpBody ?? Data()
        guard ["GET","POST"].contains(method),url.path.hasPrefix("/api/") else{throw TransferError(message:"不支持的 USB 请求。")}
        _=try command("OPEN");defer{_ = try? command("CLOSE",timeout:2)}
        var header="\(method) \(url.path)\(url.query.map{"?"+$0} ?? "") HTTP/1.1\r\nHost: localhost:8081\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (name,value) in request.allHTTPHeaderFields ?? [:] {guard !name.contains("\r"),!name.contains("\n"),!value.contains("\r"),!value.contains("\n") else{throw TransferError(message:"无效请求头。")};if !["host","connection","content-length"].contains(name.lowercased()){header+="\(name): \(value)\r\n"}}
        var outgoing=Data((header+"\r\n").utf8);outgoing.append(body)
        for offset in stride(from:0,to:outgoing.count,by:1024){let chunk=outgoing.subdata(in:offset..<min(offset+1024,outgoing.count));let reply=try command("WRITE",chunk.base64EncodedString());guard reply.0=="OK" else{throw TransferError(message:"USB 写入未确认。")}}
        var response=Data();var mode=0, endOfHeader=0, expected=0, chunkPosition=0;let deadline=Date().addingTimeInterval(1800)
        while Date()<deadline {
            let (status,payload)=try command("READ")
            if status=="EOF"{return try Self.decodeHTTP(response,url:url)}
            if status=="WAIT"{continue}
            guard status=="DATA",let bytes=Data(base64Encoded:payload),bytes.count<=1024 else{throw TransferError(message:"USB 返回数据损坏。")}
            response.append(bytes);guard response.count<=130*1024*1024 else{throw TransferError(message:"USB 文件超过大小限制。")}
            if mode==0,let marker=response.range(of:Data("\r\n\r\n".utf8)) {
                endOfHeader=marker.upperBound
                guard endOfHeader<16384 else{throw TransferError(message:"USB 响应头过长。")}
                let header=String(decoding:response[..<marker.lowerBound],as:UTF8.self).lowercased()
                if header.components(separatedBy:"\r\n").contains(where:{$0.hasPrefix("transfer-encoding:") && $0.contains("chunked")}) {mode=2;chunkPosition=endOfHeader}
                else if let line=header.components(separatedBy:"\r\n").first(where:{$0.hasPrefix("content-length:")}),let length=Int(line.dropFirst(15).trimmingCharacters(in:.whitespaces)),length>=0,length<=130*1024*1024 {mode=1;expected=endOfHeader+length}
            }
            if mode==1,response.count>=expected {return try Self.decodeHTTP(response,url:url)}
            if mode==2 {
                while chunkPosition<response.count,let line=response.range(of:Data("\r\n".utf8),in:chunkPosition..<response.count) {
                    guard line.lowerBound-chunkPosition<32,let length=Int(String(decoding:response[chunkPosition..<line.lowerBound],as:UTF8.self).components(separatedBy:";")[0],radix:16),length>=0,length<=130*1024*1024 else{throw TransferError(message:"USB 分块响应损坏。")}
                    let end=line.upperBound+length
                    if end+2>response.count{break}
                    guard response[end]==13,response[end+1]==10 else{throw TransferError(message:"USB 分块响应损坏。")}
                    if length==0 {return try Self.decodeHTTP(response,url:url)}
                    chunkPosition=end+2
                }
            }

        }
        throw TransferError(message:"USB 传输超时，原文件保留，可重试。")
    }
    static func decodeHTTP(_ data:Data,url:URL)throws->(Data,HTTPURLResponse) {
        guard let marker=data.range(of:Data("\r\n\r\n".utf8)),marker.lowerBound<16384,let header=String(data:data[..<marker.lowerBound],encoding:.utf8) else{throw TransferError(message:"USB 响应头不完整。")}
        let lines=header.components(separatedBy:"\r\n"),statusParts=lines[0].split(separator:" ")
        guard statusParts.count>=2,let status=Int(statusParts[1]) else{throw TransferError(message:"USB 状态无效。")}
        var fields:[String:String]=[:]
        for line in lines.dropFirst(){guard let colon=line.firstIndex(of:":") else{continue};fields[String(line[..<colon]).lowercased()]=String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)}
        let raw=Data(data[marker.upperBound...]);var body=Data()
        if fields["transfer-encoding"]?.lowercased()=="chunked" {
            var pos=0
            while true {
                guard pos<raw.count,let end=raw.range(of:Data("\r\n".utf8),in:pos..<raw.count),end.lowerBound-pos<32,let n=Int(String(decoding:raw[pos..<end.lowerBound],as:UTF8.self).components(separatedBy:";")[0],radix:16),n>=0,n<=130*1024*1024 else{throw TransferError(message:"USB 分块响应损坏。")}
                pos=end.upperBound
                guard pos<=raw.count-2,n<=raw.count-pos-2,raw[pos+n]==13,raw[pos+n+1]==10 else{throw TransferError(message:"USB 下载中断，请重试。")}
                if n==0{break};body.append(raw[pos..<pos+n]);pos+=n+2
            }
        } else {body=raw;if let length=fields["content-length"],Int(length) != raw.count{throw TransferError(message:"USB 文件长度不符。")}}
        guard let response=HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:fields) else{throw TransferError(message:"USB 响应无效。")};return(body,response)
    }
}
