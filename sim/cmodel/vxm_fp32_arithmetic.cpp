#include "ftlpu/core/fp16.hpp"
#include "ftlpu/core/instruction_codec.hpp"
#include "ftlpu/system/tsp_slice_system.hpp"

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>

namespace {

constexpr std::size_t kVxmCycle = 8;
constexpr std::size_t kSourceAddress = 0;
constexpr float kAddend = 0.1f;
constexpr float kSubtrahend = -0.35f;
constexpr float kMultiplier = 1.3f;
using Record = std::array<std::uint32_t, 15>;

float input_value(std::size_t tile, std::size_t lane)
{
    return 0.25f * static_cast<float>(
        static_cast<int>(tile * ftlpu::hw::kLanesPerTile + lane) - 15);
}

std::uint64_t read_word(
    const ftlpu::TspSliceSystem& system,
    std::size_t column,
    std::size_t address,
    std::size_t tile)
{
    std::uint64_t result = 0;
    for (std::size_t lane = 0; lane < ftlpu::hw::kLanesPerTile; ++lane)
        result |= static_cast<std::uint64_t>(
            system.read_mem_sram_lane_byte(column, tile, address, lane))
            << (lane * 8);
    return result;
}

void write_init(const char* path, const ftlpu::TspSliceSystem& system)
{
    std::ofstream output(path, std::ios::trunc);
    if (!output) throw std::runtime_error("failed to open VXM arithmetic init");
    output << std::hex << std::setfill('0');
    for (std::size_t column = 0; column < 4; ++column)
        for (std::size_t tile = 0; tile < ftlpu::hw::kTileRows; ++tile)
            output << std::setw(16)
                   << read_word(system, column, kSourceAddress, tile) << '\n';
}

void write_golden(const char* path, const ftlpu::TspSliceSystem& system)
{
    std::ofstream output(path, std::ios::trunc);
    if (!output) throw std::runtime_error("failed to open VXM arithmetic golden");
    output << std::hex << std::setfill('0');
    for (std::size_t address = 1; address <= 3; ++address)
        for (std::size_t column = 0; column < 4; ++column)
            for (std::size_t tile = 0; tile < ftlpu::hw::kTileRows; ++tile)
                output << std::setw(16)
                       << read_word(system, column, address, tile) << '\n';
}

void set_record_bits(
    Record& record,
    std::size_t offset,
    std::uint64_t value,
    std::size_t width)
{
    for (std::size_t bit = 0; bit < width; ++bit)
        if (((value >> bit) & 1u) != 0)
            record[(offset + bit) / 32] |=
                std::uint32_t {1} << ((offset + bit) % 32);
}

Record command_record(std::uint8_t queue, std::uint32_t command)
{
    Record result {};
    set_record_bits(result, 0, queue, 8);
    set_record_bits(result, 9, command, 32);
    return result;
}

Record mem_record(std::uint8_t queue, const ftlpu::MemInstruction& instruction)
{
    Record result {};
    set_record_bits(result, 0, queue, 8);
    set_record_bits(result, 8, 1, 1);
    set_record_bits(result, 41, ftlpu::isa::encode_mem_instruction(instruction), 47);
    return result;
}

Record vxm_record(
    std::uint8_t queue,
    const ftlpu::isa::EncodedVxmInstruction& instruction)
{
    Record result {};
    set_record_bits(result, 0, queue, 8);
    set_record_bits(result, 8, 1, 1);
    for (std::size_t word = 0; word < instruction.words.size(); ++word)
        set_record_bits(result, 41 + word * 32, instruction.words[word], 32);
    return result;
}

void write_record(std::ofstream& output, const Record& record)
{
    for (std::size_t word = record.size(); word-- > 0;)
        output << std::setw(8) << record[word];
    output << '\n';
}

ftlpu::VxmLaneAluInstruction arithmetic_instruction(
    ftlpu::VxmAluOpcode opcode,
    ftlpu::VxmLaneOperand lhs,
    float rhs)
{
    return ftlpu::VxmLaneAluInstruction {
        opcode,
        lhs,
        ftlpu::VxmLaneOperand::Imm(rhs),
        1.0f,
        0,
        ftlpu::VxmCastTarget::Float32,
        0,
        ftlpu::Hemisphere::East,
        ftlpu::Hemisphere::East,
    };
}

} // namespace

