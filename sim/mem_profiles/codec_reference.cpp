#include "ftlpu/core/instruction_codec.hpp"
#include <fstream>
#include <iostream>
using namespace ftlpu;
int main(int argc,char**argv) try {
    if(argc!=3)throw std::runtime_error("usage codec_reference output active_rows");
    const std::size_t p=hw::kSramDepthRows, e=std::stoul(argv[2]);
    std::ofstream out(argv[1]);out<<"MEM_PROFILE_CODEC 1 "<<p<<' '<<e<<'\n';
    std::size_t count=0;
    auto emit=[&](std::uint32_t word){
        bool accepted=false;
        try{auto i=isa::decode_mem_instruction(word);accepted=(i.opcode==MemOpcode::Read||i.opcode==MemOpcode::Write)&&i.address<e;}
        catch(const std::exception&){}
        out<<std::hex<<word<<' '<<std::dec<<accepted<<' '<<std::hex<<(accepted?word&~std::uint32_t(0x7e00):0)<<'\n';++count;
    };
    for(int op=0;op<8;++op)for(int stream=0;stream<64;++stream)for(int map=0;map<64;++map)for(int preserve=0;preserve<2;++preserve)
      for(std::size_t row:{std::size_t(0),e-1,e,p-1,p,std::size_t(32767)})
        emit(std::uint32_t(op|(stream<<3)|(map<<9)|(row<<15))|(std::uint32_t(preserve)<<31));
    for(int bit=0;bit<32;++bit)emit(std::uint32_t(1)<<bit);
    emit(0xffffffff);
    std::cout<<"MEM_PROFILE_CODEC_REFERENCE TEST_PASS cases="<<count<<" P="<<p<<" E="<<e<<'\n';
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}
