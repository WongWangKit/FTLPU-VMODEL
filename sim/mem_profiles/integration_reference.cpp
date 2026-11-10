// Actual local R1 MEM + persistent SRF closed loop. No per-cycle state reset,
// fabricated current, response-delay wrapper or alternative MEM implementation.
#include "ftlpu/mem/mem_array.hpp"
#include "ftlpu/core/instruction_codec.hpp"
#include <array>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <random>
#include <set>
#include <vector>

using namespace ftlpu;
struct Issue { int h,s,b; MemInstruction instruction; };
struct Boundary { int h,d,t,s; std::uint64_t data; };
std::uint64_t pack(const StreamPayloadTileSegment& x) {
    std::uint64_t v=0;for(int l=0;l<8;++l)v|=std::uint64_t(x[l])<<(l*8);return v;
}
int main(int argc,char**argv) try {
    if(argc!=2 && argc!=4)throw std::runtime_error("usage integration_reference output [seed random_cycles]");
    constexpr int T=hw::kTileRows, P=hw::kSramDepthRows;
    std::array<std::unique_ptr<MemArrayModel>,2> mem;
    std::array<StreamRegisterFabric,2> fabric{StreamRegisterFabric(16),StreamRegisterFabric(16)};
    for(auto& m:mem)m=std::make_unique<MemArrayModel>(MemStreamPortMap::BetweenBoundaries(),MemArrayModel::MissingStreamPolicy::Error);
    std::map<int,std::vector<Issue>> issues;
    std::map<int,std::vector<Boundary>> boundary;
    std::set<int> resets{0};
    const int block=16+T+3;
    int cursor=1;
    // Populate every real leaf through external SRF boundary -> current -> MEM
    // Write, with distinct hemisphere/group/bank/tile/lane payloads.
    for(int row: {0,P-1})for(int g=0;g<13;++g){
        for(int h=0;h<2;++h)for(int k=0;k<8;++k){
            for(int t=0;t<T;++t){
                std::uint64_t data=0;
                for(int l=0;l<8;++l)data|=std::uint64_t((h*113+g*19+k*37+t*11+l+(row?71:0))&255)<<(l*8);
                boundary[cursor+t].push_back({h,0,t,k,data});
            }
            issues[cursor+g+1].push_back({h,g*4+k/2,k%2,MemInstruction::Write(row,StreamId::East(k))});
        }
        cursor+=block;
    }
    for(int direction=0;direction<2;++direction)for(int g=0;g<13;++g){
        for(int h=0;h<2;++h)for(int k=0;k<8;++k){
            const auto stream=direction?StreamId::West((g%4)*8+k):StreamId::East((g%4)*8+k);
            const int source_row=direction?P-1:0;
            issues[cursor].push_back({h,g*4+k/2,k%2,MemInstruction::Read(source_row,stream)});
            int destination=g+(direction?-1:1);
            if(destination>=0 && destination<13){
                auto write=g%2?MemInstruction::WriteTap(P-2,stream):MemInstruction::Write(1,stream);
                issues[cursor+2].push_back({h,destination*4+k/2,k%2,write});
            }
        }
        cursor+=block;
    }
    // Verification-only extension: legal randomized schedules on the SAME
    // persistent CModel MEM/SRF, not a second reference or injected SRF current.
    // No wait/retry is added to product RTL.  Jobs are spaced to drain passive
    // links; each job itself issues adjacent waves and reads initialized data.
    const unsigned seed=argc==4?std::stoul(argv[2]):0;
    const int random_cycles=argc==4?std::stoi(argv[3]):0;
    if(random_cycles<0)throw std::runtime_error("negative random cycles");
    std::mt19937 rng(seed);
    std::set<int> random_groups,random_streams,random_rows;
    int random_jobs=0,random_waves=0,random_taps=0,random_writes=0;
    const int random_start=cursor;
    const int random_block=16+T+12;
    while(cursor+random_block<=random_start+random_cycles){
        const int direction=rng()%2;
        const int g=direction?1+rng()%12:rng()%12;
        const int destination=direction?rng()%g:g+1+rng()%(12-g);
        const int hop=direction?g-destination-1:destination-g-1;
        const int stream_base=(rng()%4)*8;
        const int burst=1+rng()%8;
        const int row=1+rng()%(P-2);
        const bool tap=rng()%2;
        random_groups.insert(g);random_groups.insert(destination);random_rows.insert(row);
        for(int n=0;n<burst;++n)for(int h=0;h<2;++h)for(int k=0;k<8;++k){
            const auto stream=direction?StreamId::West(stream_base+k):StreamId::East(stream_base+k);
            issues[cursor+n].push_back({h,g*4+k/2,k%2,MemInstruction::Read((rng()%2)?P-1:0,stream)});
            issues[cursor+n+2+hop].push_back({h,destination*4+k/2,k%2,
                tap?MemInstruction::WriteTap(row,stream):MemInstruction::Write(row,stream)});
            random_streams.insert(direction*32+stream_base+k);
        }
        ++random_jobs;random_waves+=burst;
        if(tap)random_taps+=burst*16;else random_writes+=burst*16;
        cursor+=random_block;
    }
    cursor=random_start+random_cycles;
    // A response exists after A, then an in-flight reset cancels it before B.
    for(int h=0;h<2;++h)issues[cursor].push_back({h,0,0,MemInstruction::Read(0,StreamId::East(31))});
    resets.insert(cursor+1);
    const int cycles=cursor+block;
    std::ofstream out(argv[1]);
    if(!out)throw std::runtime_error("cannot open output");
    out<<"MEM_INTEGRATION 1 "<<T*8<<' '<<T<<' '<<P<<' '<<cycles<<'\n';
    std::size_t reads=0,writes=0,consumes=0,compared=0;
    for(int c=0;c<cycles;++c){
        const bool reset=resets.contains(c);
        if(reset)for(int h=0;h<2;++h){mem[h]->reset_execution_state();fabric[h].reset();}
        for(auto& f:fabric)f.begin_cycle();
        for(const auto& q:issues[c])mem[q.h]->enqueue_instruction(q.s,q.b,q.instruction);
        if(!reset)for(int h=0;h<2;++h)mem[h]->evaluate(fabric[h]);
        for(const auto& q:boundary[c]){
            StreamPayloadTileSegment payload{};
            for(int l=0;l<8;++l)payload[l]=q.data>>(l*8);
            fabric[q.h].stage_payload_segment(q.d?15:0,q.t,q.d?StreamId::West(q.s):StreamId::East(q.s),payload);
        }
        for(auto& f:fabric){f.stage_linear_links();f.commit_cycle();}
        struct State {int h,d,col,t,s;std::uint64_t data;};
        std::vector<State> state;
        for(int h=0;h<2;++h)for(int d=0;d<2;++d)for(int col=0;col<16;++col)
          for(int t=0;t<T;++t)for(int s=0;s<32;++s){
            StreamPayloadTileSegment bytes{};int mask=0;
            for(int l=0;l<8;++l){auto cell=fabric[h].cell(col,t,l,d?StreamId::West(s):StreamId::East(s));if(cell.valid)mask|=1<<l;bytes[l]=cell.data;}
            if(mask!=0 && mask!=255)throw std::runtime_error("unexpected partial in compatibility domain");
            if(mask)state.push_back({h,d,col,t,s,pack(bytes)});
          }
        auto nr=mem[0]->read_responses().size()+mem[1]->read_responses().size();
        auto nc=mem[0]->consumed_transfers().size()+mem[1]->consumed_transfers().size();
        out<<c<<' '<<reset<<' '<<issues[c].size()<<' '<<boundary[c].size()<<' '<<state.size()<<' '<<nr<<' '<<nc<<'\n';
        for(const auto& q:issues[c])out<<q.h<<' '<<q.s<<' '<<q.b<<' '<<std::hex<<isa::encode_mem_instruction(q.instruction)<<std::dec<<'\n';
        for(const auto& q:boundary[c])out<<q.h<<' '<<q.d<<' '<<q.t<<' '<<q.s<<' '<<std::hex<<q.data<<std::dec<<'\n';
        for(auto q:state)out<<q.h<<' '<<q.d<<' '<<q.col<<' '<<q.t<<' '<<q.s<<' '<<std::hex<<q.data<<std::dec<<'\n';
        for(int h=0;h<2;++h)for(auto q:mem[h]->read_responses())out<<h<<' '<<(q.mem_slice*2+q.bank)*T+q.tile<<' '
          <<int(q.stream.direction()==StreamDirection::West)<<' '<<q.stream.index()<<' '<<q.sr_column<<' '<<std::hex<<pack(q.bytes)<<std::dec<<'\n';
        for(int h=0;h<2;++h)for(auto q:mem[h]->consumed_transfers())out<<h<<' '<<q.sr_column<<' '
          <<int(q.stream.direction()==StreamDirection::West)<<' '<<q.stream.index()<<' '<<q.tile<<'\n';
        for(int h=0;h<2;++h)for(auto q:mem[h]->executed_transfers())writes+=q.kind==MemArrayModel::MemTransfer::Kind::StoreStreamToSram;
        reads+=nr;consumes+=nc;compared+=state.size();
    }
    out<<"END "<<208*T<<'\n';
    for(int h=0;h<2;++h)for(int s=0;s<52;++s)for(int b=0;b<2;++b)for(int t=0;t<T;++t){
        std::uint64_t digest=0xcbf29ce484222325ull;
        for(int r=0;r<P;++r){StreamPayloadTileSegment bytes{};for(int l=0;l<8;++l)bytes[l]=mem[h]->sram_lane_byte(s,b,t,r,l);digest=(digest^pack(bytes))*0x100000001b3ull;}
        out<<h<<' '<<s<<' '<<b<<' '<<t<<' '<<std::hex<<digest<<std::dec<<'\n';
    }
    for(auto& m:mem)if(m->has_pending_read_responses())throw std::runtime_error("undrained response");
    std::ofstream coverage(std::string(argv[1])+".coverage.json");
    coverage<<"{\"seed\":"<<seed<<",\"random_cycles\":"<<random_cycles
        <<",\"random_jobs\":"<<random_jobs<<",\"random_waves\":"<<random_waves
        <<",\"random_tap_commands\":"<<random_taps<<",\"random_write_commands\":"<<random_writes
        <<",\"random_groups\":"<<random_groups.size()<<",\"random_streams\":"<<random_streams.size()
        <<",\"random_destination_rows\":"<<random_rows.size()<<",\"total_cycles\":"<<cycles<<"}\n";
    std::cout<<"MEM_INTEGRATION_REFERENCE TEST_PASS cycles="<<cycles<<" reads="<<reads
             <<" writes="<<writes<<" consumes="<<consumes<<" state_cells="<<compared<<'\n';
}catch(const std::exception& e){std::cerr<<"MEM_INTEGRATION_REFERENCE FAIL "<<e.what()<<'\n';return 1;}