int main(int argc, char** argv)
try {
    if (argc != 4) {
        std::cerr << "usage: vxm_fp32_arithmetic <init.hex> <golden.hex> <schedule.hex>\n";
        return 2;
    }

    auto system = ftlpu::TspSliceSystem {};
    for (std::size_t tile = 0; tile < ftlpu::hw::kTileRows; ++tile) {
        for (std::size_t lane = 0; lane < ftlpu::hw::kLanesPerTile; ++lane) {
            const auto bits = ftlpu::Fp16::from_float(input_value(tile, lane)).bits();
            system.initialize_mem_sram_lane_byte(
                0, tile, kSourceAddress, lane,
                static_cast<std::uint8_t>(bits & 0xffu));
            system.initialize_mem_sram_lane_byte(
                1, tile, kSourceAddress, lane,
                static_cast<std::uint8_t>((bits >> 8) & 0xffu));
        }
    }

    const auto add = arithmetic_instruction(
        ftlpu::VxmAluOpcode::Add,
        ftlpu::VxmLaneOperand::StreamFloat16(32), kAddend);
    const auto subtract = arithmetic_instruction(
        ftlpu::VxmAluOpcode::Subtract,
        ftlpu::VxmLaneOperand::Alu(0), kSubtrahend);
    const auto multiply = arithmetic_instruction(
        ftlpu::VxmAluOpcode::Multiply,
        ftlpu::VxmLaneOperand::Alu(1), kMultiplier);

    write_init(argv[1], system);
    for (std::size_t column = 0; column < 4; ++column) {
        if (column < 2) {
            system.icu().enqueue_mem_nop(column, kVxmCycle - 2);
            system.icu().enqueue_mem(column, ftlpu::MemInstruction::Read(
                kSourceAddress, ftlpu::StreamId::West(column)));
            system.icu().enqueue_mem_nop(column, 2);
        } else {
            system.icu().enqueue_mem_nop(column, kVxmCycle + 1);
        }
        for (std::size_t address = 1; address <= 3; ++address)
            system.icu().enqueue_mem(column, ftlpu::MemInstruction::Write(
                address, ftlpu::StreamId::East(column)));
    }
    const std::array instructions {add, subtract, multiply};
    for (std::size_t alu = 0; alu < instructions.size(); ++alu) {
        system.icu().enqueue_vxm_nop(alu, kVxmCycle + alu);
        system.icu().enqueue_vxm(alu, instructions[alu]);
    }

    for (std::size_t cycle = 0; cycle < 28; ++cycle)
        system.tick(ftlpu::TspSliceSystem::LogSinks {});

    for (std::size_t tile = 0; tile < ftlpu::hw::kTileRows; ++tile) {
        for (std::size_t lane = 0; lane < ftlpu::hw::kLanesPerTile; ++lane) {
            const float expected[3] {
                input_value(tile, lane) + kAddend,
                (input_value(tile, lane) + kAddend) - kSubtrahend,
                ((input_value(tile, lane) + kAddend) - kSubtrahend) * kMultiplier,
            };
            for (std::size_t result = 0; result < 3; ++result) {
                std::uint32_t actual = 0;
                for (std::size_t byte = 0; byte < 4; ++byte)
                    actual |= static_cast<std::uint32_t>(
                        system.read_mem_sram_lane_byte(
                            byte, tile, result + 1, lane)) << (byte * 8);
                if (actual != std::bit_cast<std::uint32_t>(expected[result]))
                    throw std::runtime_error("C model VXM FP32 arithmetic mismatch");
            }
        }
    }
    write_golden(argv[2], system);

    std::ofstream schedule(argv[3], std::ios::trunc);
    if (!schedule) throw std::runtime_error("failed to open VXM arithmetic schedule");
    schedule << std::hex << std::setfill('0');
    for (std::size_t column = 0; column < 4; ++column) {
        if (column < 2) {
            write_record(schedule, command_record(column,
                ftlpu::isa::encode_icu_nop(kVxmCycle - 2)));
            write_record(schedule, mem_record(column, ftlpu::MemInstruction::Read(
                kSourceAddress, ftlpu::StreamId::West(column))));
            write_record(schedule, command_record(
                column, ftlpu::isa::encode_icu_nop(2)));
        } else {
            write_record(schedule, command_record(
                column, ftlpu::isa::encode_icu_nop(kVxmCycle + 1)));
        }
        for (std::size_t address = 1; address <= 3; ++address)
            write_record(schedule, mem_record(column, ftlpu::MemInstruction::Write(
                address, ftlpu::StreamId::East(column))));
    }
    for (std::size_t alu = 0; alu < instructions.size(); ++alu) {
        write_record(schedule, command_record(
            static_cast<std::uint8_t>(112 + alu),
            ftlpu::isa::encode_icu_nop(kVxmCycle + alu)));
        write_record(schedule, vxm_record(
            static_cast<std::uint8_t>(112 + alu),
            ftlpu::isa::encode_vxm_instruction(instructions[alu])));
    }

    std::cout << "C model VXM FP32 Add/Subtract/Multiply golden generated\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
}
