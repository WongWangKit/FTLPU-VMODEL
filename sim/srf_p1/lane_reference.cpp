#include "ftlpu/core/stream_port.hpp"
#include <array>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <vector>
#include <stdexcept>
using namespace ftlpu;
constexpr int H=2,C=16,T=4,S=32,L=8;
static_assert(hw::kHemispheres==H && hw::kTileRows==T && hw::kLanesPerTile==L);
static_assert(hw::kStreamsPerDirection==S && hw::kSystemStreamRegisterColumns==C);
static_assert(hw::kStreamRegisterBytes==1 && hw::kTargetName=="ftlpu-lpu32");
struct E {int h=0,d=0,c=0,t=0,p=0,s=0,api=0; unsigned mask=0; uint64_t data=0;};
using Key=std::array<int,6>; // h,d,c,t,s,l (not RTL bus index)
using State=std::map<Key,uint8_t>;
StreamId id(E e){return e.d==0?StreamId::East(e.s):StreamId::West(e.s);}
Key key(E e,int l){return {e.h,e.d,e.c,e.t,e.s,l};}
int fault(Key q){return ((q[0]*2+q[1])*C+q[2])*T+q[3];}
void need(bool b,const char* s){if(!b)throw std::runtime_error(s);}
std::string hex_fault(const std::set<int>& v){std::string r(64,'0');const char* x="0123456789abcdef";
 for(int f:v){int p=63-f/4; int old=r[p]<='9'?r[p]-'0':r[p]-'a'+10;r[p]=x[old|(1<<(f%4))];}return r;}
