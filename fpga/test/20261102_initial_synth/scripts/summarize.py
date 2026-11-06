"""Extract measured OOC resources and label linear projections separately."""
import csv
import hashlib
import json
from pathlib import Path
import re
from run import EXPERIMENT, FPGA, REPO

def number(text, label):
    m=re.search(r'^\|\s*'+re.escape(label)+r'\s*\|\s*([\d,.]+)\s*\|',text,re.M)
    return float(m.group(1).replace(',','')) if m else None

def main():
    out=EXPERIMENT/'results'/'analysis001'
    out.mkdir(exist_ok=True)
    rows=[]
    reports=list((EXPERIMENT/'results').glob('run*/*/utilization.rpt'))
    reports+=list((EXPERIMENT/'results').glob('recover*/utilization.rpt'))
    for p in sorted(reports):
        txt=p.read_text(errors='replace')
        timing=p.with_name('timing_summary.rpt')
        wns=None
        if timing.exists():
            m=re.search(r'WNS\(ns\).*?\n\s*-{3,}[^\n]*\n\s*([-\d.]+)',timing.read_text(errors='replace'),re.S)
            if m:wns=float(m.group(1))
        recovered=p.parent.name.startswith('recover')
        run_name=p.parent.name if recovered else p.parent.parent.name
        case_name='mem_leaf' if recovered else p.parent.name
        invalid=p.with_name('INVALID_FOR_PROJECTION.txt').exists()
        summary=p.parent.parent/'summary.json'
        completed=False
        if not recovered and summary.exists():
            completed=any(r.get('case')==case_name and r.get('returncode')==0 and r.get('synthesis_completed') for r in json.loads(summary.read_text(encoding='utf-8')))
        status='invalid_configuration' if invalid else ('checkpoint_recovery_area_only' if recovered else ('complete_OOC' if completed else 'partial_area_report_only'))
        row={'run':run_name,'case':case_name,'evidence_status':status,
             'LUT':number(txt,'CLB LUTs*'),'FF':number(txt,'CLB Registers'),
             'BRAM36_tiles':number(txt,'Block RAM Tile'),'URAM':number(txt,'URAM'),
             'DSP':number(txt,'DSPs'),'WNS_10ns':wns,
             'netlist_file_exists':p.with_name('netlist.v').exists(),
             'netlist_valid_for_simulation':completed and not invalid,
             'checkpoint_available':p.with_name('synthesized.dcp').exists(),
             'report_path':p.relative_to(FPGA).as_posix(),
             'report_sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
        rows.append(row)
    (out/'measured_resources.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
    if rows:
        with (out/'measured_resources.csv').open('w',newline='',encoding='utf-8-sig') as f:
            w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    selected={r['case']:r for r in rows if r['run'] in ['run007','run010','run012'] and not (r['run']=='run010' and r['case']=='alu_basic_bf16')}
    projection={
        'status':'linear_OOC_projection_not_integrated_synthesis',
        'profile':'LPU16: H=2,T=2,L=8,52 slices per hemisphere,2 banks,1024 rows',
        'MEM_bytes':2*52*2*2*8*1024,'MEM_leaf_count':416,'MEM_slice_count':104,
        'SRF_leaf_count':2*2*16*2,'SRF_data_bits':2*2*16*2*32*8*8,
        'SRF_valid_bits':2*2*16*2*32*8,'VXM_basic_instance_count':16*16,
        'exclusions':['native MXM','special ALU increments','VXM operand/control/LUT plumbing','MEM hemisphere/group glue','SXM','ICU','DMA/DDR/PCIe/ILA','placement/routing effects']}
    if all(k in selected for k in ['mem_slice_bram','srf_leaf','alu_basic_pruned','alu_basic_bf16']):
        mem=104*selected['mem_slice_bram']['LUT']
        srf=128*selected['srf_leaf']['LUT']
        basic=256*selected['alu_basic_pruned']['LUT']
        bf16=256*selected['alu_basic_bf16']['LUT']
        projection.update(MEM_LUT=mem,SRF_LUT=srf,VXM_basic_LUT=basic,VXM_bf16_basic_LUT=bf16,
            subtotal_full_basic_LUT=mem+srf+basic,subtotal_bf16_basic_LUT=mem+srf+bf16,
            MEM_BRAM36=104*selected['mem_slice_bram']['BRAM36_tiles'],
            compact16_slices_per_hemi_subtotal_bf16_LUT=32*selected['mem_slice_bram']['LUT']+56*selected['srf_leaf']['LUT']+bf16)
    projection['demo_model']={
        'SmolLM2_135M_FFN_W8_bytes':3*576*1536,
        'FFN_per_output_scale_BF16_bytes':2*(1536+1536+576),
        'FFN_input_BF16_bytes_batch1':576*2,
        'KV_cache_128_tokens_BF16_bytes':2*30*3*64*2*128,
        'weights_135M_INT8_approx_bytes':135_000_000,
        'KV_and_FFN_formulas':'config h=576, intermediate=1536, layers=30, KV heads=3, head dim=64; K and V BF16'}
    (out/'projection.json').write_text(json.dumps(projection,indent=2),encoding='utf-8')
    profile=REPO.parent/'FTLPU-CMODEL/config/mem-profiles/ftlpu-lpu16.json'
    (out/'reference_lpu16_profile.json').write_bytes(profile.read_bytes())
    print(json.dumps({'measurements':rows,'projection':projection},indent=2))

if __name__=='__main__':main()
