// Included by sync_transfer.cc to share the authenticated transfer session.
#include "book_format.h"
#include <unistd.h>
#include <errno.h>
static bool book_recv(httpd_req_t *r,uint8_t *out,size_t length,mbedtls_sha256_context *sha) {
    size_t used=0;
    while(used<length && !stopping.load()) {
        int n=httpd_req_recv(r,(char*)out+used,length-used);
        if(n<=0)return false;
        mbedtls_sha256_update(sha,out+used,n);used+=n;
    }
    return used==length;
}
static void book_clean_stage(const char *dir) {
    char path[180];
    snprintf(path,sizeof(path),"%s/book.txt",dir);unlink(path);
    snprintf(path,sizeof(path),"%s/meta.json",dir);unlink(path);
    rmdir(dir);
}
static esp_err_t book_upload_handler(httpd_req_t *r) {
    if(!authorized(r))return error(r,"401 Unauthorized","Pair device first");
    char query[96]={0},id[65]={0},expected[65]={0};
    if(httpd_req_get_url_query_str(r,query,sizeof(query))!=ESP_OK || httpd_query_key_value(query,"id",id,sizeof(id))!=ESP_OK || !book_id_valid(id)
       || httpd_req_get_hdr_value_str(r,"X-SHA256",expected,sizeof(expected))!=ESP_OK || strcmp(id,expected))
        return error(r,"400 Bad Request","Invalid book id or hash");
    if(r->content_len<15 || r->content_len>BOOK_MAX_TEXT+BOOK_MAX_META+12)return error(r,"413 Payload Too Large","Book exceeds limit");
    if(mkdir("/sdcard/books",0775)!=0 && errno!=EEXIST)return error(r,"503 Service Unavailable","TF unavailable");
    char stage[160],dest[160],path[180];
    snprintf(stage,sizeof(stage),"/sdcard/books/.incoming-%s",id);
    snprintf(dest,sizeof(dest),"/sdcard/books/%s",id);
    book_clean_stage(stage);
    if(mkdir(stage,0775)!=0)return error(r,"503 Service Unavailable","Cannot create staging directory");
    mbedtls_sha256_context sha;mbedtls_sha256_init(&sha);mbedtls_sha256_starts(&sha,0);
    const char *status="400 Bad Request",*message="Invalid book package";
    cJSON *meta=nullptr;uint8_t *metadata=nullptr;FILE *file=nullptr;bool ok=false,exists=false;
    do {
        uint8_t header[12];
        if(!book_recv(r,header,sizeof(header),&sha)){message="Upload interrupted";break;}
        uint32_t m=u32(header+8);
        if(memcmp(header,"INKBOOK1",8)||m<2||m>BOOK_MAX_META||r->content_len<=12+m)break;
        size_t text_size=r->content_len-12-m;
        if(text_size>BOOK_MAX_TEXT)break;
        metadata=(uint8_t*)heap_caps_malloc(m+1,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
        if(!metadata){status="503 Service Unavailable";message="Memory unavailable";break;}
        if(!book_recv(r,metadata,m,&sha)){message="Upload interrupted";break;}
        metadata[m]=0;
        if(memchr(metadata,0,m)||!book_json_shallow((char*)metadata,m))break;
        meta=cJSON_ParseWithLengthOpts((char*)metadata,m+1,nullptr,true);
        if(!book_meta_valid(meta,text_size))break;
        snprintf(path,sizeof(path),"%s/book.txt",stage);file=fopen(path,"wb");
        if(!file){status="507 Insufficient Storage";message="Cannot write book";break;}
        BookUTF8 utf8;size_t left=text_size;bool failed=false;
        while(left) {
            size_t n=left>4096?4096:left;
            if(!book_recv(r,io_buffer,n,&sha)||!utf8.feed(io_buffer,n)||fwrite(io_buffer,1,n,file)!=n){failed=true;break;}
            left-=n;vTaskDelay(1);
        }
        int flushed=fflush(file);int closed=fclose(file);file=nullptr;
        if(failed||utf8.remaining||flushed||closed){message="Incomplete, invalid UTF-8, or TF write failed";break;}
        uint8_t digest[32];char hex[65];mbedtls_sha256_finish(&sha,digest);
        for(int i=0;i<32;i++)snprintf(hex+i*2,3,"%02x",digest[i]);
        if(strcmp(hex,expected)){message="SHA-256 mismatch";break;}
        // A chapter may not begin in the middle of a UTF-8 code point.
        file=fopen(path,"rb");if(!file)break;
        cJSON *chapters=cJSON_GetObjectItemCaseSensitive(meta,"chapters");
        for(int i=0;i<cJSON_GetArraySize(chapters);i++) {
            long off=(long)cJSON_GetObjectItemCaseSensitive(cJSON_GetArrayItem(chapters,i),"offset")->valuedouble;
            if(fseek(file,off,SEEK_SET)!=0){failed=true;break;}
            int ch=fgetc(file);if(ch<0||(ch&0xc0)==0x80){failed=true;break;}
        }
        fclose(file);file=nullptr;if(failed)break;
        cJSON_DeleteItemFromObjectCaseSensitive(meta,"id");
        if(!cJSON_AddStringToObject(meta,"id",id)){status="503 Service Unavailable";message="Memory unavailable";break;}
        char *serialized=cJSON_PrintUnformatted(meta);if(!serialized)break;
        snprintf(path,sizeof(path),"%s/meta.json",stage);file=fopen(path,"wb");
        if(!file){free(serialized);break;}
        size_t len=strlen(serialized);bool written=fwrite(serialized,1,len,file)==len;free(serialized);
        flushed=fflush(file);closed=fclose(file);file=nullptr;if(!written||flushed||closed)break;
        if(stopping.load()){message="Upload cancelled";break;}
        struct stat st;
        if(stat(dest,&st)==0) {
            // Immutable content id: re-sending does not reset progress/bookmarks.
            // Validate stored files byte-for-byte before reporting already present.
            const char *names[]={"book.txt"};bool identical=true;
            for(const char *name:names) {
                char a[180],b[180];snprintf(a,sizeof(a),"%s/%s",stage,name);snprintf(b,sizeof(b),"%s/%s",dest,name);
                FILE *fa=fopen(a,"rb"),*fb=fopen(b,"rb");
                if(!fa||!fb)identical=false;
                if(fa&&fb){
                    uint8_t compare[512];
                    while(!stopping.load()) {
                        size_t na=fread(io_buffer,1,sizeof(compare),fa),nb=fread(compare,1,sizeof(compare),fb);
                        if(na!=nb||memcmp(io_buffer,compare,na)){identical=false;break;}
                        if(na<sizeof(compare))break;
                        vTaskDelay(1);
                    }
                    if(stopping.load()||ferror(fa)||ferror(fb))identical=false;
                }
                if(fa)fclose(fa);
                if(fb)fclose(fb);
            }
            // TF exports may use a different JSON key order or whitespace.
            snprintf(path,sizeof(path),"%s/meta.json",dest);
            FILE *stored=fopen(path,"rb");
            cJSON *existing_meta=nullptr;
            if(stored) {
                if(fseek(stored,0,SEEK_END)==0) {
                    long size=ftell(stored);
                    if(size>0&&size<=(long)BOOK_MAX_META+128&&fseek(stored,0,SEEK_SET)==0) {
                        char *raw=(char*)heap_caps_malloc(size+1,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
                        if(raw) {
                            if(fread(raw,1,size,stored)==(size_t)size&&!memchr(raw,0,size)&&book_json_shallow(raw,size)) {
                                raw[size]=0;existing_meta=cJSON_ParseWithLengthOpts(raw,size+1,nullptr,true);
                            }
                            free(raw);
                        }
                    }
                }
                fclose(stored);
            }
            if(!existing_meta||!cJSON_Compare(existing_meta,meta,true))identical=false;
            cJSON_Delete(existing_meta);
            if(!identical){status="409 Conflict";message="Existing book is damaged; preserve it and use TF repair";break;}
            exists=true;
        } else if(rename(stage,dest)!=0){status="507 Insufficient Storage";message="Cannot commit book";break;}
        ok=true;
    }while(false);
    if(file)fclose(file);
    free(metadata);cJSON_Delete(meta);mbedtls_sha256_free(&sha);book_clean_stage(stage);
    if(!ok)return error(r,status,message);
    char reply[220];snprintf(reply,sizeof(reply),"{\"id\":\"%s\",\"sha256\":\"%s\",\"status\":\"%s\"}",id,id,exists?"exists":"saved");
    httpd_resp_set_type(r,"application/json");
    ESP_LOGI(TAG,"BOOK saved id=%s existing=%d",id,exists);
    return httpd_resp_send(r,reply,HTTPD_RESP_USE_STRLEN);
}
