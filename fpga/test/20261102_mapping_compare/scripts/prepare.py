"""Generate experiment-only variants; all originals remain read-only."""
from pathlib import Path
import random
import struct
from run import EXP, REPO

def replace_once(text, old, new):
    assert text.count(old)==1, old
    return text.replace(old,new)

def main():
    rtl=EXP/'rtl'
    base=(rtl/'mem_leaf_bram.sv').read_text()
    (rtl/'mem_leaf_uram.sv').write_text(replace_once(base,'ram_style = "block"','ram_style = "ultra"'))
    mul=(REPO/'rtl/vxm/lpu_vxm_mul8x8.sv').read_text()
    mul=replace_once(mul,'output logic [15:0] product_o','(* use_dsp = "yes" *) output logic [15:0] product_o')
    (rtl/'mul8x8_dsp.sv').write_text(mul)
    pkg=(REPO/'rtl/vxm/lpu_vxm_math_pkg.sv').read_text()
    dsp=replace_once(pkg,'  logic [47:0] product;','  (* use_dsp = "yes" *) logic [47:0] product;')
    (rtl/'math_dsp_pkg.sv').write_text(dsp)
    (rtl/'math_reference_pkg.sv').write_text(replace_once(pkg,'package lpu_vxm_math_pkg;','package fpga_reference_math_pkg;'))
    # Keep exactly the product arithmetic, rounding and format behavior.
    rng=random.Random(0x20261102)
    old=EXP.parent/'20261102_initial_synth/tb/alu_basic_tb.sv'
    tb=old.read_text()
    extra=[]
    for fmt in range(3):
        for _ in range(400):
            if fmt==0:
                a=(rng.randrange(2)<<15)|(rng.randrange(7,23)<<10)|rng.randrange(1024)
                b=(rng.randrange(2)<<15)|(rng.randrange(7,23)<<10)|rng.randrange(1024)
                av=struct.unpack('>e',a.to_bytes(2,'big'))[0];bv=struct.unpack('>e',b.to_bytes(2,'big'))[0]
                expected=int.from_bytes(struct.pack('>e',av*bv),'big')
            elif fmt==1:
                a=(rng.randrange(2)<<15)|(rng.randrange(117,137)<<7)|rng.randrange(128)
                b=(rng.randrange(2)<<15)|(rng.randrange(117,137)<<7)|rng.randrange(128)
                av=struct.unpack('>f',(a<<16).to_bytes(4,'big'))[0];bv=struct.unpack('>f',(b<<16).to_bytes(4,'big'))[0]
                bits=int.from_bytes(struct.pack('>f',av*bv),'big')
                expected=(bits+0x7fff+((bits>>16)&1))>>16
            else:
                a=(rng.randrange(2)<<31)|(rng.randrange(117,137)<<23)|rng.randrange(1<<23)
                b=(rng.randrange(2)<<31)|(rng.randrange(117,137)<<23)|rng.randrange(1<<23)
                av=struct.unpack('>f',a.to_bytes(4,'big'))[0];bv=struct.unpack('>f',b.to_bytes(4,'big'))[0]
                expected=int.from_bytes(struct.pack('>f',av*bv),'big')
            # The original VXM arithmetic flushes half subnormals to zero.
            if fmt==0 and expected&0x7c00==0: expected &= 0x8000
            extra.append(f"    test_op({fmt},3,32'h{a:08x},32'h{b:08x},32'h{expected:08x});")
    tb=replace_once(tb,'    @(negedge clk_i); input_valid_i=1; data_format_i=3;', '\n'.join(extra)+'\n    @(negedge clk_i); input_valid_i=1; data_format_i=3;')
    tb=replace_once(tb,'#10000;','#200000;')
    (EXP/'tb/alu_basic_tb.sv').write_text(tb)
    srf=(EXP.parent/'20261102_initial_synth/tb/srf_leaf_tb.sv').read_text()
    srf=replace_once(srf,'t<128','t<2048')
    srf=replace_once(srf,'#10000;','#100000;')
    (EXP/'tb/srf_leaf_tb.sv').write_text(srf)
    print('Prepared MEM/ALU/MXM variants and independent ALU multiply bit-pattern cases.')

if __name__=='__main__':main()
