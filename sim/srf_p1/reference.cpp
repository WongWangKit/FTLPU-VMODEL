#include "ftlpu/core/stream_port.hpp"
#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>
#include <array>
#include <limits>

using namespace ftlpu;
constexpr int H=2, D=2, C=16, T=4, S=32, L=8;
static_assert(hw::kHemispheres==H && hw::kTileRows==T && hw::kLanesPerTile==L);
static_assert(hw::kStreamsPerDirection==S && hw::kSystemStreamRegisterColumns==C);
static_assert(hw::kStreamRegisterBytes==1 && std::numeric_limits<uint8_t>::digits==8);
static_assert(hw::kTargetName=="ftlpu-lpu32");
struct Event { int h,d,c,t,slot,s; uint64_t data; };
StreamId sid(int d,int s) { return d==0 ? StreamId::East(s) : StreamId::West(s); }
int si(int h,int d,int c,int t,int s) { return ((((h*D+d)*C+c)*T+t)*S+s); }
int bi(int h,int d,int t,int s) { return (((h*D+d)*T+t)*S+s); }
void require(bool ok,const char* msg) { if(!ok) throw std::runtime_error(msg); }
uint64_t payload(const StreamTileSegment& seg) {
    uint64_t x=0; for(int l=0;l<L;++l) x|=uint64_t(seg[l].data)<<(l*8); return x;
}
std::string bits(const std::vector<bool>& v) {
    static const char* hex="0123456789abcdef";
    std::string r((v.size()+3)/4,'0');
    for(size_t n=0;n<r.size();++n) { int x=0; for(int b=0;b<4;++b)
        if(n*4+b<v.size() && v[n*4+b]) x|=1<<b;
        r[r.size()-1-n]=hex[x]; }
    return r;
}
std::string words(const std::vector<uint64_t>& v) {
    static const char* hex="0123456789abcdef";
    std::string r(v.size()*16,'0');
    for(size_t n=0;n<v.size();++n) for(int b=0;b<16;++b)
        r[r.size()-1-(n*16+b)]=hex[(v[n]>>(b*4))&15];
    return r;
}
void api_checks() {
    StreamRegisterFabric f(C); auto id=StreamId::East(0);
    StreamInputPort in(f,0,StreamDirection::East,"api-check");
    f.begin_cycle(); require(!in.consume_cell(0,0,0).valid,"conditional consume invalid");
    f.stage_write(0,0,0,id,StreamCell::Valid(0x51));
    f.stage_write(0,0,0,id,StreamCell::Invalid());
    StreamTileSegment empty{}; f.stage_segment(0,0,id,empty);
    f.stage_write(0,0,1,id,StreamCell::Invalid());
    f.stage_write(0,0,1,id,StreamCell::Valid(0xA2));
    f.commit_cycle(); require(f.cell(0,0,0,id).data==0x51 && f.cell(0,0,0,id).valid,"invalid overwrite");
    require(f.cell(0,0,1,id).data==0xA2 && f.cell(0,0,1,id).valid,"invalid then valid");
    require(!f.segment_valid(0,0,id),"partial is not segment-valid");
    f.begin_cycle(); bool duplicate=false;
    f.stage_write(0,0,0,id,StreamCell::Valid(7)); empty[0]=StreamCell::Valid(7);
    try { f.stage_segment(0,0,id,empty); } catch(const std::logic_error&) { duplicate=true; }
    require(duplicate,"cross-API duplicate not rejected"); f.reset();
    f.begin_cycle(); bool bad=false;
    try { f.consume_segment(0,0,id); } catch(const std::logic_error&) { bad=true; }
    require(bad,"direct invalid consume not rejected"); f.reset();
    std::cout<<"REFERENCE_API_CHECKS PASS\n";
}
int main(int argc,char** argv) try {
    require(argc==3,"usage: reference vectors.txt expected.txt"); api_checks();
    std::ifstream input(argv[1]); std::ofstream out(argv[2]); require(bool(input)&&bool(out),"open failed");
    std::array<StreamRegisterFabric,H> f{StreamRegisterFabric(C),StreamRegisterFabric(C)};
    int seq,rst,nb,ni,nc,count=0; bool needs_reset=false;
    while(input>>seq>>rst>>nb>>ni>>nc) {
        require(seq==count,"nonsequential vector");
        require(!needs_reset || rst,"exception must end epoch");
        if(rst) { for(auto& x:f) x.reset(); needs_reset=false; }
        std::vector<Event> boundary,inject,consume;
        for(int i=0;i<nb;++i) { Event e{}; input>>e.h>>e.d>>e.t>>e.s>>std::hex>>e.data>>std::dec;
            e.c=e.d==0?0:C-1; boundary.push_back(e); }
        for(int i=0;i<ni;++i) { Event e{}; input>>e.h>>e.d>>e.c>>e.t>>e.slot>>e.s>>std::hex>>e.data>>std::dec; inject.push_back(e); }
        for(int i=0;i<nc;++i) { Event e{}; input>>e.h>>e.d>>e.c>>e.t>>e.slot>>e.s; consume.push_back(e); }
        require(bool(input),"truncated input");
        std::vector<bool> used(H*D*C*T*S,false),bv(H*D*T*S,false),sv(H*D*C*T*S,false);
        std::vector<uint64_t> bd(H*D*T*S,0),sd(H*D*C*T*S,0);
        for(auto e:consume) used.at(si(e.h,e.d,e.c,e.t,e.s))=true;
        for(int h=0;h<H;++h) for(int d=0;d<D;++d) for(int t=0;t<T;++t) for(int s=0;s<S;++s) {
            int c=d==0?C-1:0,b=bi(h,d,t,s);
            bv[b]=f[h].segment_valid(c,t,sid(d,s))&&!used[si(h,d,c,t,s)];
            if(bv[b]) bd[b]=payload(f[h].segment(c,t,sid(d,s)));
        }
        std::string error="none";
        for(auto& x:f) x.begin_cycle();
        try {
            for(auto e:consume) f.at(e.h).consume_segment(e.c,e.t,sid(e.d,e.s),"compat consumer");
            auto stage=[&](Event e){ StreamPayloadTileSegment data{};
                for(int l=0;l<L;++l) data[l]=(e.data>>(l*8))&255;
                f.at(e.h).stage_payload_segment(e.c,e.t,sid(e.d,e.s),data,0,"compat producer"); };
            for(auto e:boundary) stage(e); for(auto e:inject) stage(e);
            for(auto& x:f) x.stage_linear_links();
        } catch(const std::logic_error& ex) {
            std::string msg=ex.what();
            if(msg.find("write collision")!=std::string::npos) error="collision";
            else if(msg.find("read of invalid")!=std::string::npos) error="invalid";
            else throw;
            needs_reset=true;
        }
        if(error=="none") {
            for(auto& x:f) x.commit_cycle();
            for(int h=0;h<H;++h) for(int d=0;d<D;++d) for(int c=0;c<C;++c)
            for(int t=0;t<T;++t) for(int s=0;s<S;++s) {
                int n=si(h,d,c,t,s); sv[n]=f[h].segment_valid(c,t,sid(d,s));
                if(sv[n]) sd[n]=payload(f[h].segment(c,t,sid(d,s)));
            }
        }
        out<<seq<<' '<<error<<' '<<bits(bv)<<' '<<words(bd)<<' '<<bits(sv)<<' '<<words(sd)<<'\n';
        ++count;
    }
    require(count>0,"empty vector file");
    std::cout<<"REFERENCE_COMPLETE cycles="<<count<<" H=2 C=16 T=4 S=32 L=8 B=8\n";
    return 0;
} catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
