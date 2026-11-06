"""Explicit partial-resource extrapolation and sensitivity scenarios, not whole-core synthesis."""
import argparse,json,re
from pathlib import Path
EXP=Path(__file__).resolve().parents[1];FPGA=EXP.parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--run',required=True)
args=parser.parse_args()
if not re.fullmatch(r'[a-zA-Z0-9_-]+',args.run):
    parser.error('--run must be a simple run identifier')
out=EXP/'results'/args.run;out.mkdir()
known=dict(MEM_LUT=104*4953,SRF_LUT=128*2888,VXM_basic_LUT=256*1513,
    FF=104*284+128*2304+256*109,BRAM36=416*2,DSP=256*2)
known['LUT']=sum(known[x] for x in ['MEM_LUT','SRF_LUT','VXM_basic_LUT'])
log=(EXP/'results/parts001/vivado.log').read_text(errors='replace')
boards=[]
for pattern,name,rank in [('xcvu19p-fsvb3824-2-e','HTG-960',1),('xcv80*','Alveo V80',2),('xcvu440-flgb2377-2-e','HTG-840-2',3)]:
    chunk=re.search(r'^PATTERN='+re.escape(pattern)+r' MATCH_COUNT=1\n(.*?)(?=^PATTERN=|^# puts)',log,re.M|re.S).group(1)
    keys={k:int(v) if v else 0 for k,v in re.findall(r'^(LUT_ELEMENTS|FLIPFLOPS|BLOCK_RAMS|ULTRA_RAMS|DSP)=(\d*)$',chunk,re.M)}
    boards.append(dict(board=name,rank=rank,part=re.search(r'^PART=(.*)$',chunk,re.M).group(1),resources=keys,
      LUT_70pct_total_budget=keys['LUT_ELEMENTS']*7//10,LUT_remaining_at_70pct=keys['LUT_ELEMENTS']*7//10-known['LUT'],
      DSP_remaining_at_70pct=keys['DSP']*7//10-known['DSP'],BRAM36_remaining_at_70pct=keys['BLOCK_RAMS']*7//10-known['BRAM36'],
      LUT_sensitivity=[dict(unknown_extra_LUT=x,total_LUT=known['LUT']+x,utilization_pct=round(100*(known['LUT']+x)/keys['LUT_ELEMENTS'],2)) for x in [500000,1000000,1500000]]))
result=dict(known_partial=known,boards=boards,
    old_compute_only_proxies=dict(vector_4_MXM_LUT=4*32*8313,vector_4_MXM_DSP=4*32*8,block8_4_MXM_LUT=4*8*32*8313,block8_4_MXM_DSP=4*8*32*8),
    scope=['Known partial uses prior OOC MEM/SRF/VXM and target 16-lane geometry; not a full current branch top',
      'Unknown-extra scenarios are sensitivity inputs, NOT estimates or measured distributions',
      '70% is a resource planning policy including shell/debug, not a placement/routing guarantee',
      'V80 DSP58 and Versal mapping must be re-synthesized; UltraScale LUT proxy not a cross-family measurement',
      'No pruning of Block8, formats, capacity or physical LPU geometry is authorized by this report'])
(out/'resource_projection.json').write_text(json.dumps(result,indent=2))
(out/'project_resources.py').write_bytes(Path(__file__).read_bytes())
print(json.dumps(result,indent=2))
