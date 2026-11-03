// Functional events and independent SRAM oracle on the selected frozen reference.
// Profile regression uses the actual local synchronous-read R1, never a substitute model.
#include "ftlpu/mem/mem_array.hpp"
#include "ftlpu/core/instruction_codec.hpp"
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <random>
#include <set>
#include <tuple>

using namespace ftlpu;
constexpr int H = 2, SLICES = 52, BANKS = 2, TILES = hw::kTileRows;
static_assert(hw::kMemSliceColumns == SLICES && hw::kTileRows == TILES);
static_assert(hw::kMemBanksPerSlice == BANKS && hw::kLanesPerTile == 8);
using Key = std::array<int, 6>; // hemisphere,boundary,direction,stream,tile,unused
using MemoryKey = std::array<int, 5>; // hemisphere,slice,bank,tile,row

void need(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
std::uint64_t pack(const StreamPayloadTileSegment& bytes) {
    std::uint64_t value = 0;
    for (int l = 0; l < 8; ++l) value |= std::uint64_t(bytes[l]) << (l*8);
    return value;
}
std::uint64_t pattern(std::uint64_t seed, int cycle, const Key& key) {
    std::uint64_t x = seed ^ (std::uint64_t(cycle+1)*0x9e3779b97f4a7c15ull);
    for (int q : key) x = (x ^ std::uint64_t(q+1))*0x100000001b3ull;
    return x ^ (x >> 23);
}
MemInstruction instruction(int op, int row, int stream) {
    return op == 0 ? MemInstruction::Read(row, stream) :
           op == 1 ? MemInstruction::Write(row, stream) : MemInstruction::WriteTap(row, stream);
}
int op_of(const MemInstruction& i) {
    return i.opcode == MemOpcode::Read ? 0 : (i.preserve_stream ? 2 : 1);
}

void codec_vectors(const std::string& path, int active) {
    std::ofstream out(path);
    out << hw::kSramDepthRows << ' ' << active << '\n';
    const int rows[] = {0, 63, 64, 8191, 8192, 32767};
    auto emit = [&](std::uint32_t word) {
        bool accepted = false;
        try {
            const auto i = isa::decode_mem_instruction(word);
            accepted = (i.opcode == MemOpcode::Read || i.opcode == MemOpcode::Write)
                && i.address < std::size_t(active);
        } catch (const std::exception&) {}
        out << std::hex << word << ' ' << std::dec << int(accepted) << ' '
            << std::hex << (accepted ? word & ~std::uint32_t(0x7e00) : 0) << '\n';
    };
    for (int op = 0; op < 8; ++op)
        for (int stream = 0; stream < 64; ++stream)
            for (int map = 0; map < 64; ++map)
                for (int tap = 0; tap < 2; ++tap)
                    for (int row : rows)
                        emit(std::uint32_t(op | (stream<<3) | (map<<9) | (row<<15))
                             | (std::uint32_t(tap)<<31));
    for (int bit = 0; bit < 32; ++bit) emit(std::uint32_t(1) << bit);
    emit(0xffffffff); emit(0x00200000); emit(0);
}

void masks(const std::string& path) {
    std::ofstream out(path);
    for (int mode = 0; mode < 2; ++mode)
        for (int op = 1; op <= 2; ++op)
            for (int mask = 0; mask < 256; ++mask) {
                MemArrayModel m(MemStreamPortMap::BetweenBoundaries(), mode ?
                    MemArrayModel::MissingStreamPolicy::ZeroFill : MemArrayModel::MissingStreamPolicy::Error);
                StreamRegisterFabric f(16);
                const std::uint64_t initial = 0x8877665544332211ull;
                const std::uint64_t payload = 0xfedcba9876543210ull;
                for (int l = 0; l < 8; ++l) m.set_sram_lane_byte(0,0,0,1,l,initial>>(8*l));
                f.begin_cycle();
                for (int l = 0; l < 8; ++l)
                    if ((mask>>l)&1) f.stage_write(0,0,l,StreamId::East(0), StreamCell::Valid(payload>>(8*l)));
                f.commit_cycle(); f.begin_cycle();
                m.enqueue_instruction(0,0,instruction(op,1,0));
                bool fault = false;
                try { m.evaluate(f); } catch (const std::exception&) { fault = true; }
                const bool expected_fault = mode == 0 && op == 1 && mask != 255;
                need(fault == expected_fault, "c7 mask exception mismatch");
                int consumed = 0;
                if (!fault) {
                    f.stage_linear_links(); f.commit_cycle();
                    int forwarded = 0;
                    for (int l = 0; l < 8; ++l)
                        if (f.cell(1,0,l,StreamId::East(0)).valid) forwarded |= 1<<l;
                    consumed = mask & ~forwarded;
                }
                // Exception cycles use the approved no-write/no-consume safety
                // oracle, not a commit of the exceptional CModel fabric.
                std::uint64_t stored = initial;
                if (!fault) {
                    stored = 0;
                    for (int l = 0; l < 8; ++l) stored |= std::uint64_t(m.sram_lane_byte(0,0,0,1,l))<<(8*l);
                }
                out << mode << ' ' << op << ' ' << std::hex << mask << ' ' << std::dec << int(fault)
                    << ' ' << std::hex << consumed << ' ' << stored << '\n';
            }
}

struct Issue { int h,s,b; MemInstruction i; };
struct Event { int h,s,b,t; MemInstruction i; unsigned mask; std::uint64_t input; };

void full(const std::string& path, std::uint32_t seed, int mode, bool directed, int active) {
    auto policy = mode ? MemArrayModel::MissingStreamPolicy::ZeroFill : MemArrayModel::MissingStreamPolicy::Error;
    std::array<std::unique_ptr<MemArrayModel>,H> models;
    std::array<StreamRegisterFabric,H> fabrics{StreamRegisterFabric(16),StreamRegisterFabric(16)};
    for (auto& m : models) {m=std::make_unique<MemArrayModel>(MemStreamPortMap::BetweenBoundaries(),policy);m->set_sram_depth_rows(active);}
    std::map<MemoryKey,std::uint64_t> oracle;
    std::set<std::array<int,5>> read_coordinates, write_coordinates;
    std::mt19937 rng(seed);
    const int phase_cycles = 512+TILES+1;
    const int random_cycles = 1010;
    const int cycles = directed ? 1+3*phase_cycles : 1+random_cycles+TILES+1;
    std::ofstream out(path);
    out << "MEM_P1 2 " << hw::kSramDepthRows << ' ' << active << ' ' << mode << ' ' << cycles << ' ' << TILES << '\n';
    std::size_t reads=0,writes=0,taps=0,zero_fills=0;
    auto memory = [&](int h,int s,int b,int t,int row) {
        StreamPayloadTileSegment bytes{};
        for(int l=0;l<8;++l)bytes[l]=models[h]->sram_lane_byte(s,b,t,row,l);
        return pack(bytes);
    };
    for (int cycle=0;cycle<cycles;++cycle) {
        const bool reset = cycle==0 || (!directed && cycle>0 && cycle<=random_cycles && cycle%257==0);
        std::vector<Issue> issues;
        if (reset) {
            for(auto& m:models)m->reset_execution_state();
        } else if (directed) {
            const int phase=(cycle-1)/phase_cycles, tick=(cycle-1)%phase_cycles;
            if(tick<512){
                const int stream=tick/8, slot=tick%8;
                const int row=phase==0?active-1:stream%active;
                for(int h=0;h<H;++h)for(int g=0;g<13;++g)
                    issues.push_back({h,g*4+slot/2,slot%2,instruction(phase==1?1:0,row,stream)});
            }
        } else if(cycle<=random_cycles) {
            for(int h=0;h<H;++h){
                std::set<int> selected;
                while(selected.size()<5)selected.insert(rng()%52);
                for(int s:selected)for(int b=0;b<2;++b)if(rng()%4!=0){
                    int stream=(s%4)*2+b+8*(rng()%4)+32*(rng()%2);
                    int row=rng()%active;
                    if(cycle%17==0)row=active-1;
                    if(cycle%19==0)row=0;
                    issues.push_back({h,s,b,instruction(rng()%3,row,stream)});
                }
            }
        }
        std::map<std::array<int,3>,MemInstruction> incoming;
        for(const auto& q:issues)incoming.emplace(std::array<int,3>{q.h,q.s,q.b},q.i);
        std::vector<Event> events;
        std::map<Key,std::pair<unsigned,std::uint64_t>> stimulus;
        if(!reset)for(int h=0;h<H;++h)for(int s=0;s<52;++s)for(int b=0;b<2;++b)for(int t=0;t<TILES;++t){
            std::optional<MemInstruction> current;
            if(t==0){auto it=incoming.find({h,s,b});if(it!=incoming.end())current=it->second;}
            else current=models[h]->instruction_at(s,b,t);
            if(!current)continue;
            auto i=*current;unsigned mask=255;std::uint64_t data=0;
            if(op_of(i)!=0){
                if(mode && !directed)mask=(cycle%5==0)?255:unsigned((cycle*73+seed)&255);
                const auto stream=i.stream_id();
                Key key{h,s/4+(stream.direction()==StreamDirection::West),
                        stream.direction()==StreamDirection::West,int(stream.index()),t,0};
                data=pattern(seed,cycle,key);stimulus[key]={mask,data};
            }
            events.push_back({h,s,b,t,i,mask,data});
        }
        for(auto& f:fabrics){f.reset();f.begin_cycle();}
        for(auto [key,value]:stimulus){
            auto [mask,data]=value;
            auto id=key[2]?StreamId::West(key[3]):StreamId::East(key[3]);
            for(int l=0;l<8;++l)if((mask>>l)&1)
                fabrics[key[0]].stage_write(key[1],key[4],l,id,StreamCell::Valid(data>>(8*l)));
        }
        for(auto& f:fabrics){f.commit_cycle();f.begin_cycle();}
        for(auto q:issues)models[q.h]->enqueue_instruction(q.s,q.b,isa::decode_mem_instruction(isa::encode_mem_instruction(q.i)));
        if(!reset)for(int h=0;h<H;++h)models[h]->evaluate(fabrics[h]);
        std::map<std::array<int,4>,MemArrayModel::MemTransfer> transfers;
        if(!reset)for(int h=0;h<H;++h){
            std::size_t count=0;for(const auto&e:events)count+=e.h==h;
            need(count==models[h]->executed_instructions().size(),"command wave event count");
            for(auto x:models[h]->executed_transfers())transfers.emplace(std::array<int,4>{h,int(x.mem_slice),int(x.bank),int(x.tile)},x);
        }
        out<<cycle<<' '<<int(reset)<<' '<<issues.size()<<' '<<stimulus.size()<<' '<<events.size()<<'\n';
        for(auto q:issues)out<<q.h<<' '<<q.s<<' '<<q.b<<' '<<std::hex<<isa::encode_mem_instruction(q.i)<<std::dec<<'\n';
        for(auto [key,v]:stimulus)out<<key[0]<<' '<<key[1]<<' '<<key[2]<<' '<<key[3]<<' '<<key[4]<<' '<<std::hex<<v.first<<' '<<v.second<<std::dec<<'\n';
        for(auto e:events){
            const int op=op_of(e.i),row=e.i.address,d=e.i.stream_id().direction()==StreamDirection::West,stream=e.i.stream_id().index();
            MemoryKey key{e.h,e.s,e.b,e.t,row};
            auto expected=oracle[key];std::uint64_t read_data=0;
            if(op==0){
                auto it=transfers.find({e.h,e.s,e.b,e.t});need(it!=transfers.end(),"missing real c7 Read event");
                read_data=pack(it->second.bytes);need(read_data==expected,"real c7 read/layout oracle mismatch");
                read_coordinates.insert({e.h,e.s,e.b,e.t,int(e.i.stream)});++reads;
            }else if(e.mask==255 || (op==1 && mode)){
                expected=e.mask==255?e.input:0;oracle[key]=expected;
                auto it=transfers.find({e.h,e.s,e.b,e.t});need(it!=transfers.end(),"missing real c7 store event");
                need(pack(it->second.bytes)==expected,"real c7 store payload mismatch");
                write_coordinates.insert({e.h,e.s,e.b,e.t,int(e.i.stream)});
                if(op==1)++writes;else ++taps;if(e.mask!=255)++zero_fills;
            }else{
                need(op==2 && !transfers.contains({e.h,e.s,e.b,e.t}),"Tap missing must be no-op");
            }
            const auto actual=memory(e.h,e.s,e.b,e.t,row);need(actual==expected,"real c7 SRAM after-event mismatch");
            const int lo=(row+active-1)%active,hi=(row+1)%active;
            const auto lov=memory(e.h,e.s,e.b,e.t,lo),hiv=memory(e.h,e.s,e.b,e.t,hi);
            need(lov==oracle[{e.h,e.s,e.b,e.t,lo}] && hiv==oracle[{e.h,e.s,e.b,e.t,hi}],"neighbor corruption");
            out<<e.h<<' '<<e.s<<' '<<e.b<<' '<<e.t<<' '<<op<<' '<<row<<' '<<d<<' '<<stream<<' '
               <<std::hex<<e.mask<<' '<<e.input<<' '<<read_data<<' '<<actual<<' '<<lov<<' '<<hiv<<std::dec<<'\n';
        }
        // The next cycle's boundary state is an explicit independent fixture;
        // no RTL SRF links, SR timing profile, or whole-system schedule is tested.
    }
    out<<"END "<<H*52*2*TILES<<'\n';
    for(int h=0;h<H;++h)for(int s=0;s<52;++s)for(int b=0;b<2;++b)for(int t=0;t<TILES;++t){
        std::uint64_t digest=0xcbf29ce484222325ull;
        for(int row=0;row<int(hw::kSramDepthRows);++row){
            const auto it=oracle.find({h,s,b,t,row});
            const std::uint64_t expected=it==oracle.end()?0:it->second;
            if(row<active)need(memory(h,s,b,t,row)==expected,"final full-SRAM oracle mismatch");
            digest=(digest^expected)*0x100000001b3ull;
        }
        out<<h<<' '<<s<<' '<<b<<' '<<t<<' '<<std::hex<<digest<<std::dec<<'\n';
    }
    std::ofstream cov(path+".coverage.json");
    cov<<"{\"cycles\":"<<cycles<<",\"main_random_cycles\":"<<(directed?0:random_cycles)
       <<",\"reads\":"<<reads<<",\"writes\":"<<writes<<",\"taps\":"<<taps
       <<",\"zero_fills\":"<<zero_fills<<",\"read_coordinates\":"<<read_coordinates.size()
       <<",\"write_coordinates\":"<<write_coordinates.size()<<",\"physical_rows\":"<<hw::kSramDepthRows
       <<",\"active_rows\":"<<active<<",\"tiles\":"<<TILES<<",\"full_storage_signatures\":"<<H*SLICES*BANKS*TILES<<",\"l2\":false}\n";
    std::cout<<"CMODEL_MEM_L1 PASS cycles="<<cycles<<" reads="<<reads<<" zero_fills="<<zero_fills<<'\n';
}

int main(int argc,char**argv) try {
    need(argc>=3,"usage reference codec|masks|full output [active] [mode] [seed] [directed]");
    const std::string task=argv[1],path=argv[2];
    if(task=="codec")codec_vectors(path,std::stoi(argv[3]));
    else if(task=="masks")masks(path);
    else if(task=="full"){
        need(argc==7,"full requires active mode seed directed");
        full(path,std::stoul(argv[5]),std::stoi(argv[4]),std::stoi(argv[6]),std::stoi(argv[3]));
    }
    else throw std::runtime_error("unknown reference task");
    return 0;
} catch(const std::exception&e){std::cerr<<"REFERENCE_FAIL "<<e.what()<<'\n';return 1;}