std::vector<E> pack(const State& st,bool boundary){
 std::map<std::array<int,5>,E> groups;
 for(auto [q,v]:st){auto k=std::array<int,5>{q[0],q[1],q[2],q[3],q[4]}; auto& e=groups[k];
  e.h=q[0];e.d=q[1];e.c=q[2];e.t=q[3];e.s=q[4];e.mask|=1u<<q[5];e.data|=uint64_t(v)<<(8*q[5]);}
 std::vector<E> r;for(auto [q,e]:groups)r.push_back(e);return r;
}
void emit(std::ostream& o,E e,int kind){
 o<<e.h<<' '<<e.d<<' '; if(kind!=0)o<<e.c<<' ';o<<e.t<<' ';
 if(kind==1 || kind==2)o<<e.p<<' ';o<<e.s<<' '<<std::hex<<e.mask<<' ';
 if(kind!=2)o<<e.data<<' ';o<<std::dec;
 if(kind<3)o<<e.api; o<<'\n';
}
int main(int argc,char** argv)try{
 need(argc==3,"usage lane_reference input compiled_vectors");
 std::ifstream in(argv[1]);std::ofstream out(argv[2]);need(bool(in)&&bool(out),"open input/output");
 std::array<StreamRegisterFabric,H> f{StreamRegisterFabric(C),StreamRegisterFabric(C)};
 State state;int seq,rst,nb,ni,nc,negative,n=0,errors=0;bool reset_required=false;
 while(in>>seq>>rst>>nb>>ni>>nc>>negative){
  need(seq==n,"cycle identity");need(!reset_required||rst,"exception epoch not reset");
  if(rst){for(auto& x:f)x.reset();state.clear();reset_required=false;}
  std::vector<E> b(nb),inj(ni),con(nc);
  for(auto& e:b){in>>e.h>>e.d>>e.t>>e.s>>std::hex>>e.mask>>e.data>>std::dec>>e.api;e.c=e.d==0?0:C-1;}
  for(auto& e:inj)in>>e.h>>e.d>>e.c>>e.t>>e.p>>e.s>>std::hex>>e.mask>>e.data>>std::dec>>e.api;
  for(auto& e:con)in>>e.h>>e.d>>e.c>>e.t>>e.p>>e.s>>std::hex>>e.mask>>std::dec>>e.api;
  need(bool(in),"truncated vector");
  std::set<Key> consumed;std::set<int> collision,invalid;std::map<Key,std::vector<uint8_t>> candidates;
  for(auto e:con)for(int l=0;l<L;++l)if((e.mask>>l)&1){auto k=key(e,l);
   if(e.api==2 && !state.contains(k))continue;
   consumed.insert(k);if(!state.contains(k))invalid.insert(fault(k));}
  State boundary;
  for(auto [k,v]:state)if(!consumed.contains(k)){
   auto q=k;q[2]+=k[1]==0?1:-1;
   if(q[2]<0||q[2]>=C)boundary[k]=v;else candidates[q].push_back(v);}
  for(auto list:{b,inj})for(auto e:list)for(int l=0;l<L;++l)if((e.mask>>l)&1)
   candidates[key(e,l)].push_back(uint8_t(e.data>>(l*8)));
  State predicted;
  for(auto [k,v]:candidates)if(v.size()==1)predicted[k]=v[0];else collision.insert(fault(k));
  need(bool(!collision.empty()||!invalid.empty())==bool(negative),"independent legality/negative mismatch");
  for(auto& x:f)x.begin_cycle();std::string error="none";
  try{
   for(auto e:con){auto& ff=f.at(e.h);StreamInputPort port(ff,e.c,id(e).direction(),"lane helper");
    if(e.api==1){need(e.mask==255,"consume_segment requires FF");ff.consume_segment(e.c,e.t,id(e));}
    else for(int l=0;l<L;++l)if((e.mask>>l)&1){
     if(e.api==2)port.consume_cell(e.t,l,e.s);else ff.consume(e.c,e.t,l,id(e));}}
   auto stage=[&](E e){auto& ff=f.at(e.h);StreamTileSegment seg{};StreamPayloadTileSegment data{};
    for(int l=0;l<L;++l){data[l]=uint8_t(e.data>>(l*8));if((e.mask>>l)&1)seg[l]=StreamCell::Valid(data[l],false,seq+1);}
    StreamOutputPort port(ff,e.c,id(e).direction(),"lane output helper");
    if(e.api==1)ff.stage_segment(e.c,e.t,id(e),seg);
    else if(e.api==2){need(e.mask==255,"payload segment requires FF");ff.stage_payload_segment(e.c,e.t,id(e),data);}
    else if(e.api==5)port.write_segment(e.t,e.s,seg);
    else if(e.api==6){need(e.mask==255,"port payload requires FF");port.write_payload_segment(e.t,e.s,data);}
    else for(int l=0;l<L;++l){
     if(e.api==4)ff.stage_write(e.c,e.t,l,id(e),StreamCell::Invalid());
     ff.stage_write(e.c,e.t,l,id(e),seg[l]);
     if(e.api==3)ff.stage_write(e.c,e.t,l,id(e),StreamCell::Invalid());
    }};
   for(auto e:b)stage(e);for(auto e:inj)stage(e);for(auto& x:f)x.stage_linear_links();
  }catch(const std::logic_error& ex){std::string s=ex.what();
   if(s.find("write collision")!=std::string::npos)error="collision";
   else if(s.find("read of invalid")!=std::string::npos)error="invalid";else throw;
   reset_required=true;++errors;}
  need((error!="none")==bool(negative),"CModel exception mismatch");
  if(negative)need(error==(!invalid.empty()?"invalid":"collision"),"CModel first exception category mismatch");
  if(!negative){for(auto& x:f)x.commit_cycle();State actual;
   for(int h=0;h<H;++h)for(int d=0;d<2;++d)for(int c=0;c<C;++c)for(int t=0;t<T;++t)for(int s=0;s<S;++s)for(int l=0;l<L;++l){
    E e;e.h=h;e.d=d;e.c=c;e.t=t;e.s=s;auto v=f[h].cell(c,t,l,id(e));if(v.valid)actual[key(e,l)]=v.data;}
   need(actual==predicted,"CModel state disagrees with independent coordinate oracle");state=std::move(actual);
  }else state=predicted; // RTL safety policy only; never commit the exceptional CModel.
  auto bo=pack(boundary,true),post=pack(state,false);
  out<<seq<<' '<<rst<<' '<<nb<<' '<<ni<<' '<<nc<<' '<<bo.size()<<' '<<post.size()<<' '<<hex_fault(collision)<<' '<<hex_fault(invalid)<<' '<<error<<'\n';
  for(auto e:b)emit(out,e,0);for(auto e:inj)emit(out,e,1);for(auto e:con)emit(out,e,2);
  for(auto e:bo){out<<e.h<<' '<<e.d<<' '<<e.t<<' '<<e.s<<' '<<std::hex<<e.mask<<' '<<e.data<<std::dec<<'\n';}
  for(auto e:post)emit(out,e,3);
  ++n;
 }
 need(n>0,"empty input");std::cout<<"LANE_REFERENCE PASS cycles="<<n<<" negative="<<errors<<"\n";
 return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
