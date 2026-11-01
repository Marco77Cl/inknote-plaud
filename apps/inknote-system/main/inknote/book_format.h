#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#include "cJSON.h"

// Shared, bounded wire format. Offsets are UTF-8 byte positions in book.txt.
static constexpr size_t BOOK_MAX_TEXT = 8 * 1024 * 1024;
static constexpr size_t BOOK_MAX_META = 65536;
static inline bool book_id_valid(const char *s) {
    if (!s || strlen(s)!=64) return false;
    for (int i=0;i<64;i++) if (!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f'))) return false;
    return true;
}
struct BookUTF8 {
    unsigned remaining=0; uint32_t value=0, minimum=0;
    bool feed(const uint8_t *p,size_t n) {
        for(size_t i=0;i<n;i++) {
            unsigned c=p[i];
            if(remaining) {
                if((c&0xc0)!=0x80)return false;
                value=(value<<6)|(c&63);
                if(--remaining==0 && (value<minimum || value>0x10ffff || (value>=0xd800&&value<=0xdfff)))return false;
            } else if(c<0x80) { if(c==0)return false; }
            else if(c>=0xc2&&c<=0xdf){remaining=1;value=c&31;minimum=0x80;}
            else if(c>=0xe0&&c<=0xef){remaining=2;value=c&15;minimum=0x800;}
            else if(c>=0xf0&&c<=0xf4){remaining=3;value=c&7;minimum=0x10000;}
            else return false;
        }
        return true;
    }
};
static inline bool book_string_valid(const cJSON *j,size_t max) {
    if(!cJSON_IsString(j)||!j->valuestring||!j->valuestring[0]||strlen(j->valuestring)>max)return false;
    BookUTF8 u;return u.feed((const uint8_t*)j->valuestring,strlen(j->valuestring))&&u.remaining==0;
}
static inline bool book_meta_valid(const cJSON *j,size_t text_size) {
    if(!cJSON_IsObject(j)||!text_size||text_size>BOOK_MAX_TEXT)return false;
    const cJSON *v=cJSON_GetObjectItemCaseSensitive(j,"version"),*kind=cJSON_GetObjectItemCaseSensitive(j,"kind"),*chapters=cJSON_GetObjectItemCaseSensitive(j,"chapters");
    if(!cJSON_IsNumber(v)||v->valuedouble!=1 || !book_string_valid(cJSON_GetObjectItemCaseSensitive(j,"title"),240))return false;
    const cJSON *author=cJSON_GetObjectItemCaseSensitive(j,"author");
    if(!cJSON_IsString(author)||!author->valuestring||strlen(author->valuestring)>240)return false;
    BookUTF8 author_utf8;
    if(!author_utf8.feed((const uint8_t*)author->valuestring,strlen(author->valuestring))||author_utf8.remaining)return false;
    if(!cJSON_IsString(kind)||(strcmp(kind->valuestring,"book")&&strcmp(kind->valuestring,"note")))return false;
    int count=cJSON_GetArraySize(chapters);
    if(!cJSON_IsArray(chapters)||count<1||count>512)return false;
    double previous=-1;
    for(int i=0;i<count;i++) {
        const cJSON *c=cJSON_GetArrayItem(chapters,i),*offset=cJSON_GetObjectItemCaseSensitive(c,"offset");
        if(!book_string_valid(cJSON_GetObjectItemCaseSensitive(c,"title"),240)||!cJSON_IsNumber(offset))return false;
        double n=offset->valuedouble;
        if(!isfinite(n)||floor(n)!=n||n<0||n>=text_size||n<=previous||(i==0&&n!=0))return false;
        previous=n;
    }
    return true;
}

// Bound cJSON recursion on the device's small HTTP/main task stacks.
static inline bool book_json_shallow(const char *text, size_t length) {
    int depth=0; bool quoted=false,escaped=false;
    for(size_t i=0;i<length;i++) {
        char c=text[i];
        if(quoted) {
            if(escaped) escaped=false;
            else if(c=='\\') escaped=true;
            else if(c=='"') quoted=false;
        } else if(c=='"') quoted=true;
        else if(c=='{'||c=='[') { if(++depth>16)return false; }
        else if(c=='}'||c==']') { if(--depth<0)return false; }
    }
    return !quoted && depth==0;
}
