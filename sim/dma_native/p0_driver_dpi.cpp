// XSim samples the real IP pins and forwards their handshakes to this runtime client.
#include "ftlpu/software/runtime/static_weight_port.hpp"
#include <cstdio>
using namespace ftlpu;
using namespace ftlpu::software::runtime;
namespace {
StaticWeightPort host;
std::unique_ptr<WeightDmaCalendar> issuer;
WeightDmaCalendar::Command cmd{};
std::uint64_t next_window=0;
WeightPageId id(int page){return {11,0x100000000ull+unsigned(page)};}
}
#define API extern "C" __declspec(dllexport) int
#define FAIL catch(const std::exception& e){std::fprintf(stderr,"DPI weight driver: %s\n",e.what());return -1;}
API ip_can_bind(int gen){return host.may_bind(gen);}
API ip_bind(int image,int empty)try{
    host.bound(11,image);issuer.reset();
    if(!empty)return 1;
    auto p=read_binary_program(std::filesystem::path("a.ftlpu"));
    p.queues.clear(); // Exact active compute image at these two bindings: END only.
    issuer=std::make_unique<WeightDmaCalendar>(p,11,image);next_window=0;return 1;
}FAIL
API ip_reserve(int page,int src,int users)try{
    WeightPageRequest req{id(page),{}};
    for(unsigned j=0;j<2;j++)
        req.segments.push_back({{unsigned(src)+j*hw::kPhysicalVectorBytes,1,0,0,1,3+j,31},
                                 3,hw::kPhysicalVectorBytes,1});
    return host.reserve(0,req,users);
}FAIL
API ip_offer(int tag,int edge)try{
    issuer->advance(edge);
    auto first=std::max(next_window,std::uint64_t(edge)+20);
    cmd=host.offer(0,*issuer,tag,first,first+180);next_window=first+180;return 1;
}FAIL
API ip_word(int i){return static_cast<int>(cmd.at(i));}
API ip_mask(int i)try{return static_cast<int>(host.bank_mask(0,52).at(i));}FAIL
API ip_handshake(int rejected)try{host.handshake(rejected);return 1;}FAIL
API ip_result(int tag,int error,int resident)try{host.result(tag,error,resident);return 1;}FAIL
API ip_published(int page,int visible)try{return host.published(0,id(page),visible);}FAIL
API ip_use(int page,int user,int done)try{return host.observe(0,id(page),user,done);}FAIL
extern "C" __declspec(dllexport) unsigned long long ip_start_page(int user){
    auto x=host.start_request(0,user);return x ? x->page : 0;
}
API ip_release(int page,int handshake)try{
    if(!handshake)return host.can_retire(0,id(page));
    host.retire_handshake(0,id(page));return 1;
}FAIL
