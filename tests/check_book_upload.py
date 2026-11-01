#!/usr/bin/env python3
"""Host integration of actual firmware upload handler; no device required."""
import hashlib, json, pathlib, struct, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
SHIM = r'''
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <fstream>
#include <iterator>
#include <atomic>
#include <sys/stat.h>
#include <CommonCrypto/CommonDigest.h>
using esp_err_t=int;
#define ESP_OK 0
#define MALLOC_CAP_SPIRAM 0
#define MALLOC_CAP_8BIT 0
#define HTTPD_RESP_USE_STRLEN -1
#define ESP_LOGI(...) ((void)0)
#define heap_caps_malloc(n,c) malloc(n)
using mbedtls_sha256_context=CC_SHA256_CTX;
void mbedtls_sha256_init(mbedtls_sha256_context*){}
void mbedtls_sha256_free(mbedtls_sha256_context*){}
void mbedtls_sha256_starts(mbedtls_sha256_context*c,int){CC_SHA256_Init(c);}
void mbedtls_sha256_update(mbedtls_sha256_context*c,const void*p,size_t n){CC_SHA256_Update(c,p,n);}
void mbedtls_sha256_finish(mbedtls_sha256_context*c,unsigned char*p){CC_SHA256_Final(p,c);}
struct httpd_req_t {std::string data,id,hash,status="200 OK",reply;size_t content_len,pos=0;bool auth=true;};
std::atomic<bool> stopping(false);uint8_t buffer[4096];uint8_t *io_buffer=buffer;
void vTaskDelay(int){}
bool authorized(httpd_req_t*r){return r->auth;}
int error(httpd_req_t*r,const char*s,const char*m){r->status=s;r->reply=m;return -1;}
int copy(const std::string&s,char*p,size_t n){if(s.size()>=n)return -1;strcpy(p,s.c_str());return 0;}
int httpd_req_get_url_query_str(httpd_req_t*r,char*p,size_t n){return copy(r->id,p,n);}
int httpd_query_key_value(const char*s,const char*,char*p,size_t n){return copy(s,p,n);}
int httpd_req_get_hdr_value_str(httpd_req_t*r,const char*,char*p,size_t n){return copy(r->hash,p,n);}
int httpd_req_recv(httpd_req_t*r,char*p,size_t n){n=std::min(n,std::min(size_t(37),r->data.size()-r->pos));memcpy(p,r->data.data()+r->pos,n);r->pos+=n;return n;}
void httpd_resp_set_type(httpd_req_t*,const char*){}
int httpd_resp_send(httpd_req_t*r,const char*p,int){r->reply=p;return 0;}
uint32_t u32(const uint8_t*p){return p[0]|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;}
#include "upload.inc"
int main(int argc,char**argv){httpd_req_t r;std::ifstream f(argv[1],std::ios::binary);r.data.assign(std::istreambuf_iterator<char>(f),{});r.id=argv[2];r.hash=argv[3];r.auth=atoi(argv[4]);r.content_len=strtoull(argv[5],0,10);stopping=atoi(argv[6]);book_upload_handler(&r);printf("%s\n%s\n",r.status.c_str(),r.reply.c_str());}
'''
with tempfile.TemporaryDirectory(prefix='booktest-',dir='/tmp') as temp:
    t=pathlib.Path(temp); books=t/'books'; src=ROOT/'apps/inknote-system/main/inknote'
    (t/'upload.inc').write_text((src/'book_upload.inc').read_text().replace('/sdcard/books',str(books)))
    (t/'shim.cc').write_text(SHIM)
    cj=ROOT/'tools/esp-idf/components/json/cJSON'
    subprocess.run(['clang','-c',str(cj/'cJSON.c'),'-o',str(t/'cjson.o')],check=True)
    subprocess.run(['clang++','-std=c++17','-Wno-deprecated-declarations','-I'+str(src),'-I'+str(cj),str(t/'shim.cc'),str(t/'cjson.o'),'-o',str(t/'runner')],check=True)
    base={'version':1,'kind':'book','title':'中文书籍 {"[]"}','author':'','chapters':[{'title':'第一章','offset':0}]}
    def package(text='你好，世界。\n第二段。'.encode(),meta=None):
        m=json.dumps(base if meta is None else meta,ensure_ascii=False,separators=(',',':')).encode()
        return b'INKBOOK1'+struct.pack('<I',len(m))+m+text
    def run(name,payload,code=400,identity=None,digest=None,auth=True,length=None,stop=False):
        ident=identity or hashlib.sha256(payload).hexdigest(); (t/'input').write_bytes(payload)
        output=subprocess.check_output([str(t/'runner'),str(t/'input'),ident,digest or ident,str(int(auth)),str(len(payload) if length is None else length),str(int(stop))],text=True)
        assert output.startswith(str(code)),(name,output)
        assert not list(books.glob('.incoming-*')),(name,'leaked stage')
        if code!=200: assert not (books/ident).exists(),(name,'visible incomplete')
        print('PASS',name);return ident,output
    p=package();ident,_=run('UTF-8 import with fragmented receive',p,200)
    assert (books/ident/'book.txt').read_bytes()=='你好，世界。\n第二段。'.encode()
    assert json.loads((books/ident/'meta.json').read_text())['id']==ident
    (books/ident/'progress.json').write_text('{"offset":9}')
    _,out=run('duplicate preserves progress',p,200);assert 'exists' in out
    assert (books/ident/'progress.json').read_text()=='{"offset":9}'
    stored=json.loads((books/ident/'meta.json').read_text())
    (books/ident/'meta.json').write_text(json.dumps(dict(reversed(list(stored.items()))),ensure_ascii=False,indent=2))
    _,out=run('duplicate accepts reordered TF metadata',p,200);assert 'exists' in out
    run('unauthorized',package(b'auth'),401,auth=False)
    run('invalid id',p,identity='../invalid')
    run('header hash differs',package(b'hash'),digest='a'*64)
    run('computed hash differs',package(b'hash'),identity='b'*64)
    for label,change in [('version',{'version':2}),('kind',{'kind':'other'}),('empty title',{'title':''}),('missing chapters',{'chapters':[]}),('fractional offset',{'chapters':[{'title':'x','offset':0.5}]}),('offset in UTF8',{'chapters':[{'title':'x','offset':0},{'title':'y','offset':1}]}),('unordered offsets',{'chapters':[{'title':'x','offset':0},{'title':'y','offset':0}]})]:
        run(label,package(meta=dict(base,**change)))
    for label,text in [('overlong UTF8',b'\xc0\x80'),('surrogate UTF8',b'\xed\xa0\x80'),('unfinished UTF8',b'\xe4\xbd'),('nul text',b'abc\0def')]:run(label,package(text))
    run('truncated payload',package(b'truncate')[:-2],length=len(package(b'truncate')))
    run('oversize request',b'x',413,length=8*1024*1024+65536+13)
    run('undersize request',b'x',413)
    run('metadata bound',b'INKBOOK1'+struct.pack('<I',65537)+b'a'*65538)
    nested=0
    for _ in range(32): nested=[nested]
    run('deep JSON nesting',package(meta=dict(base,junk=nested)))
    run('cancelled',package(b'cancel'),stop=True)
    assert len(list(books.iterdir()))==1
    # Damaged duplicate must remain untouched and report conflict.
    (books/ident/'book.txt').write_bytes(b'damaged')
    (t/'input').write_bytes(p)
    out=subprocess.check_output([str(t/'runner'),str(t/'input'),ident,ident,'1',str(len(p)),'0'],text=True)
    assert out.startswith('409') and (books/ident/'book.txt').read_bytes()==b'damaged'
    assert not list(books.glob('.incoming-*'));print('PASS damaged duplicate preserves existing file')
print('All upload integration checks passed.')
