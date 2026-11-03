// Replay immutable S05 issue/current inputs against the actual adapted model.
// No response delay in this driver: PRE/POST come directly from MemArrayModel.
#include "ftlpu/mem/mem_array.hpp"
#include "ftlpu/core/instruction_codec.hpp"
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <set>

using namespace ftlpu;
using Transfer = MemArrayModel::MemTransfer;
using Coord = std::array<int,4>;
void need(bool v, const std::string& msg) { if (!v) throw std::runtime_error(msg); }
std::uint64_t pack(const StreamPayloadTileSegment& bytes) {
    std::uint64_t value=0; for(int l=0;l<8;++l)value|=std::uint64_t(bytes[l])<<(8*l); return value;
}
struct Issue { int h,s,b; std::uint32_t word; };
struct Input { int h,col,dir,stream,tile; unsigned mask; std::uint64_t data; };
struct Event { int h,s,b,t,op,row,dir,stream; unsigned mask; std::uint64_t input,read,mem,lo,hi; };

int main(int argc,char**argv) try {
    need(argc==3,"usage sync_reference original_L1_vector new_sync_vector");
    std::ifstream in(argv[1]); std::ofstream out(argv[2]); need(bool(in)&&bool(out),"open vector");
    std::string magic;int version,p,active,mode,cycles;
    in>>magic>>version>>p>>active>>mode>>cycles;
    int tiles=4; if(version==2)in>>tiles;
    need((version==1||version==2)&&tiles==int(hw::kTileRows),"tile profile identity");
    need(magic=="MEM_P1" && (version==1||version==2) && p==int(hw::kSramDepthRows),"physical profile identity");
    std::array<std::unique_ptr<MemArrayModel>,2> model;
    std::array<StreamRegisterFabric,2> fabric{StreamRegisterFabric(16),StreamRegisterFabric(16)};
    for(auto& m:model){m=std::make_unique<MemArrayModel>(MemStreamPortMap::BetweenBoundaries(),mode?
        MemArrayModel::MissingStreamPolicy::ZeroFill:MemArrayModel::MissingStreamPolicy::Error);m->set_sram_depth_rows(active);}
    out<<"MEM_SYNC 2 "<<p<<' '<<active<<' '<<mode<<' '<<cycles<<' '<<tiles<<'\n';
    std::size_t reads=0,releases=0,consumes=0,nonreset=0,canceled=0,writes=0,taps=0;
    std::map<std::array<int,5>,std::uint64_t> storage;
    auto memory=[&](int h,int s,int b,int t,int r){
        StreamPayloadTileSegment a{};for(int l=0;l<8;++l)a[l]=model[h]->sram_lane_byte(s,b,t,r,l);return pack(a);};
    for(int cycle=0;cycle<cycles;++cycle){
        int seq,reset,ni,ns,ne;in>>seq>>reset>>ni>>ns>>ne;
        need(bool(in)&&seq==cycle,"input frame cycle="+std::to_string(cycle));
        std::vector<Issue> issues(ni);std::vector<Input> inputs(ns);std::vector<Event> events(ne);
        for(auto& q:issues)in>>q.h>>q.s>>q.b>>std::hex>>q.word>>std::dec;
        for(auto& q:inputs)in>>q.h>>q.col>>q.dir>>q.stream>>q.tile>>std::hex>>q.mask>>q.data>>std::dec;
        for(auto& q:events)in>>q.h>>q.s>>q.b>>q.t>>q.op>>q.row>>q.dir>>q.stream>>std::hex>>q.mask>>q.input>>q.read>>q.mem>>q.lo>>q.hi>>std::dec;
        if(reset){for(auto& m:model){canceled+=m->read_responses().size();m->reset_execution_state();}}
        else ++nonreset;
        for(auto& f:fabric){f.reset();f.begin_cycle();}
        for(auto q:inputs)for(int l=0;l<8;++l)if(q.mask&(1<<l))
            fabric[q.h].stage_write(q.col,q.tile,l,q.dir?StreamId::West(q.stream):StreamId::East(q.stream),StreamCell::Valid(q.data>>(8*l)));
        for(auto& f:fabric){f.commit_cycle();f.begin_cycle();}
        std::set<std::array<int,3>> issued;
        for(auto q:issues){need(issued.insert({q.h,q.s,q.b}).second,"more than one primitive per bank");
            model[q.h]->enqueue_instruction(q.s,q.b,isa::decode_mem_instruction(q.word));}
        if(!reset)for(int h=0;h<2;++h)model[h]->evaluate(fabric[h]);
        std::map<Coord,MemArrayModel::InstructionTrace> commands;
        std::map<Coord,Transfer> after;
        std::size_t nr=0,np=0,nc=0;
        for(int h=0;h<2;++h){
            for(auto q:model[h]->executed_instructions())need(commands.emplace(Coord{h,int(q.mem_slice),int(q.bank),int(q.tile)},q).second,"single leaf occupancy");
            for(auto q:model[h]->read_responses())need(after.emplace(Coord{h,int(q.mem_slice),int(q.bank),int(q.tile)},q).second,"duplicate response source");
            nr+=model[h]->read_responses().size();np+=model[h]->staged_read_responses().size();nc+=model[h]->consumed_transfers().size();
        }
        need(commands.size()==events.size(),"command count cycle="+std::to_string(cycle));
        for(auto q:events){
            Coord id{q.h,q.s,q.b,q.t};need(commands.contains(id),"missing command coordinate");
            auto i=commands.at(id).instruction;
            const int op=i.opcode==MemOpcode::Read?0:i.preserve_stream?2:1;
            need(op==q.op && int(i.address)==q.row && int(i.stream)==q.dir*32+q.stream,"command metadata mismatch");
            // Non-temporal cross-check with the original c7 functional golden.
            if(q.op==0){need(after.contains(id)&&pack(after.at(id).bytes)==q.read,"original c7 Read data mismatch");}
            need(memory(q.h,q.s,q.b,q.t,q.row)==q.mem,"original c7 store effect mismatch");
            need(memory(q.h,q.s,q.b,q.t,(q.row+active-1)%active)==q.lo,"lower neighbor mismatch");
            need(memory(q.h,q.s,q.b,q.t,(q.row+1)%active)==q.hi,"upper neighbor mismatch");
            storage[{q.h,q.s,q.b,q.t,q.row}]=q.mem;
            if(q.op==1)++writes;if(q.op==2)++taps;
        }
        out<<cycle<<' '<<reset<<' '<<ni<<' '<<ns<<' '<<ne<<' '<<np<<' '<<nr<<' '<<nc<<'\n';
        for(auto q:issues)out<<q.h<<' '<<q.s<<' '<<q.b<<' '<<std::hex<<q.word<<std::dec<<'\n';
        for(auto q:inputs)out<<q.h<<' '<<q.col<<' '<<q.dir<<' '<<q.stream<<' '<<q.tile<<' '<<std::hex<<q.mask<<' '<<q.data<<std::dec<<'\n';
        for(auto q:events)out<<q.h<<' '<<q.s<<' '<<q.b<<' '<<q.t<<' '<<q.op<<' '<<q.row<<' '<<q.dir<<' '<<q.stream<<' '
            <<std::hex<<q.mask<<' '<<q.input<<' '<<q.read<<' '<<q.mem<<' '<<q.lo<<' '<<q.hi<<std::dec<<'\n';
        auto emit=[&](int h,const Transfer&r){out<<h<<' '<<r.mem_slice<<' '<<r.bank<<' '<<r.tile<<' '<<r.address<<' '
            <<int(r.stream.direction()==StreamDirection::West)<<' '<<r.stream.index()<<' '<<r.sr_column<<' '
            <<std::hex<<pack(r.bytes)<<std::dec<<'\n';};
        for(int h=0;h<2;++h)for(auto r:model[h]->staged_read_responses())emit(h,r);
        for(int h=0;h<2;++h)for(auto r:model[h]->read_responses())emit(h,r);
        for(int h=0;h<2;++h)for(auto r:model[h]->consumed_transfers())emit(h,r);
        // Actual CModel next-state/commit sanity check only. This is not a
        // claim that an RTL SRF instance was tested or that inputs feed back.
        for(int h=0;h<2;++h){fabric[h].commit_cycle();for(auto r:model[h]->staged_read_responses())
            for(int l=0;l<8;++l){const auto& cell=fabric[h].cell(r.sr_column,r.tile,l,r.stream);
                need(cell.valid && cell.data==r.bytes[l],"actual CModel B commit mismatch");}}
        reads+=nr;releases+=np;consumes+=nc;
    }
    int n;in>>magic>>n;need(magic=="END"&&n==int(208*hw::kTileRows),"missing full-storage signatures");
    out<<"END "<<208*hw::kTileRows<<'\n';
    for(int q=0;q<n;++q){int h,s,b,t;std::uint64_t expected;in>>h>>s>>b>>t>>std::hex>>expected>>std::dec;
        std::uint64_t digest=0xcbf29ce484222325ull;
        for(int r=0;r<p;++r){const auto it=storage.find({h,s,b,t,r});const auto value=it==storage.end()?0:it->second;
            if(r<active)need(memory(h,s,b,t,r)==value,"adapted full-storage mismatch");digest=(digest^value)*0x100000001b3ull;}
        need(digest==expected,"original c7 final signature mismatch");out<<h<<' '<<s<<' '<<b<<' '<<t<<' '<<std::hex<<digest<<std::dec<<'\n';}
    for(auto& m:model)need(!m->has_pending_read_responses(),"last response not drained");
    need(reads==releases+canceled,"response conservation including reset cancellation");
    std::ofstream cov(std::string(argv[2])+".coverage.json");
    cov<<"{\"cycles\":"<<cycles<<",\"nonreset_cycles\":"<<nonreset<<",\"reads\":"<<reads<<",\"released\":"<<releases
       <<",\"reset_canceled\":"<<canceled<<",\"consumes\":"<<consumes<<",\"write_commands\":"<<writes
       <<",\"tap_commands\":"<<taps<<",\"physical_rows\":"<<p<<",\"active_rows\":"<<active
       <<",\"zero_fill\":"<<mode<<",\"l2_mem_boundary\":true,\"rtl_srf\":false}\n";
    std::cout<<"MEM_SYNC_REFERENCE TEST_PASS cycles="<<cycles<<" nonreset="<<nonreset<<" reads="<<reads<<" released="<<releases<<" canceled="<<canceled<<'\n';
}catch(const std::exception&e){std::cerr<<"MEM_SYNC_REFERENCE FAIL "<<e.what()<<'\n';return 1;}
