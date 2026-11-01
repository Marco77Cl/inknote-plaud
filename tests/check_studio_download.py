"""Exercise the actual Swift Download class against HTTP failure fixtures."""
from pathlib import Path
import tempfile, threading, http.server, hashlib, subprocess, json, time
root=Path(__file__).resolve().parents[1]
payload=bytes(range(256))*8192
digest=hashlib.sha256(payload).hexdigest()
class Server(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  start=int(self.headers.get('Range','bytes=0-')[6:-1]); data=payload[start:]
  if self.path=='/reject':self.send_response(401);self.end_headers();return
  self.send_response(206 if start else 200)
  self.send_header('X-SHA256','0'*64 if self.path=='/corrupt' else digest)
  if start:self.send_header('Content-Range',f'bytes {start+1 if self.path=="/badrange" else start}-{len(payload)-1}/{len(payload)}')
  self.send_header('Content-Length',str(len(data)));self.end_headers()
  self.wfile.write(data[:65536] if self.path=='/broken' else data);self.wfile.flush();time.sleep(0.3);self.close_connection=True
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Server)
threading.Thread(target=server.serve_forever,daemon=True).start()
s=(root/'apps/inknote-studio/InkNoteStudio.swift').read_text();body=s[s.index('struct TransferError'):s.index('@MainActor final class Studio')]
with tempfile.TemporaryDirectory() as temp:
 d=Path(temp);src=d/'test.swift'
 src.write_text('import Foundation\nimport CryptoKit\n'+body+'''
@main struct Test {
 static func main() async {
  let args=CommandLine.arguments
  let part=URL(fileURLWithPath:args[2]);let offset=((try? FileManager.default.attributesOfItem(atPath:part.path)[.size]) as? NSNumber)?.int64Value ?? 0
  var request=URLRequest(url:URL(string:args[1])!);if offset>0{request.setValue("bytes=\\(offset)-",forHTTPHeaderField:"Range")}
  do { let d=Download(part:part,offset:offset,expected:2097152){_ in};print(try await d.run(request)) }
  catch { print(error.localizedDescription);exit(2) }
 }
}
''')
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/tmp/inknote-swift-cache',str(src),'-o',str(d/'test')],check=True)
 def run(endpoint,path,expected):
  r=subprocess.run([str(d/'test'),f'http://127.0.0.1:{server.server_port}/{endpoint}',str(path)],capture_output=True,text=True,timeout=30)
  assert r.returncode==expected,(endpoint,r.stdout,r.stderr)
 part=d/'audio.part'
 run('broken',part,2);assert 0<part.stat().st_size<len(payload), ('partial_size',part.stat().st_size)
 run('ok',part,0);assert part.read_bytes()==payload
 part2=d/'reject.part';part2.write_bytes(b'keep');run('reject',part2,2);assert part2.read_bytes()==b'keep'
 run('badrange',part2,2);assert part2.read_bytes()==b'keep'
 bad=d/'corrupt.part';run('corrupt',bad,2);assert not bad.exists();assert list(d.glob('corrupt.bad-*'))
 print(json.dumps({'interrupted_resume':'PASS','sha256':'PASS','401_preserves_partial':'PASS','invalid_range_rejected':'PASS','corrupt_quarantined':'PASS'}))
server.shutdown()
