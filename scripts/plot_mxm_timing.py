"""Plot observed public-port simulation traces; never synthesize expected waves.

python scripts/plot_mxm_timing.py --simulate
Produces standalone SVG timing diagrams, a browsable report, CSV/VCD and hashes.
"""
import argparse
import csv
import hashlib
import html
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/mxm_supercell'
OUT = ROOT / 'output/instruction_supercell_array_test_results'
CONTROL = 'lpu_mxm_control_tb_k4_n3'
FRONT = 'lpu_mxm_frontend_tb'
BACKEND = 'lpu_mxm_backend_tb_k4_n8'
CORE = 'lpu_mxm_core_tb'
REFILL = CORE + '_s1'
LONG = CORE + '_s7'
MIXED = (CORE+'_s4', CORE+'_s5')
COLORS = ['#2864B4', '#147C69', '#AA6B15', '#8056A5', '#B54248']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_trace(name, group):
    records = list(csv.DictReader((BUILD/'traces'/f'{name}.csv').open(encoding='utf-8')))
    legal = [r for r in records if r['reset_n'] == r['run'] == r['scoring'] == '1']
    if group == 'row':
        origin = min(float(r['sample_ns']) for r in legal if r['row'] == '0' and r['compute_update'] == '1')
    else:
        origin = min(float(r['sample_ns']) for r in legal if r['column'] == '0' and
                     r['compute_row_valid'] == '1' and r['compute_index'] == '0')
    rows = [dict() for _ in range(4)]
    for r in legal:
        cycle = round((float(r['sample_ns'])-origin)/10)
        assert abs((float(r['sample_ns'])-origin)/10-cycle) < 1e-8
        assert r['fault'] == '0', f'fault in plotted legal trace: {r}'
        rows[int(r[group])][cycle] = r
    return rows, origin


def read_stage_trace(name, launch_key):
    records=list(csv.DictReader((BUILD/'traces'/f'{name}.csv').open(encoding='utf-8')))
    legal=[r for r in records if r['reset_n']==r['run']=='1' and r.get('scoring','1')=='1']
    origin=min(float(r['sample_ns']) for r in legal if r['column']=='0' and r[launch_key]=='1')
    columns=[dict() for _ in range(4)]
    for r in legal:
        assert r['fault']=='0',r
        cycle=round((float(r['sample_ns'])-origin)/10)
        columns[int(r['column'])][cycle]=r
    return columns,origin


OPERATIONS = ['DIRECT_OUT', 'STORE', 'ACC_STORE', 'ACC_OUT']


