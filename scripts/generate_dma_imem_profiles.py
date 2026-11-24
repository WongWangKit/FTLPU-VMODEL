"""Refresh/check the mixed16/32 product top elaboration defaults from the software/CModel target."""
import argparse,json
from pathlib import Path
vm=Path(__file__).resolve().parents[1]
p=vm/'rtl/core/lpu_pkg.sv'
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');args=parser.parse_args()
targets={v:json.loads((vm.parent/f'FTLPU-CMODEL/config/ftlpu-lpu{v}-mixed.json').read_text(encoding='utf8')) for v in (16,32)}
begin='  // BEGIN generated DMA mixed iMEM defaults';end='  // END generated DMA mixed iMEM defaults'
lines=[begin]
for field,section,key,legacy in [
    ('mem_imem_depth','icu','mem_imem_depth',131072),
    ('mxm_imem_depth','icu','mxm_imem_depth',65536),
    ('program_response','program_load','response_fifo_depth',192),
    ('rt','external_memory','dma_fifo_depth_vectors',128),
    ('q','external_memory','ddr_request_queue_depth',384),
]:
    f='dma_mixed_'+field
    lines += [f'  function automatic integer {f}(input integer vector_bytes);','    case (vector_bytes)']
    for v,t in targets.items():lines += [f'      {v}: {f} = {t[section][key]};']
    lines += [f'      default: {f} = {legacy};','    endcase','  endfunction']
lines.append(end);new='\n'.join(lines);s=p.read_text(encoding='utf8')
if begin not in s: result=s.replace('package lpu_pkg;','package lpu_pkg;\n'+new,1)
else:
 a=s.index(begin);b=s.index(end,a)+len(end);result=s[:a]+new+s[b:]
if args.check:
 if s!=result:raise SystemExit('RTL defaults differ from mixed target JSON')
else:p.write_text(result,encoding='utf8')
print('mixed16/32: P/RT/Q and MEM/MXM elaboration constants match target JSON')
