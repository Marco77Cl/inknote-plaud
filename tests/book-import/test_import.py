#!/usr/bin/env python3
"""Native Swift converter integration tests; Python is only the test runner."""
import hashlib,json,pathlib,struct,subprocess,tempfile,unittest,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
class ImportTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.temp=tempfile.TemporaryDirectory();cls.root=pathlib.Path(cls.temp.name);cls.runner=cls.root/'importer'
  subprocess.run(['swiftc','-swift-version','5','-module-cache-path','/tmp/inknote-swift-cache',str(ROOT/'apps/inknote-studio/BookImport.swift'),str(ROOT/'tests/book-import/Runner.swift'),'-o',str(cls.runner)],check=True)
 @classmethod
 def tearDownClass(cls):cls.temp.cleanup()
 def convert(self,path,ok=True):
  out=self.root/'out.inkbook';r=subprocess.run([str(self.runner),str(path),str(out)],capture_output=True,text=True)
  self.assertEqual(r.returncode==0,ok,r.stderr)
  if not ok:return
  data=out.read_bytes();self.assertEqual(data[:8],b'INKBOOK1');self.assertEqual(r.stdout.strip(),hashlib.sha256(data).hexdigest());n=struct.unpack('<I',data[8:12])[0]
  return json.loads(data[12:12+n]),data[12+n:]
 def epub(self,extra=None,layout='',spine='b a'):
  p=self.root/'test.epub'
  files={'META-INF/container.xml':'<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>', 'OPS/book.opf':f'<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>中文书名</dc:title><dc:creator>作者</dc:creator>{layout}</metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest><spine>'+''.join(f'<itemref idref="{i}"/>' for i in spine.split())+'</spine></package>','OPS/a.xhtml':'<html><head><title>第一章</title></head><body><p>你好 &amp; 世界</p><img alt="测试图片"/></body></html>','OPS/b.xhtml':'<html><head><title>第二章</title></head><body><p>先读这里。</p><script>HIDDEN</script></body></html>'}
  files.update(extra or {})
  with zipfile.ZipFile(p,'w',zipfile.ZIP_DEFLATED) as z:
   for name,value in files.items():z.writestr(name,value)
  return p
 def test_spine_offsets_metadata(self):
  meta,text=self.convert(self.epub());self.assertEqual(meta['title'],'中文书名');self.assertEqual(meta['author'],'作者');self.assertTrue(text.decode().startswith('先读这里。'));self.assertNotIn('HIDDEN',text.decode());self.assertEqual([x['title'] for x in meta['chapters']],['第二章','第一章']);self.assertEqual(meta['chapters'][0]['offset'],0);self.assertTrue(text[meta['chapters'][1]['offset']:].decode().startswith('你好 & 世界'));self.assertIn('[插图：测试图片]',text.decode())
 def test_traversal(self):self.convert(self.epub({'../escape':'bad'}),False)
 def test_drm(self):self.convert(self.epub({'META-INF/encryption.xml':'<encryption/>'}),False)
 def test_fixed_layout(self):self.convert(self.epub(layout='<meta property="rendition:layout">pre-paginated</meta>'),False)
 def test_corrupt(self):
  p=self.root/'bad.epub';p.write_bytes(b'not a zip'*10);self.convert(p,False)
 def test_missing_spine(self):self.convert(self.epub(spine='missing'),False)
 def test_entities(self):self.convert(self.epub({'OPS/b.xhtml':'<!DOCTYPE html [<!ENTITY secret SYSTEM "file:///etc/passwd">]><html><body>&secret;</body></html>'}),False)
 def test_txt_encodings(self):
  for encoding in ['utf-8','utf-16']:
   p=self.root/'中文.txt';p.write_bytes('中文正文\r\n第二段'.encode(encoding));meta,text=self.convert(p);self.assertEqual(text.decode(),'中文正文\n第二段');self.assertEqual(meta['chapters'][0]['offset'],0)
 def test_bad_encoding(self):
  p=self.root/'bad.txt';p.write_bytes(b'\x81\x82\x83');self.convert(p,False)
 def test_long_chinese_metadata(self):
  p=self.epub();
  with zipfile.ZipFile(p) as z:files={n:z.read(n) for n in z.namelist()}
  files['OPS/book.opf']=files['OPS/book.opf'].replace('中文书名'.encode(),('长'*120).encode())
  with zipfile.ZipFile(p,'w') as z:
   for n,v in files.items():z.writestr(n,v)
  meta,text=self.convert(p);self.assertEqual(len(meta['title'].encode()),240)
 def test_nul(self):
  p=self.root/'nul.txt';p.write_bytes(b'abc\0def');self.convert(p,False)
 def test_item_fixed(self):
  p=self.epub();
  with zipfile.ZipFile(p) as z:files={n:z.read(n) for n in z.namelist()}
  files['OPS/book.opf']=files['OPS/book.opf'].replace(b'<itemref idref="b"',b'<itemref properties="rendition:layout-pre-paginated" idref="b"')
  with zipfile.ZipFile(p,'w') as z:
   for n,v in files.items():z.writestr(n,v)
  self.convert(p,False)
 def test_empty(self):
  p=self.root/'empty.txt';p.write_bytes(b' \n');self.convert(p,False)
if __name__=='__main__':unittest.main()