def measure_core(columns, refill=False, batch=32):
    """Measure consumed inputs, output/control phases and actual bank services."""
    launch = {key:[t for t,d in sorted(columns[0].items()) if d[key]=='1']
              for key in ('load_launch','compute_launch','backend_launch')}
    assert launch['load_launch']==([0,32,32+batch,32+2*batch] if refill else [0,32])
    assert launch['compute_launch']==[32+s*batch for s in range(4)]
    assert launch['backend_launch']==[51,51+batch//2,51+batch,51+2*batch,51+3*batch]
    first_weights,first_activations,first_partials,first_outputs=[],[],[],[]
    memory_pairs=0
    output_delays=[]
    output_formats=[0,0]
    direct_operand_pairs=0
    for r,data in enumerate(columns):
        full=[False,False];last_activation=[-1000,-1000]
        weights=[None,None]
        first_weights.append(min(t for t,d in data.items() if d['weight_accepted']=='1'))
        first_activations.append(min(t for t,d in data.items() if d['activation_accepted']=='1'))
        first_partials.append(min(t for t,d in data.items() if d['partial_valid']=='1'))
        first_outputs.append(min(t for t,d in data.items() if d['result_valid']=='1'))
        accepted=[t for t,d in sorted(data.items()) if d['activation_accepted']=='1']
        expected=[start+3*r+1+i for start in launch['compute_launch'] for i in range(batch)]
        assert accepted==expected
        for t,d in sorted(data.items()):
            if d['activation_accepted']=='1':
                b=int(d['activation_buffer'])
                assert full[b],f'compute before weight ready at row {r}, E{t}'
                last_activation[b]=t
            if d['weight_accepted']=='1':
                b=int(d['weight_buffer']);index=int(d['weight_index'])
                assert t>last_activation[b],'refill clobbers local activation'
                if index==0: full[b]=False;weights[b]=[]
                assert index==len(weights[b])
                weights[b].append(d['weight_lane0'])
                full[b]=index==31
            # Cell monitors are the bottom-row physical SC ports, not the row
            # inputs above. Check each local write/compute phase independently.
            cell_a=[(start+1+r,start+batch+r,s%2) for s,start in enumerate(launch['compute_launch'])]
            cell_w=[(start+1+(9*r if s<2 else r),start+32+r,s%2) for s,start in enumerate(launch['load_launch'])]
            expected_a=[b for lo,hi,b in cell_a if lo<=t<=hi]
            expected_w=[b for lo,hi,b in cell_w if lo<=t<=hi]
            assert int(d['cell_activation_accepted'])==bool(expected_a)
            assert int(d['cell_weight_accepted'])==bool(expected_w)
            if expected_a:assert int(d['cell_activation_buffer'])==expected_a[0]
            if expected_w:assert int(d['cell_weight_buffer'])==expected_w[0]
            if expected_a and expected_w:assert expected_a[0]!=expected_w[0]
            assert d['backend_slot_valid']==d['partial_valid']
            if d['backend_slot_valid']=='1' and d['backend_operation'] in ('0','3'):
                output=data[t+4]
                assert output['result_valid']=='1' and output['result_tag']==d['partial_tag']
                assert output['result_address']==d['backend_address']
                assert output['result_bf16']==d['backend_bf16']
                tag=int(output['result_tag'])
                issued=launch['backend_launch'][3 if tag<3*batch else 4]+tag%batch+r
                assert t+4-issued==6
                output_delays.append(t+4-issued)
                output_formats[int(output['result_bf16'])]+=1
            if d['backend_slot_valid']=='1' and d['backend_operation']!='0':
                address=int(d['backend_address']);bank=address%2
                service=data[t+4 if d['backend_operation']=='1' else t-1]
                assert service[f'bank{bank}_valid']=='1'
                assert service[f'bank{bank}_write']==('1' if d['backend_operation']=='1' else '0')
                assert int(service[f'bank{bank}_address'])*2+bank==address
                memory_pairs+=1
                if d['backend_operation'] in ('2','3'):
                    alu=data[t+1]
                    assert alu['alu_valid']==alu['partial_accepted']=='1'
                    assert alu['operand_a0']==alu['accepted_partial_lane0']==d['partial_lane0']
                    assert alu['alu_tag']==alu['accepted_partial_tag']==d['partial_tag']
                    assert alu['alu_address']==d['backend_address']
                    direct_operand_pairs+=1
                if d['backend_operation']=='2':
                    write=data[t+4]
                    assert write[f'bank{bank}_valid']==write[f'bank{bank}_write']=='1'
                    assert int(write[f'bank{bank}_address'])*2+bank==address
        assert sum(int(d['result_valid']) for d in data.values())==2*batch
    assert first_weights==[1,4,7,10] and first_activations==[33,36,39,42]
    assert first_partials==[53,54,55,56]
    assert first_outputs==[57+2*batch+c for c in range(4)]
    assert direct_operand_pairs==2*batch*4
    return dict(activation_batch_count=batch,launches=launch,first_weight_capture=first_weights,
                first_activation_capture=first_activations,first_partial=first_partials,
                first_output=first_outputs,checked_memory_requests=memory_pairs,
                output_launch_delays=sorted(set(output_delays)),output_batches_by_format=output_formats,
                partial_available_to_output_cycles=4,direct_operand_pairs=direct_operand_pairs,
                compute_boundary_gaps=[b-a-batch for a,b in zip(launch['compute_launch'],launch['compute_launch'][1:])])


def draw_core_schedule(columns, summary, stem, refill=False):
    batch=summary['activation_batch_count']
    p=Diagram('完整核心实测：连续更换四套权重，计算无空拍' if batch==32 else
              '完整核心实测：40批activation配合32拍权重加载，计算无空拍',
              '统一 E0 = 本次仿真首条前端权重加载；输入/Bank 为沿上实际服务，指令状态/结果为沿后采样。',-1,200 if batch==32 else 232,10,10)
    data=columns[0]
    for row,(key,label) in enumerate((('load_launch','前端：权重指令发射'),('compute_launch','前端：计算指令发射'),('backend_launch','后端：累加指令发射'))):
        p.binary(row,label,data,key,COLORS[row])
        for t in summary['launches'][key]:p.mark(row,t,f'E{t}',COLORS[row])
    p.bus(3,'SL0 权重写入',data,lambda d:(f'Weight B{d["weight_buffer"]}',COLORS[int(d['weight_buffer'])]) if d.get('weight_accepted')=='1' else ('—','#8995A5'))
    p.bus(4,'SL0 activation 接收',data,lambda d:(f'Compute B{d["activation_buffer"]}',COLORS[int(d['activation_buffer'])]) if d.get('activation_accepted')=='1' else ('—','#8995A5'))
    p.bus(5,'后端列0 执行指令',data,lambda d:(OPERATIONS[int(d['backend_operation'])],COLORS[int(d['backend_operation'])]) if d.get('backend_slot_valid')=='1' else ('—','#8995A5'))
    p.binary(6,'阵列列0 部分和',data,'partial_valid',COLORS[0])
    for bank in (0,1):
        p.bus(7+bank,f'后端 Bank{bank} 服务',data,lambda d,b=bank:('W' if d[f'bank{b}_write']=='1' else 'R',COLORS[1] if d[f'bank{b}_write']=='1' else COLORS[0]) if d.get(f'bank{b}_valid')=='1' else ('—','#8995A5'))
    p.bus(9,'后端列0 FP32 输出',data,lambda d:(('ACC_OUT' if int(d['result_tag'])<3*batch else 'DIRECT_OUT'),COLORS[1] if int(d['result_tag'])<3*batch else COLORS[2]) if d.get('result_valid')=='1' else ('—','#8995A5'))
    p.save(stem)


class Diagram:
    def __init__(self, title, subtitle, lo, hi, tracks, tick=1):
        self.lo, self.hi = lo, hi
        self.left, self.width, self.top, self.rowh = 290, 1900, 180, 58
        self.height = self.top + tracks*self.rowh + 100
        self.scale = (self.width-self.left-50)/(hi-lo)
        self.parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.width}" height="{self.height}" viewBox="0 0 {self.width} {self.height}" role="img" aria-label="{html.escape(title)}">',
                      '<style>text{font-family:Microsoft YaHei,Arial,sans-serif;fill:#10233F} .axis{fill:#53657B;font-size:19px} .label{font-size:22px} .small{font-size:19px}</style>',
                      f'<rect width="{self.width}" height="{self.height}" fill="white"/>']
        self.text(title, 36, 48, 34, bold=True)
        self.text(subtitle, 36, 88, 22, color='#53657B')
        self.text('相对上升沿 / 拍', 36, 143, 21)
        for c in range(lo, hi+1):
            x = self.x(c)
            self.parts.append(f'<line x1="{x}" x2="{x}" y1="161" y2="{self.height-85}" stroke="#E0E6ED" stroke-width="1"/>')
            if c % tick == 0:
                self.text(str(c), x, 145, 19, anchor='middle', color='#53657B')
        self.text('每条竖线代表一个上升沿，周期10 ns；实际输入/Bank服务与沿后状态的采样约定见图注。', 36, self.height-35, 20, color='#53657B')

    def x(self, cycle):
        return round(self.left+(cycle-self.lo)*self.scale, 2)

    def y(self, row):
        return self.top+row*self.rowh

    def text(self, value, x, y, size=21, color='#10233F', anchor='start', bold=False):
        self.parts.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" text-anchor="{anchor}" font-weight="{600 if bold else 400}">{html.escape(str(value))}</text>')

    def label(self, row, name):
        self.text(name, 36, self.y(row)+30, 22)

    def binary(self, row, name, records, key, color=COLORS[0]):
        self.label(row, name)
        yy = self.y(row)
        points = []
        previous = None
        for c in range(self.lo, self.hi):
            v = int(records.get(c, {}).get(key, '0'))
            y = yy+(10 if v else 38)
            x, xn = self.x(c), self.x(c+1)
            if v:
                self.parts.append(f'<rect x="{x}" y="{yy+10}" width="{xn-x}" height="28" fill="{color}" opacity="0.12"/>')
            if previous is None:
                points.append(f'M{x},{y}')
            elif v != previous:
                points.append(f'L{x},{y}')
            points.append(f'L{xn},{y}')
            previous = v
        self.parts.append(f'<path d="{" ".join(points)}" fill="none" stroke="{color}" stroke-width="2.5"/>')

    def bus(self, row, name, records, value_fn):
        self.label(row, name)
        values = [value_fn(records.get(c, {})) for c in range(self.lo, self.hi)]
        start = self.lo
        for i in range(1, len(values)+1):
            if i != len(values) and values[i] == values[i-1]:
                continue
            end = self.lo+i
            label, color = values[i-1]
            x, xn, y = self.x(start), self.x(end), self.y(row)+7
            w = xn-x
            notch = min(7, w/5)
            points = f'{x+notch},{y} {xn-notch},{y} {xn},{y+16} {xn-notch},{y+32} {x+notch},{y+32} {x},{y+16}'
            self.parts.append(f'<polygon points="{points}" fill="{color}" fill-opacity="0.10" stroke="{color}" stroke-width="1.5"/>')
            if label and (len(label)*12 < w or w > 110):
                self.text(label, (x+xn)/2, y+23, 20, anchor='middle')
            start = end

    def mark(self, row, cycle, label, color=COLORS[0]):
        x, y = self.x(cycle), self.y(row)
        self.parts.append(f'<circle cx="{x}" cy="{y+7}" r="4.5" fill="{color}"/>')
        self.text(label, x+7, y-5, 18, color=color)

    def save(self, stem):
        self.parts.append('</svg>')
        target = OUT/'figures'/f'{stem}.svg'
        target.write_text('\n'.join(self.parts), encoding='utf-8')
        return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulate', action='store_true')
    args = parser.parse_args()
    if args.simulate:
        for top in ('lpu_mxm_output_pipe_tb','lpu_mxm_control_tb', FRONT, 'lpu_mxm_backend_tb', CORE):
            subprocess.run([sys.executable, str(ROOT/'scripts/test_mxm_supercell.py'), '--top', top, '--trace'], cwd=ROOT, check=True)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/'traces').mkdir(exist_ok=True)
    (OUT/'figures').mkdir(exist_ok=True)
    (OUT/'logs').mkdir(exist_ok=True)
    control, control_origin = read_trace(CONTROL, 'row')
    front, front_origin = read_trace(FRONT, 'column')
    backend,backend_origin=read_stage_trace(BACKEND,'launch')
    # Main report is the four-DISTINCT-weight run, not reuse of two old tiles.
    core,core_origin=read_stage_trace(REFILL,'load_launch')
    refill,refill_origin=read_stage_trace(REFILL,'load_launch')
    core_summary=measure_core(core,True)
    refill_summary=measure_core(refill,True)
    mixed=[read_stage_trace(name,'load_launch')[0] for name in MIXED]
    mixed_summaries=[measure_core(columns,True) for columns in mixed]
    long,long_origin=read_stage_trace(LONG,'load_launch')
    long_summary=measure_core(long,True,40)
    negative_tests=[]
    for scenario,edge in ((2,32),(3,119),(6,54)):
        records=list(csv.DictReader((BUILD/'traces'/f'{CORE}_s{scenario}.csv').open(encoding='utf-8')))
        origin=min(float(d['sample_ns']) for d in records if d['load_launch']=='1')
        fault=min((d for d in records if d['fault']=='1'),key=lambda d:float(d['sample_ns']))
        observed=round((float(fault['sample_ns'])-origin)/10)
        assert observed==edge
        assert fault['frontend_fault']==('1' if scenario==2 else '0')
        assert fault['backend_fault']==('0' if scenario==2 else '1')
        negative_tests.append(dict(scenario=scenario,fault_cycle=observed,frontend_fault=fault['frontend_fault'],backend_fault=fault['backend_fault']))
    draw_core_schedule(core,core_summary,'00-core-schedule')
    draw_core_schedule(long,long_summary,'10-core-count40',True)
    p=Diagram('连续换权重：每个 Supercell 都在旧权重用完后下一拍开始替换',
              '同主图E0；只展示最底层四个Supercell。每条波形来自该单元的真实写入/activation采样端口。',58,110,8,5)
    for c,data in enumerate(refill):
        p.bus(2*c,f'SC{c} 权重实际写入',data,lambda d:(f'B{d["cell_weight_buffer"]}',COLORS[int(d['cell_weight_buffer'])]) if d.get('cell_weight_accepted')=='1' else ('—','#8995A5'))
        p.bus(2*c+1,f'SC{c} activation计算',data,lambda d:(f'B{d["cell_activation_buffer"]}',COLORS[int(d['cell_activation_buffer'])]) if d.get('cell_activation_accepted')=='1' else ('—','#8995A5'))
        p.mark(2*c,65+c,f'E{65+c}开始重载B0')
        p.mark(2*c+1,64+c,f'E{64+c}最后使用旧B0')
        p.mark(2*c+1,97+c,f'E{97+c}使用新B0',COLORS[1])
    p.save('07-core-refill')
    compute_events, load_events = [], []
    for r, data in enumerate(control):
        compute_events.append([(c, d['compute_instruction']) for c, d in data.items() if d['compute_update'] == '1'])
        load_events.append([(c, d['load_instruction']) for c, d in data.items() if d['load_update'] == '1'])
    for events, interval in ((compute_events, 3), (load_events, 3)):
        for r in range(1, 4):
            assert [(c+interval, word) for c, word in events[r-1]] == events[r]
    assert [c for c, _ in compute_events[0]] == [0,32,72]
    assert [c for c, _ in load_events[0]] == [0,32,36,41,44]
    first_results = [min(c for c,d in data.items() if d['result_valid']=='1' and d['result_tag']=='0') for data in front]
    assert first_results == [21,22,23,24]
    spec=importlib.util.spec_from_file_location('numeric_reference',ROOT/'sim/cmodel/generate_mxm_supercell_vectors.py')
    numeric_reference=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(numeric_reference)
    writeback_pairs=[]
    observed_operands=0
    read_request_delays=[]
    store_write_delays=[]
    checked_formatted_outputs=0
    for col,data in enumerate(backend):
        memory={}
        for cycle,d in sorted(data.items()):
            if d['slot_valid']==d['partial_valid']=='1' and d['slot_operation']!='0':
                service=data[cycle+3 if d['slot_operation']=='1' else cycle-2];bank=int(d['slot_address'])%2
                assert service[f'bank{bank}_valid']=='1'
                assert service[f'bank{bank}_write']==('1' if d['slot_operation']=='1' else '0')
                assert int(service[f'bank{bank}_address'])*2+bank==int(d['slot_address'])
            if d['slot_valid']==d['partial_valid']=='1' and d['slot_operation']=='0':
                output=data[cycle+3]
                expected=int(d['partial_lane0'],16)
                if d['slot_bf16']=='1':expected=numeric_reference.fp32_to_bf16(expected)
                assert output['result_valid']=='1' and output['result_tag']==d['partial_tag']
                assert output['result_bf16']==d['slot_bf16'] and int(output['result_lane0'],16)==expected
                checked_formatted_outputs+=1
            if d['launch']=='1' and col==0:
                issue=data[cycle+1]
                if issue['issue_operation']!='0':
                    delay=6 if issue['issue_operation']=='1' else 1
                    service=data[cycle+delay];bank=int(issue['issue_address'])%2
                    assert service[f'bank{bank}_valid']=='1'
                    (store_write_delays if delay==6 else read_request_delays).append(delay)
            for bank in (0,1):
                if d[f'bank{bank}_valid']!='1':continue
                row=int(d[f'bank{bank}_address']);key=(bank,row)
                if d[f'bank{bank}_write']=='1':
                    memory[key]=int(d[f'bank{bank}_data0'],16)
                else:
                    intake=data[cycle+2];alu=data[cycle+2]
                    assert alu['alu_valid']=='1'
                    assert int(alu['alu_address'])==row*2+bank
                    assert alu['operand_a0']==intake['partial_lane0']
                    assert int(alu['operand_b0'],16)==memory[key]
                    observed_operands+=1
                    if intake['slot_operation']=='3':
                        output=data[cycle+5]
                        expected=numeric_reference.fp32_add(int(alu['operand_a0'],16),int(alu['operand_b0'],16))
                        if intake['slot_bf16']=='1':expected=numeric_reference.fp32_to_bf16(expected)
                        assert output['result_valid']=='1' and output['result_tag']==intake['partial_tag']
                        assert output['result_bf16']==intake['slot_bf16'] and int(output['result_lane0'],16)==expected
                        checked_formatted_outputs+=1
                    if intake['slot_operation']=='2':
                        write=data[cycle+5]
                        assert write[f'bank{bank}_valid']==write[f'bank{bank}_write']=='1'
                        assert int(write[f'bank{bank}_address'])==row
                        expected=numeric_reference.fp32_add(int(alu['operand_a0'],16),int(alu['operand_b0'],16))
                        assert int(write[f'bank{bank}_data0'],16)==expected
                        writeback_pairs.append(dict(column=col,read_cycle=cycle,write_cycle=cycle+5,address=row*2+bank))
    assert len(writeback_pairs)==512 and observed_operands==1024
    assert len(read_request_delays)==8 and len(store_write_delays)==5
    assert checked_formatted_outputs==1152
    assert sum(int(d['partial_valid']) for data in core for d in data.values())==512
    assert sum(int(d['result_valid']) for data in core for d in data.values())==256
    assert sum(int(d['result_valid']) for data in front for d in data.values()) == 416
    compute_names = {word:f'C{i} / COUNT={((int(word,16)>>3)&65535)} / B{(int(word,16)>>2)&1}'
                     for i, (_,word) in enumerate(compute_events[0])}
    compute_colors = {word:COLORS[i] for i,(_,word) in enumerate(compute_events[0])}
    p = Diagram('附录：前端计算队列单测，32 / 40 / 32 拍切换',
                '控制传播单测，无权重数据通路，不证明权重就绪；与图02共用单测 E0，不能拼接到完整核心时间轴。', -1, 115, 8, 5)
    for r in range(4):
        p.bus(2*r, f'SL{r} 计算指令', control[r], lambda d:(compute_names.get(d.get('compute_instruction'), '—'), compute_colors.get(d.get('compute_instruction'),'#8995A5')))
        p.binary(2*r+1, f'SL{r} compute_valid', control[r], 'compute_valid', COLORS[r%3])
        for c,word in compute_events[r]:
            p.mark(2*r,c,str(c),compute_colors[word])
    p.save('01-compute')
    # Keep the SAME origin as the compute-control unit test. Never silently
    # move the first COLUMN launch to E0 and imply it precedes weight loading.
    load_origin = 0
    load_view = control
    load_names = {load_events[0][0][1]:('MATRIX','#8995A5')}
    for i, (_,word) in enumerate(load_events[0][1:]):
        load_names[word] = (f'{chr(65+i)} / COL{int(word,16)>>57&63}',COLORS[i])
    p = Diagram('附录：前端权重队列单测，仅验证逐层接力',
                '与图01同一次控制单测、同一 E0；首条 MATRIX 在 E0，单列 A/B/C/D 在 E32/36/41/44。无实际权重数据。', -1, 60, 8, 5)
    for r in range(4):
        p.bus(2*r,f'SL{r} 加载指令',load_view[r],lambda d:load_names.get(d.get('load_instruction'),('—','#8995A5')))
        p.binary(2*r+1,f'SL{r} load_valid',load_view[r],'load_valid',COLORS[0])
        for c,word in load_events[r][1:]:
            pos = c-load_origin
            p.mark(2*r,pos,str(pos),load_names[word][1])
    p.save('02-load-relay')
    p = Diagram('附录：独立前端阵列测试，纵向三拍、横向一拍',
                '局部 E0 = 该前端测试首次计算；先前权重加载未在本局部图中展示。与完整核心为不同仿真。', -1, 31, 8)
    for r in range(4):
        p.binary(r,f'SL{r} compute_valid',front[r],'compute_row_valid',COLORS[0])
        first = min(c for c,d in front[r].items() if d['compute_row_valid']=='1')
        p.mark(r,first,f'E{first}')
    for c in range(4):
        p.binary(4+c,f'列{c} result_valid',front[c],'result_valid',COLORS[1])
        p.mark(4+c,first_results[c],f'E{first_results[c]}',COLORS[1])
    p.save('03-array-startup')
    memory_origin=writeback_pairs[0]['read_cycle']
    memory_view={c-memory_origin:d for c,d in backend[0].items()}
    p=Diagram('附录：独立后端测试，提前预读与新部分和直接进入 A1',
              'E0 = 首次 ACC_STORE 预读服务沿；E2新部分和与旧值同拍进入A1，E5原位写回。输入、Bank和ALU均沿前采样。',-1,12,6)
    for bank in (0,1):
        p.bus(bank,f'Bank{bank} 访问',memory_view,
              lambda d,b=bank:((('W' if d[f'bank{b}_write']=='1' else 'R')+str(int(d[f'bank{b}_address'])*2+b)),
                               COLORS[1] if d[f'bank{b}_write']=='1' else COLORS[0]) if d.get(f'bank{b}_valid')=='1' else ('—','#8995A5'))
    p.bus(2,'新部分和采样 tag',memory_view,lambda d:(d['partial_tag'],COLORS[0]) if d.get('partial_valid')=='1' else ('—','#8995A5'))
    p.mark(2,2,f'tag{memory_view[2]["partial_tag"]} 对应 R0')
    p.binary(3,'ALU A1 采样',memory_view,'alu_valid',COLORS[0])
    p.bus(4,'A[0] 新部分和',memory_view,lambda d:(d['operand_a0'],COLORS[0]) if d.get('alu_valid')=='1' else ('—','#8995A5'))
    p.bus(5,'B[0] SRAM 旧值',memory_view,lambda d:(d['operand_b0'],COLORS[1]) if d.get('alu_valid')=='1' else ('—','#8995A5'))
    p.mark(0,0,'读地址0',COLORS[0]);p.mark(0,5,'写回地址0：+5拍',COLORS[1])
    p.save('04-backend')
    p=Diagram('完整 MXM 核心：阵列部分和 → 存储累加 → FP32 输出',
              '与图00相同仿真、相同 E0 = 首条前端权重加载；此处放大 ACC_OUT → DIRECT_OUT 连续输出。',110,195,8,5)
    for c in range(4):
        p.binary(2*c,f'列{c} partial_valid',core[c],'partial_valid',COLORS[0])
        p.bus(2*c+1,f'列{c} FP32 输出',core[c],
              lambda d:('ACC_OUT / tag64–95',COLORS[1]) if d.get('result_valid')=='1' and int(d['result_tag'])<96 else
                       (('DIRECT_OUT / tag96–127',COLORS[2]) if d.get('result_valid')=='1' else ('—','#8995A5')))
        first=min(t for t,d in core[c].items() if d['result_valid']=='1')
        switch=min(t for t,d in core[c].items() if d['result_valid']=='1' and d['result_tag']=='96')
        p.mark(2*c+1,first,f'E{first}',COLORS[1]);p.mark(2*c+1,switch,f'E{switch}',COLORS[2])
    p.save('05-core')
    p=Diagram('完整核心：四层权重写入和 activation 接收的实际边沿',
              '与图00共用 E0；SL0 在 E32 写完 B0，E33 接收首个 activation，同时开始写 B1；各层相差三拍。',24,85,8,5)
    for r,data in enumerate(core):
        p.bus(2*r,f'前端 SL{r} 权重写入',data,lambda d:(f'B{d["weight_buffer"]}',COLORS[int(d['weight_buffer'])]) if d.get('weight_accepted')=='1' else ('—','#8995A5'))
        p.bus(2*r+1,f'前端 SL{r} activation',data,lambda d:(f'B{d["activation_buffer"]}',COLORS[int(d['activation_buffer'])]) if d.get('activation_accepted')=='1' else ('—','#8995A5'))
        p.mark(2*r,32+3*r,f'B0最后写 E{32+3*r}')
        p.mark(2*r+1,33+3*r,f'B0首次读 E{33+3*r}')
    p.save('06-core-inputs')
    p=Diagram('完整核心：BF16 / FP32 双向连续输出，提前发射、固定六拍输出',
              '上下为两次独立核心仿真，各自E0均为首次权重加载。E147切换后端指令，E153切换结果格式，输出无空拍。',145,160,10)
    for case,columns in enumerate(mixed):
        data=columns[0];row=case*5
        p.bus(row,f'测试{case+1} 提前发射控制',data,lambda d:(OPERATIONS[int(d['issue_operation'])]+'/'+('BF16' if d['issue_bf16']=='1' else 'FP32'),COLORS[int(d['issue_bf16'])]) if d.get('issue_valid')=='1' else ('—','#8995A5'))
        p.binary(row+1,'列0 result_valid',data,'result_valid',COLORS[0])
        p.bus(row+2,'列0 结果格式',data,lambda d:(('BF16' if d['result_bf16']=='1' else 'FP32'),COLORS[int(d['result_bf16'])]) if d.get('result_valid')=='1' else ('—','#8995A5'))
        p.bus(row+3,'列0 result_tag',data,lambda d:(d['result_tag'],COLORS[0]) if d.get('result_valid')=='1' else ('—','#8995A5'))
        p.bus(row+4,'列0 lane0 原始编码',data,lambda d:(d['result_lane0'],COLORS[0]) if d.get('result_valid')=='1' else ('—','#8995A5'))
        p.mark(row,147,'E147');p.mark(row+2,153,'E153 = +6拍')
    p.save('08-output-formats')
    p=Diagram('完整核心：从 A/B 会合沿倒推预读，无新部分和等待寄存器',
              '同主图E0。E83发射，E84预读，E85阵列结果可用；E86新A/旧B直接进入A1，E89写回。',81,94,8)
    data=core[0]
    p.binary(0,'后端指令发射',data,'backend_launch',COLORS[2]);p.mark(0,83,'E83')
    for bank in (0,1):
        p.bus(1+bank,f'Bank{bank} 实际服务',data,lambda d,b=bank:(('W' if d[f'bank{b}_write']=='1' else 'R')+str(int(d[f'bank{b}_address'])*2+b),COLORS[1] if d[f'bank{b}_write']=='1' else COLORS[0]) if d.get(f'bank{b}_valid')=='1' else ('—','#8995A5'))
    p.bus(3,'阵列可用部分和 tag',data,lambda d:(d['partial_tag'],COLORS[0]) if d.get('partial_valid')=='1' else ('—','#8995A5'));p.mark(3,85,'tag32 在 E85可用')
    p.bus(4,'本沿新部分和采样 tag',data,lambda d:(d['accepted_partial_tag'],COLORS[0]) if d.get('partial_accepted')=='1' else ('—','#8995A5'))
    p.binary(5,'A1 同拍采样 A/B',data,'alu_valid',COLORS[1]);p.mark(5,86,'E86直接进入A1')
    for row,key,label in ((6,'operand_a0','A[0] 新部分和'),(7,'operand_b0','B[0] SRAM预读值')):
        p.bus(row,label,data,lambda d,k=key:(d[k],COLORS[0]) if d.get('alu_valid')=='1' else ('—','#8995A5'))
    p.mark(1,84,'R0 E84');p.mark(1,89,'W0 E89：读后5拍',COLORS[1])
    p.save('09-core-prefetch')
    copied = []
    for name in (CONTROL,FRONT,BACKEND,CORE,REFILL,LONG,CORE+'_s2',CORE+'_s3',CORE+'_s6',*MIXED):
        for ext in ('csv','vcd'):
            src = BUILD/'traces'/f'{name}.{ext}'
            dst = OUT/'traces'/src.name
            shutil.copyfile(src,dst)
            copied.append(dst)
        src = BUILD/f'{name}_run.log'
        assert '_PASS' in src.read_text(encoding='utf-8')
        dst = OUT/'logs'/src.name
        shutil.copyfile(src,dst)
        copied.append(dst)
    output_log=OUT/'logs/lpu_mxm_output_pipe_tb_run.log'
    shutil.copyfile(BUILD/'lpu_mxm_output_pipe_tb_run.log',output_log)
    assert 'MXM_OUTPUT_PIPE_PASS' in output_log.read_text(encoding='utf-8')
    copied.append(output_log)
    sources = [ROOT/f'sim/tb/mxm/{name}.sv' for name in ('lpu_mxm_control_tb',FRONT,'lpu_mxm_backend_tb',CORE,'lpu_mxm_output_pipe_tb')] + list((ROOT/'rtl/mxm').glob('*.sv'))
    sources += [ROOT/'scripts/plot_mxm_timing.py',ROOT/'scripts/test_mxm_supercell.py',ROOT/'sim/cmodel/generate_mxm_supercell_vectors.py',ROOT/'sim/filelist_mxm_supercell.f']
    report = dict(clock_period_ns=10, sample_after_edge_ns=2,
                  control_E0_sample_ns=control_origin, frontend_E0_sample_ns=front_origin,
                  core_E0_sample_ns=core_origin,refill_E0_sample_ns=refill_origin,
                  core_schedule=core_summary,refill_schedule=refill_summary,
                  main_core_trace=REFILL,long_batch_core_schedule=long_summary,long_batch_E0_sample_ns=long_origin,
                  mixed_format_core_schedules=mixed_summaries,
                  backend_output_latency=6,partial_available_to_output_cycles=4,backend_checked_formatted_outputs=checked_formatted_outputs,
                  output_conversion_input_patterns=331776,output_conversion_lane_checks=1990656,
                  core_negative_tests=negative_tests,
                  compute_updates=compute_events, load_updates=load_events,
                  first_result_cycles=first_results, backend_writeback_pairs=writeback_pairs,
                  observed_operand_pairs=observed_operands,command_to_read_cycles=read_request_delays,command_to_store_write_cycles=store_write_delays,
                  core_partial_fp32=4096,core_output_fp32=2048,
                  valid_result_batches=416, testbench_checked_FP32_results=3328,
                  scope='Observed public ports only; legal traffic windows. Logical SRAM, FP32 core and equal-latency optional BF16 output implemented; physical macro timing and final stream packing/routing not implemented.',
                  sha256={str(f.relative_to(ROOT)):digest(f) for f in sources+copied})
    (OUT/'measurements.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    titles = [('00-core-schedule','连续更换权重：三条指令流'),('07-core-refill','连续更换权重：逐单元实际读写'),('10-core-count40','40批activation：计算仍无空拍'),('09-core-prefetch','完整核心：倒推预读与A/B会合'),('06-core-inputs','完整核心：先加载再计算'),('05-core','完整核心：连续输出'),('08-output-formats','完整核心：FP32/BF16等延迟'),
              ('01-compute','附录：前端计算队列单测'),('02-load-relay','附录：前端权重队列单测'),('03-array-startup','附录：前端阵列单测'),('04-backend','附录：后端单测')]
    links=' '.join(f'<a href="#{stem}">{title}</a>' for stem,title in titles)
    sections='\n'.join(f'<section id="{stem}"><h2>{title}</h2><a href="figures/{stem}.svg" target="_blank">打开矢量图 / 放大查看</a><div class="wave">{(OUT/"figures"/(stem+".svg")).read_text(encoding="utf-8")}</div></section>' for stem,title in titles)
    table_rows=''.join(f'<tr><td>SL{r}</td><td>{", ".join(str(c) for c,_ in compute_events[r])}</td><td>{", ".join(str(c-load_origin) for c,_ in load_events[r][1:])}</td></tr>' for r in range(4))
    page=f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>MXM 实测时序</title>
