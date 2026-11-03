#include "ftlpu/mem/mem_array.hpp"
#include <cassert>
#include <iostream>
#include <memory>

// Tests the actual CModel SR current/next phase, not an RTL integration.
int main()
{
    using namespace ftlpu;
    for (bool early : {true,false}) {
        auto mem=std::make_unique<MemArrayModel>();
        StreamRegisterFabric fabric(16);
        const auto stream=StreamId::East(3);
        for(std::size_t t=0;t<4;++t)for(std::size_t l=0;l<8;++l){
            mem->set_sram_lane_byte(0,t,0,l,std::uint8_t(t*16+l+1));
            mem->set_sram_lane_byte(4,t,1,l,0xee);
        }
        auto tick=[&](){fabric.begin_cycle();mem->evaluate(fabric);fabric.stage_linear_links();fabric.commit_cycle();};
        mem->enqueue_instruction(0,MemInstruction::Read(0,stream));tick(); // A
        assert(mem->read_responses().size()==1 && !fabric.segment_valid(1,0,stream));
        if(early){
            mem->enqueue_instruction(4,MemInstruction::Write(1,stream));
            bool rejected=false;try{tick();}catch(const std::logic_error& e){
                rejected=std::string(e.what()).find("MEM Write reached an invalid stream segment")!=std::string::npos;
            }
            assert(rejected && mem->consumed_transfers().empty());
            assert(mem->sram_lane_byte(4,0,1,0)==0xee);
        }else{
            tick(); // B commits the first registered response; no new issue
            assert(fabric.segment_valid(1,0,stream));
            mem->enqueue_instruction(4,MemInstruction::Write(1,stream));
            for(int t=0;t<4;++t){tick();assert(mem->consumed_transfers().size()==1);}
            for(std::size_t t=0;t<4;++t)for(std::size_t l=0;l<8;++l)
                assert(mem->sram_lane_byte(4,t,1,l)==std::uint8_t(t*16+l+1));
        }
    }
    std::cout<<"MEM_SYNC_DEPENDENCY TEST_PASS early_B_consume_rejected post_B_current_consumed CModel_only\n";
}
