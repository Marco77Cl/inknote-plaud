#include "sherpa-onnx/c-api/cxx-api.h"
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <map>
int main(int argc,char **argv) {
 if(argc!=6){fprintf(stderr,"usage: speaker-cli segmentation embedding wav speakers output\n");return 2;}
 using namespace sherpa_onnx::cxx;
 auto wave=ReadWave(argv[3]);
 if(wave.samples.empty() || wave.sample_rate!=16000){fprintf(stderr,"Expected non-empty 16kHz WAV\n");return 3;}
 OfflineSpeakerDiarizationConfig cfg;
 cfg.segmentation.pyannote.model=argv[1];cfg.segmentation.num_threads=2;
 cfg.embedding.model=argv[2];cfg.embedding.num_threads=2;
 cfg.clustering.num_clusters=atoi(argv[4]);cfg.clustering.threshold=0.7;
 cfg.min_duration_on=0.3;cfg.min_duration_off=0.5;
 auto sd=OfflineSpeakerDiarization::Create(cfg);
 if(!sd.Get()){fprintf(stderr,"Cannot create speaker model\n");return 4;}
 auto result=sd.Process(wave.samples.data(),wave.samples.size(),[](int done,int total){fprintf(stderr,"progress = %d%%\n",total?done*100/total:0);});
 std::sort(result.begin(),result.end(),[](const auto&a,const auto&b){return a.start<b.start;});
 FILE *out=fopen(argv[5],"w");if(!out)return 5;
 fprintf(out,"[");std::map<int,int> speakers;bool first=true;
 for(const auto&s:result){if(!speakers.count(s.speaker))speakers[s.speaker]=speakers.size()+1;
  fprintf(out,"%s{\"startMS\":%d,\"endMS\":%d,\"speaker\":%d}",first?"":",",(int)(s.start*1000),(int)(s.end*1000),speakers[s.speaker]);first=false;}
 fprintf(out,"]\n");fclose(out);return 0;
}