<style>body{{font:16px "Microsoft YaHei",Arial,sans-serif;margin:28px;color:#10233f;background:#f4f7fa}}main{{max-width:1600px;margin:auto}}h1{{font-size:28px}}nav a,a{{color:#2864b4;margin-right:20px}}section{{background:white;margin:24px 0;padding:20px;border-radius:10px}}.wave{{overflow:auto}}svg{{width:100%;min-width:1200px;height:auto}}table{{border-collapse:collapse;background:white}}td,th{{padding:10px 20px;border:1px solid #d5dee8}}p{{line-height:1.8}}code{{font-family:Consolas,monospace}}</style>
<main><h1>MXM 公开端口实测时序</h1><p>主报告使用一次完整核心仿真的统一时间轴：E0 为首条前端权重加载的发射沿。前端权重加载、前端计算、后端累加是三个独立队列；入队发生在启动前，图中 launch 才是执行发射。图线由实际 CSV 生成，未使用期望数组。时钟周期 10 ns，输出在沿后 2 ns 采样；输入接收与 Bank 请求在同一沿之前采样，表示该沿实际消费的内容。</p><nav>{links}</nav>
<section><h2>完整核心：同一次测试的实际发射</h2><table><tr><th>指令流</th><th>发射周期</th><th>含义</th></tr>
<tr><td>前端权重加载</td><td>E0 / E32 / E64 / E96</td><td>四套不同权重依次加载到 B0 / B1 / B0 / B1，每套32拍</td></tr>
<tr><td>前端计算</td><td>E32 / E64 / E96 / E128</td><td>每条32批，依次使用 B0 / B1 / B0 / B1</td></tr>
<tr><td>后端累加与存储</td><td>E51 / E67 / E83 / E115 / E147</td><td>STORE16 / STORE16 / ACC_STORE32 / ACC_OUT32 / DIRECT_OUT32</td></tr></table>
<p>主报告使用四套不同权重的连续重载仿真（{REFILL}），不是复用旧权重。权重跨Supercell的旧尾部、valid和buffer ID一起寄存，每跨一级晚一拍，与activation一致。左端B0最后在E64用于旧计算，E65立即开始重载；右侧SC1/2/3分别在E65/66/67最后使用旧B0、E66/67/68开始重载。新B0在各单元于E96/97/98/99写完，下一拍E97/98/99/100进入新计算，无空拍。四层activation分别从E33/36/39/42连续接收128批；四列部分和从E53/54/55/56连续输出128批。</p>
<p>32拍是左端输入32组权重的持续时间，最右端完成还会晚3拍；对应activation到右端也晚3拍，因此无需等待整行全部加载完才启动左端计算。COLUMN包同样按每列一拍传递，MATRIX尾部不会因下一条COLUMN命令而丢弃；独立前端测试覆盖MATRIX→COLUMN紧邻交接。所有后端命令比阵列结果提前2拍启动，A/B直接进入A1，没有宽数据等待级。</p>
<p>以E86的A/B会合采样沿倒推：E83发射ACC_STORE，E84预读地址0，E85新A/旧B准备好，E86/A1、E87/A2、E88/A3，E89原位写回。指令到输出6拍，新部分和可用到输出4拍，比旧实现少3拍。STORE复用既有三拍旁路，与ACC_STORE保持同一写入相位；读固定launch+1、写固定launch+6，读写间隔仍5拍。首次读/写不再刻意凑成相同指令延迟。</p>
<p>额外40批activation测试同样连续更换四套权重：计算E32/72/112/152，权重加载E0/32/72/112，每次仍只加载32拍。权重入口有空闲周期，160批activation及160批阵列结果均连续，证明加载空闲不需要变成计算空拍。五组合法完整核心场景全部通过：四组COUNT32各4096个部分和、2048个最终结果，一组COUNT40为5120/2560；包含连续重载、两种输出格式及每个单元的实际本地读写沿。</p>
<p>三个负例仍保留：首次计算提前一拍在E32报错、故意在连续计算中插入3拍且不调整Bank调度在E119报冲突、后端晚发一拍在E54报错。正常32批连续计算没有这3拍，也不需要额外Bank相位空拍。输出级既有独立测试覆盖331776种输入、1990656个lane结果。物理宏时序、最终stream打包与输出位置尚未实现/验证。</p></section>
<section><h2>附录的验证范围与时间轴</h2><p>图01/02的控制器单测只验证队列传播，没有权重数据通路，不能作为合法数据调度示例。这两图来自同一次控制单测并共用时间原点；图03前端阵列单测、图04后端单测各有明确标注的局部时间轴，不能与主报告拼接。</p><table><tr><th>Superlane</th><th>单测计算 C0 / C1 / C2</th><th>单测单列权重 A / B / C / D</th></tr>{table_rows}</table><p>相邻层更新间隔实测3拍。独立后端全部16种操作交接均通过，512次原位写回均为读请求后5拍；1024对A/B操作数逐一核对。额外17条COUNT=1输出指令逐拍发射，覆盖四种操作/格式状态的全部16种相邻交接，默认4列共68批结果，均无空拍。</p></section>
{sections}<section><h2>可核对的原始数据</h2><p><a href="measurements.json">测量结果及 SHA256</a><a href="traces/{REFILL}.csv">主报告：32批连续换权重 CSV</a><a href="traces/{REFILL}.vcd">主报告 VCD</a><a href="traces/{LONG}.csv">40批连续换权重 CSV</a><a href="traces/{LONG}.vcd">40批 VCD</a><a href="traces/{CORE}.csv">对照：复用两套权重 CSV</a><a href="traces/{CONTROL}.csv">控制器单测 CSV</a><a href="traces/{BACKEND}.csv">后端单测 CSV</a></p><p>VCD 可在 GTKWave 等查看器中打开。负例的 CSV/VCD 和 PASS 日志也保存在 traces/ 与 logs/；负例的 PASS 表示预期故障确实发生，不代表调度合法。</p><p>重新生成：<code>python scripts/plot_mxm_timing.py --simulate</code></p></section></main></html>'''
    (OUT/'index.html').write_text(page,encoding='utf-8')
    print(json.dumps(dict(output=str(OUT),compute_updates=[[c for c,_ in row] for row in compute_events],
                          load_updates=[[c-load_origin for c,_ in row[1:]] for row in load_events],
                          first_results=first_results,backend_writeback_pairs=len(writeback_pairs),observed_operands=observed_operands),ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
