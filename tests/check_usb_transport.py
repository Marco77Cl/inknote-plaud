"""Exercise the real Swift USB client over a pseudoterminal, including HTTP framing."""
import select
import os,pty,subprocess,tempfile,pathlib,threading,time,base64,hashlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
 t=pathlib.Path(tmp)
 (t/'runner.swift').write_text('''import Foundation
struct TransferError:LocalizedError{let message:String;var errorDescription:String?{message}}
@main struct Test {static func main(){do{let usb=try USBTransport(path:CommandLine.arguments[1]);let token=try usb.hello();guard token==String(repeating:"a",count:32) else{exit(3)};var req=URLRequest(url:URL(string:"http://inknote-usb:8081/api/books?id=test")!);req.httpMethod="POST";req.httpBody=Data((0..<4097).map{UInt8($0%251)});req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");let (data,response)=try usb.request(req);print(response.statusCode);print(data.base64EncodedString())}catch{print(error.localizedDescription);exit(2)}}}
''')
 subprocess.run(['swiftc','-swift-version','5','-module-cache-path','/tmp/inknote-swift-cache',str(ROOT/'apps/inknote-studio/USBTransport.swift'),str(t/'runner.swift'),'-o',str(t/'runner')],check=True)
 payload=bytes(range(251))*20
 def case(mode,success=True):
  master,slave=pty.openpty();path=os.ttyname(slave);done=threading.Event();received=bytearray();state={'response':b'', 'wait':True}
  def serve():
   pending=b''
   while not done.is_set():
    try:
     if not select.select([master],[],[],0.1)[0]:continue
     incoming=os.read(master,4096)
     if not incoming:break
    except OSError:break
    pending+=incoming
    while b'\n' in pending:
     line,pending=pending.split(b'\n',1);parts=line.strip().split(b' ',3)
     if len(parts)<3 or parts[0]!=b'INKUSB1':continue
     seq,op=parts[1:3];status=b'OK';arg=b''
     if op==b'HELLO':arg=b'a'*32
     elif op==b'OPEN':received.clear()
     elif op==b'WRITE':
      received.extend(base64.b64decode(parts[3]))
      if b'\r\n\r\n' in received:
       h,b=bytes(received).split(b'\r\n\r\n',1)
       if len(b)==4097:
        assert b==bytes(i%251 for i in range(4097))
        assert b'Authorization: Bearer '+b'a'*32 in h
        if mode=='chunked':state['response']=b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'+hex(len(payload))[2:].encode()+b'\r\n'+payload+b'\r\n0\r\n\r\n'
        elif mode=='broken':state['response']=b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nshort'
        elif mode=='length':state['response']=b'HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\nshort'
        else:state['response']=b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(payload)).encode()+b'\r\n\r\n'+payload
     elif op==b'READ':
      if state['wait']:status=b'WAIT';state['wait']=False
      elif state['response']:status=b'DATA';arg=base64.b64encode(state['response'][:513]);state['response']=state['response'][513:]
      else:status=b'WAIT' if mode in ['chunked','plain'] else b'EOF'
     os.write(master,b'I (123) unrelated device log\r\nINKUSB1 '+seq+b' '+status+b' '+arg+b'\r\n')
  worker=threading.Thread(target=serve,daemon=True);worker.start()
  result=subprocess.run([str(t/'runner'),path],capture_output=True,text=True,timeout=25)
  done.set();worker.join(timeout=2);os.close(master);os.close(slave)
  assert (result.returncode==0)==success,(mode,result.stdout,result.stderr)
  if success:assert base64.b64decode(result.stdout.splitlines()[1])==payload
  print('PASS USB',mode,'upload bytes, framing and response checks')
 for mode in ['chunked','plain','broken','length']:case(mode,mode in ['chunked','plain'])
