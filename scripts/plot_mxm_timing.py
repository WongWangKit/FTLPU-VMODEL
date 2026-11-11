"""Render count-free MXM public-port traces and verify measured timing.

Use --simulate to regenerate all instruction/array/backend test evidence.
Batch lengths in this report are compiler stimulus, never instruction fields.
"""
import argparse
import csv
import hashlib
import html
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'build/mxm_supercell'
OUT=ROOT/'output/instruction_supercell_array_test_results'
COLORS=['#2864B4','#147C69','#AA6B15','#8056A5','#B54248']
OPERATIONS=['DIRECT_OUT','STORE','ACC_STORE','ACC_OUT']
CORE='lpu_mxm_core_tb'
CONTROL='lpu_mxm_control_tb_k4_n3'
FRONT='lpu_mxm_frontend_tb'
BACKEND='lpu_mxm_backend_tb_k4_n8'

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def read_trace(name,axis,anchor):
    with (BUILD/'traces'/f'{name}.csv').open(encoding='utf-8',newline='') as f:
        rows=[d for d in csv.DictReader(f) if d['reset_n']=='1' and d['run']=='1' and d.get('scoring','1')=='1']
    origin=min(float(d['sample_ns']) for d in rows if d[axis]=='0' and d[anchor]=='1')
    records=[{} for _ in range(max(int(d[axis]) for d in rows)+1)]
    for d in rows: records[int(d[axis])][round((float(d['sample_ns'])-origin)/10)]=d
    return records,origin

def bit(d,key): return d.get(key)=='1'
def fp32(value): return int.from_bytes(struct.pack('>f',float(value)),'big')
def bus(key,valid,color=0):
    return lambda d:(d[key],COLORS[color]) if bit(d,valid) else ('—','#8995A5')
def opbus(key,valid):
    return lambda d:(OPERATIONS[int(d[key])],COLORS[int(d[key])]) if bit(d,valid) else ('—','#8995A5')

def verify_core(records,batch,refill=True):
    launch=[t for t,d in records[0].items() if bit(d,'compute_launch')]
    backend=[t for t,d in records[0].items() if bit(d,'backend_launch')]
    assert len(launch)==len(backend)==4*batch
    assert launch==list(range(34,34+4*batch))
    assert backend==list(range(57,57+4*batch))
    summary=dict(batch_size=batch,compute_beats=len(launch),backend_beats=len(backend),
                 first_partial=[],first_return=[],first_output=[],compute_boundary_gaps=[0,0,0],
                 compute_group_starts=[launch[i*batch] for i in range(4)],
                 backend_operation_starts=[57,57+batch,57+2*batch,57+3*batch])
    for c,data in enumerate(records):
        assert not any(bit(d,'fault') for d in data.values())
        expected_top={s+21+c:i for i,s in enumerate(launch)}
        observed_top={t:int(d['partial_tag']) for t,d in data.items() if bit(d,'partial_valid')}
        observed_left={t:int(d['returned_tag']) for t,d in data.items() if bit(d,'returned_valid')}
        assert observed_top==expected_top
        assert observed_left=={t+4:tag for t,tag in expected_top.items()}
        summary['first_partial'].append(min(observed_top));summary['first_return'].append(min(observed_left))
        outputs={}
        for t,d in data.items():
            assert bit(d,'compute_row_valid')==(t-3*c in launch)
            assert bit(d,'activation_accepted')==(t-1-3*c in launch)
            assert bit(d,'issue_valid')==(t-c in backend)
            if bit(d,'partial_valid'):
                tag=int(d['partial_tag']);factor=tag//batch+1 if refill else tag//batch%2+1
                assert int(d['partial_lane0'],16)==fp32(8*(4*((tag%batch)%3)+10)*(c*8+1)*factor)
                assert d['partial_lane0']==data[t+4]['returned_lane0']
            if bit(d,'issue_valid'):
                beat=t-c-57;op=1 if beat<batch else (2 if beat<2*batch else (3 if beat<3*batch else 0))
                addr=beat%batch
                assert int(d['issue_operation'])==op and int(d['issue_address'])==addr
                slot=data[t+2];capture=data[t+3];done=data[t+6]
                assert bit(slot,'backend_slot_valid') and int(slot['backend_address'])==addr
                assert bit(capture,'partial_accepted') and int(capture['accepted_partial_tag'])==beat
                assert bit(capture,'alu_valid')==(op>=2)
                if op>=2:
                    assert capture['operand_a0']==capture['accepted_partial_lane0']
                    read=data[t+1];b=addr%2
                    assert bit(read,f'bank{b}_valid') and not bit(read,f'bank{b}_write')
                    assert int(read[f'bank{b}_address'])==addr//2
                if op in (1,2):
                    b=addr%2
                    assert bit(done,f'bank{b}_valid') and bit(done,f'bank{b}_write')
                    assert int(done[f'bank{b}_address'])==addr//2
                else:
                    assert bit(done,'result_valid') and int(done['result_tag'])==beat and int(done['result_address'])==addr
                    factor=(6 if refill else 4) if op==3 else (4 if refill else 2)
                    value=fp32(8*(4*((beat%batch)%3)+10)*(c*8+1)*factor)
                    if bit(done,'result_bf16'): value=(value+0x7fff+((value>>16)&1))>>16
                    assert int(done['result_lane0'],16)==value
                    outputs[t+6]=beat
        assert {t:int(d['result_tag']) for t,d in data.items() if bit(d,'result_valid')}==outputs
        summary['first_output'].append(min(outputs))
    return summary

def verify_dequant_trace():
    name='lpu_mxm_weight_dequant_tb_trace'
    with (BUILD/'traces'/f'{name}.csv').open(encoding='utf-8',newline='') as f:
        rows=list(csv.DictReader(f))
    origin=min(float(d['sample_ns']) for d in rows if bit(d,'param_accepted'))
    lanes=max(int(d['lane']) for d in rows)+1
    records=[{} for _ in range(lanes)]
    for d in rows: records[int(d['lane'])][round((float(d['sample_ns'])-origin)/10)]=d
    spec=importlib.util.spec_from_file_location('dequant_oracle',ROOT/'sim/cmodel/generate_mxm_dequant_vectors.py')
    oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
    checked=0;overwrites=0
    for data in records:
        parameters={};due={};mid={}
        for t,d in data.items():
            assert not bit(d,'fault')
            assert bit(d,'accepted')==bit(d,'request')
            assert bit(d,'param_accepted')==bit(d,'param_write')
            if bit(d,'accepted'):
                bank=int(d['param_read_buffer']);zero,scale=parameters[bank]
                value=oracle.dequantize(int(d['q'],16),zero,scale)
                due[t+2]=(value,int(d['weight_buffer']));mid[t+1]=due[t+2]
            if bit(d,'param_accepted'):
                bank=int(d['param_write_buffer'])
                if bit(d,'accepted'): assert bank!=int(d['param_read_buffer'])
                # The previous D1 has already captured this buffer: overwriting
                # it must not change the current D2 or following D3 result.
                previous=data.get(t-1)
                if previous and bit(previous,'accepted') and bank==int(previous['param_read_buffer']): overwrites+=1
                parameters[bank]=(int(d['loaded_zero'],16),int(d['loaded_scale'],16))
            assert bit(d,'d2_valid')==(t in mid)
            if t in mid: assert (int(d['d2_bf16'],16),int(d['d2_buffer']))==mid[t]
            assert bit(d,'d3_valid')==(t in due)
            if t in due:
                assert (int(d['d3_bf16'],16),int(d['d3_buffer']))==due[t]
                checked+=1
    assert checked>0 and overwrites>0
    return records,dict(lanes=lanes,checked_d3=checked,overwrites_during_D2=overwrites,write_stages=3,II=1)


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
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulate',action='store_true')
    args=parser.parse_args()
    if args.simulate:
        names=['lpu_mxm_dequant_control_tb','lpu_mxm_weight_dequant_tb','lpu_mxm_output_pipe_tb','lpu_mxm_control_tb','lpu_mxm_compact_isa_tb',FRONT,
               'lpu_mxm_weight_shift_tb','lpu_mxm_backend_tb','lpu_mxm_backend_config_tb',
               'lpu_mxm_result_return_tb',CORE]
        subprocess.run([sys.executable,str(ROOT/'scripts/test_mxm_supercell.py'),'--top',','.join(names),'--trace'],cwd=ROOT,check=True)
    for sub in ('figures','traces','logs'): (OUT/sub).mkdir(parents=True,exist_ok=True)
    core,origin=read_trace(CORE+'_s1','column','load_launch')
    reuse,_=read_trace(CORE,'column','load_launch')
    longer,_=read_trace(CORE+'_s7','column','load_launch')
    even,_=read_trace(CORE+'_s10','column','load_launch')
    mixed=[read_trace(CORE+f'_s{s}','column','load_launch')[0] for s in (4,5)]
    dequant,dequant_summary=verify_dequant_trace()
    main_summary=verify_core(core,32)
    reuse_summary=verify_core(reuse,32,False)
    long_summary=verify_core(longer,40)
    even_summary=verify_core(even,34)
    for data in mixed: verify_core(data,32)
    control,_=read_trace(CONTROL,'row','compute_launch')
    front,_=read_trace(FRONT,'column','compute_launch')
    backend,_=read_trace(BACKEND,'column','launch')
    for r,data in enumerate(control):
        assert [t for t,d in data.items() if bit(d,'compute_update')]==[t+3*r for t,d in control[0].items() if bit(d,'compute_update')]
        assert [t for t,d in data.items() if bit(d,'load_update')]==[t+3*r for t,d in control[0].items() if bit(d,'load_update')]
    figures=[]
    def save(p,stem,title): p.save(stem);figures.append((stem,title))
    def schedule(data,stem,title,batch):
        p=Diagram(title,'每拍launch是独立操作；连续高电平表示每拍发射，组长仅为编译器刺激。',0,57+4*batch+20,12,tick=16)
        for row,(key,label) in enumerate((('load_launch','权重模式指令发射'),('compute_launch','计算逐拍发射'),('backend_launch','后端逐拍发射'))): p.binary(row,label,data[0],key,COLORS[row])
        p.bus(3,'SL0计算Buffer',data[0],bus('compute_row_buffer','compute_row_valid'))
        p.bus(4,'SL0后端操作',data[0],opbus('issue_operation','issue_valid'))
        p.binary(5,'顶部列0有效',data[0],'partial_valid')
        p.binary(6,'左端SL0有效',data[0],'returned_valid',COLORS[1])
        for b in range(2):
            p.bus(7+b,f'Bank{b}实际服务',data[0],lambda d,b=b:('W' if bit(d,f'bank{b}_write') else 'R',COLORS[b]) if bit(d,f'bank{b}_valid') else ('—','#8995A5'))
        p.binary(9,'SL0输出有效',data[0],'result_valid',COLORS[2])
        p.bus(10,'SL0输出格式',data[0],lambda d:('BF16' if bit(d,'result_bf16') else 'FP32',COLORS[1]) if bit(d,'result_valid') else ('—','#8995A5'))
        p.bus(11,'SL0输出操作',data[0],lambda d:('ACC_OUT' if int(d['result_tag'])<3*batch else 'DIRECT_OUT',COLORS[2]) if bit(d,'result_valid') else ('—','#8995A5'))
        save(p,stem,title)
    schedule(core,'00-core-schedule','完整MXM：权重、计算与后端控制流',32)
    p=Diagram('计算指令：两个中继寄存器加接收端本地寄存器','控制器单测；同一指令字可连续32拍，每拍valid和独立tag均保留。',0,16,8)
    for r,data in enumerate(control):
        p.binary(2*r,f'SL{r}有效/更新',data,'compute_update',COLORS[r%4])
        p.bus(2*r+1,f'SL{r}事务tag',data,bus('compute_tag','compute_valid',r%4))
    save(p,'01-compute','计算指令3拍传播与II=1')
    p=Diagram('COLUMN每拍发射，MATRIX仍保持固定长度','同一次控制单测：E64/65/66为单列，E67开始下一条MATRIX；每层晚3拍。',60,84,8)
    for r,data in enumerate(control):
        p.binary(2*r,f'SL{r}加载更新',data,'load_update',COLORS[r%4])
        p.bus(2*r+1,f'SL{r}加载字',data,bus('load_instruction','load_valid',r%4))
    save(p,'02-load-relay','权重加载固定模式与满速传播')
    p=Diagram('前端阵列独立测试：7位指令及在途元数据','局部E0为第一拍计算发射；104批跨Buffer、stream和32/40/32批分组。',0,115,8,tick=8)
    for c,data in enumerate(front):
        p.binary(2*c,f'列{c}结果有效',data,'result_valid',COLORS[c])
        p.bus(2*c+1,f'列{c}结果指令字',data,bus('result_instruction','result_valid',c))
    save(p,'03-array-startup','前端阵列与指令元数据')
    p=Diagram('后端：编译器逐拍给实际地址','独立后端单测，局部E0为首拍STORE发射；图示STORE→ACC_STORE边界。',90,108,8)
    d=backend[0]
    p.binary(0,'逐拍发射',d,'launch');p.bus(1,'实际issue地址',d,bus('issue_address','issue_valid'))
    p.bus(2,'操作',d,opbus('issue_operation','issue_valid'))
    for b in range(2): p.bus(3+b,f'Bank{b}服务',d,lambda x,b=b:('W' if bit(x,f'bank{b}_write') else 'R',COLORS[b]) if bit(x,f'bank{b}_valid') else ('—','#8995A5'))
    p.binary(5,'A1采样',d,'alu_valid');p.bus(6,'操作数A',d,bus('operand_a0','alu_valid'));p.bus(7,'操作数B',d,bus('operand_b0','alu_valid',1))
    save(p,'04-backend','后端明确地址与Bank交织')
    p=Diagram('完整MXM：ACC_OUT→DIRECT_OUT输出交接','同主图E0；无COUNT，操作切换后的输出仍逐拍连续。',149,164,8)
    for r,d in enumerate(core):
        p.binary(2*r,f'SL{r}输出有效',d,'result_valid',COLORS[r])
        p.bus(2*r+1,f'SL{r}输出tag',d,bus('result_tag','result_valid',r))
    save(p,'05-core','输出操作交接')
    p=Diagram('先加载权重，再连续接受activation','同主图E0；采样信号表示本沿实际消费的数据。',28,46,8)
    for r,d in enumerate(core):
        p.binary(2*r,f'SL{r}activation采样',d,'activation_accepted',COLORS[r])
        p.bus(2*r+1,f'SL{r}权重移位索引',d,bus('weight_index','weight_accepted',r))
    save(p,'06-core-inputs','实际输入采样沿')
    p=Diagram('逐Supercell检查换权重与activation相位','同主图E0；图示底层4个单元的真实公开接口，不增加全行保护空拍。',61,74,8)
    for c,d in enumerate(core):
        p.bus(2*c,f'SC{c}实际activation',d,bus('cell_activation_buffer','cell_activation_accepted'))
        p.bus(2*c+1,f'SC{c}实际权重写入',d,bus('cell_weight_buffer','cell_weight_accepted',1))
    save(p,'07-core-refill','实际单元的权重交接')
    p=Diagram('FP32与BF16共用输出延迟','上下来自两次独立核心仿真，均以首次权重发射为E0；输出格式切换无空拍。',149,164,8)
    for s,data in enumerate(mixed):
        for r,d in enumerate(data): p.bus(s*4+r,f'场景{s+4} SL{r}格式',d,lambda x:('BF16' if bit(x,'result_bf16') else 'FP32',COLORS[1]) if bit(x,'result_valid') else ('—','#8995A5'))
    save(p,'08-output-formats','输出格式切换')
    p=Diagram('倒推预读：新部分和与SRAM B直接在A1会合','同主图E0；E89发射，E90读，E91沿后A/B可用，E92/A1，E95原位写回。',85,98,8)
    d=core[0]
    p.bus(0,'逐拍issue地址',d,bus('issue_address','issue_valid'))
    p.bus(1,'操作',d,opbus('issue_operation','issue_valid'))
    p.bus(2,'回传部分和tag',d,bus('returned_tag','returned_valid',1))
    p.binary(3,'A1采样',d,'alu_valid');p.bus(4,'A1地址',d,bus('alu_address','alu_valid'))
    p.bus(5,'A1操作数A',d,bus('operand_a0','alu_valid'));p.bus(6,'A1操作数B',d,bus('operand_b0','alu_valid',1))
    p.binary(7,'Bank0请求',d,'bank0_valid')
    save(p,'09-core-prefetch','预读与直接A1采样')
    schedule(longer,'10-core-count40','40批编译器分组：无COUNT也可连续换权重',40)
    p=Diagram('顶部结果向下/向左回传，三拍计算相位变为一拍结果相位','同主图E0；各路径固定4拍，后端控制每行晚1拍。',50,68,12)
    for r,d in enumerate(core):
        p.bus(3*r,f'顶部列{r} tag',d,bus('partial_tag','partial_valid'))
        p.bus(3*r+1,f'左端SL{r} tag',d,bus('returned_tag','returned_valid',1))
        p.bus(3*r+2,f'SL{r}后端地址',d,bus('issue_address','issue_valid',2))
    save(p,'11-result-return','结果回传与后端相位')
    p=Diagram('反量化：D1锁存配对参数，D2期间可覆盖原参数Buffer',
              '独立单测；E0为首次参数写入，图示scale切换及空拍；D3与独立有理数模型核对。',29,41,11)
    d=dequant[0]
    p.binary(0,'参数加载接受',d,'param_accepted')
    p.bus(1,'参数写Buffer',d,bus('param_write_buffer','param_accepted'))
    p.bus(2,'新加载scale',d,bus('loaded_scale','param_accepted'))
    p.bus(3,'新加载zero',d,bus('loaded_zero','param_accepted'))
    p.binary(4,'D1权重接受',d,'accepted',COLORS[1])
    p.bus(5,'D1参数Buffer',d,bus('param_read_buffer','accepted',1))
    p.bus(6,'D1输入q',d,bus('q','accepted',1))
    p.binary(7,'D2后组合有效',d,'d2_valid',COLORS[2])
    p.bus(8,'D2后组合BF16',d,bus('d2_bf16','d2_valid',2))
    p.bus(9,'D3实际接收BF16',d,bus('d3_bf16','d3_valid',3))
    p.bus(10,'D3权重Buffer',d,bus('d3_buffer','d3_valid',3))
    save(p,'12-dequant-parameters','反量化参数预取与D1锁存')
    names=['lpu_mxm_weight_dequant_tb_trace',CONTROL,FRONT,BACKEND,CORE,*[CORE+f'_s{s}' for s in (1,2,3,4,5,6,7,9,10)]]
    copied=[]
    for name in names:
        for ext in ('csv','vcd'):
            src=BUILD/'traces'/f'{name}.{ext}';dst=OUT/'traces'/src.name
            shutil.copyfile(src,dst);copied.append(dst)
    logs=[BUILD/f'{name}_run.log' for name in names]
    logs += sorted(BUILD.glob('lpu_mxm_weight_dequant_tb_k*_run.log'))
    logs += sorted(BUILD.glob('lpu_mxm_dequant_control_tb_k*_run.log'))
    logs += [BUILD/f'{name}_run.log' for name in ('lpu_mxm_compact_isa_tb','lpu_mxm_weight_shift_tb','lpu_mxm_weight_shift_tb_i1',CORE+'_s8','lpu_mxm_output_pipe_tb')]
    logs += sorted(BUILD.glob('lpu_mxm_backend_config_tb_d*_run.log'))
    logs += sorted(BUILD.glob('lpu_mxm_result_return*_run.log'))
    for src in logs:
        content=src.read_text(encoding='utf-8')
        assert '_PASS' in content or 'requires a positive square array' in content,src
        dst=OUT/'logs'/src.name;shutil.copyfile(src,dst);copied.append(dst)
    assert 'count_free=1' in (BUILD/f'{CORE}_s8_run.log').read_text(encoding='utf-8')
    negatives=[]
    for s,expected in ((2,34),(3,125),(6,60),(9,91)):
        records,_=read_trace(CORE+f'_s{s}','column','load_launch')
        edge=min(t for d in records for t,x in d.items() if bit(x,'fault'))
        assert edge==expected;negatives.append(dict(scenario=s,fault_cycle=edge))
    source_paths=list((ROOT/'rtl/mxm').glob('*.sv'))+list((ROOT/'sim/tb/mxm').glob('*.sv'))
    source_paths += [ROOT/'scripts/plot_mxm_timing.py',ROOT/'scripts/test_mxm_supercell.py',ROOT/'sim/cmodel/generate_mxm_supercell_vectors.py',ROOT/'sim/cmodel/generate_mxm_dequant_vectors.py',ROOT/'sim/filelist_mxm_supercell.f']
    source_paths += [ROOT/'docs'/f'{name}.md' for name in ('mxm_instructions','mxm_scheduling_contract','mxm_accumulator','mxm_weight_ingress','architecture')]
    report=dict(isa_revision='paired-parameter-buffers-2026-11-10',clock_period_ns=10,sample_after_edge_ns=2,main_core_trace=CORE+'_s1',
                core_E0_sample_ns=origin,core_schedule=main_summary,reuse_schedule=reuse_summary,
                long_batch_core_schedule=long_summary,even34_core_schedule=even_summary,core_negative_tests=negatives,
                instruction_bits=dict(compute=7,load=2,param_load=1,dequant=1,backend_default=13),queue_depth=16,queue_payload_bits=384,
                dequant_trace=dequant_summary,dequant_vectors_per_configuration=524288,dequant_configurations=4,
                compiler_contract=dict(minimum_compute_batches=32,continuous_in_place_even_pass=True,automatic_group_checks=False),
                frontend_relay_cycles=3,frontend_relay_extra_registers=2,backend_relay_cycles=1,
                backend_output_latency=6,return_pipeline_cycles=4,returned_available_to_output_cycles=4,
                partial_available_to_output_cycles=8,read_to_write_cycles=5,
                frontend_encoding_patterns=136,compute_beat_checks=66048,compute_row_checks=264192,
                backend_encoding_patterns=dict(depth2=16,depth6=64,depth1000=8192,depth1024=8192,depth2048=16384,depth65536=524288),
                maximum_group_core_partial_fp32=131072,maximum_group_core_outputs=65536,
                sha256={str(f.relative_to(ROOT)):digest(f) for f in source_paths+copied})
    (OUT/'measurements.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    links=' '.join(f'<a href="#{stem}">{html.escape(title)}</a>' for stem,title in figures)
    sections=''.join(f'<section id="{stem}"><h2>{html.escape(title)}</h2><a href="figures/{stem}.svg">打开SVG</a><div class="wave">{(OUT/"figures"/f"{stem}.svg").read_text(encoding="utf-8")}</div></section>' for stem,title in figures)
    page=f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>MXM 无COUNT指令实测时序</title>
<style>body{{font:16px "Microsoft YaHei",Arial,sans-serif;margin:28px;color:#10233f;background:#f4f7fa}}main{{max-width:1600px;margin:auto}}p{{line-height:1.8}}section{{background:white;margin:24px 0;padding:20px;border-radius:10px}}.wave{{overflow:auto}}svg{{width:100%;min-width:1200px;height:auto}}a{{color:#2864b4;margin-right:16px}}</style>
<main><h1>MXM 无COUNT指令：公开端口实测时序</h1>
<section><p>计算7位、权重加载2位、参数加载1位、反量化执行1位、后端默认13位。计算和后端每次有效launch对应一拍，连续高电平表示每拍新发射；相同字也独立传递。COUNT字段、重复执行计数、指令内索引和后端base+index地址生成已删除。前端每层用两个中继加本地寄存器延迟3拍，后端延迟1拍。权重MATRIX固定32拍/COLUMN固定1拍的模式控制保留。</p>
<p>最少32批连续计算、换权重带宽、偶数完整地址轮转以及边界相位由编译器保证，硬件不恢复组长计数器；实际Bank冲突和地址依赖检测保留。33批连续原位累加负例在E91报冲突，34批合法轮转通过。真实编译器的自动填充与丢填充输出尚未接入。</p>
<p>主图统一E0为首次权重加载。参数预取E−1/31/63/95，权重E0/32/64/96，每个权重输入拍配一条反量化选择指令。计算逐拍E34～161，后端逐拍E57～184。顶部首批E55/56/57/58，左端E59/60/61/62，首批输出E127/128/129/130。四种后端操作维持发射后6拍完成、读到写D=5。输入和Bank服务在沿前采样，输出状态在沿后2ns记录。</p>
<p>已检查前端各队列合计136种编码、66048拍和264192次逐行传播含标签回绕；六种存储深度全部后端编码；连续相同指令/空拍/固定权重模式/16种后端交接/两种输出格式。完整核心32/40/1024批均验证数值、回传、存储和实际单元采样；1024批场景保留PASS日志，未生成大体积波形。宏时序、物理布线和最终stream目的地尚未验证。</p>
<p><a href="measurements.json">测量与源码SHA256</a><a href="logs/lpu_mxm_core_tb_s8_run.log">1024批日志</a><a href="logs/lpu_mxm_core_tb_s9_run.log">33批冲突日志</a><a href="logs/lpu_mxm_core_tb_s10_run.log">34批通过日志</a><a href="traces/lpu_mxm_core_tb_s1.csv">主图CSV</a><a href="traces/lpu_mxm_core_tb_s1.vcd">主图VCD</a></p></section>
<section><p>scale/zero成对保存在参数双Buffer。参数仅在加载指令时消费；D1一次读出配对参数并锁存后续值。图12由独立单测CSV生成，D2期间覆盖旧参数Buffer，D3仍保持正确结果；四种配置各524288向量通过。参数/反量化队列验证1/2/4行和深度1/3，前端六类非法调度均报预期故障。</p></section><nav>{links}</nav>{sections}<p>复现：python scripts/plot_mxm_timing.py --simulate。图01/02为独立控制单测，图03前端单测、图04后端单测各有自己的时间原点，不能与完整核心拼接。</p></main></html>'''
    (OUT/'index.html').write_text(page,encoding='utf-8')
    (OUT/'README.txt').write_text('MXM count-free ISA timing report (2026-11-10)\nOpen index.html. Compute/load/param-load/dequant/backend: 7/2/1/1/13 default bits.\nEach compute/backend launch is one beat. Groups are compiler stimulus, never encoded lengths.\nFrontend relay: 3 cycles, II=1 (two intermediate plus receiver local registers). Backend: 1 cycle.\nMATRIX/COLUMN fixed loading retained. Compiler minimum 32 and even continuous in-place pass contracts retained.\nBank detection retained; odd33 faults, even34 passes. SRAM read-to-write D=5; final output launch+6.\nCSV/VCD are actual public ports. Logs and source hashes in measurements.json.\nUnit plots have separate origins as labeled. Physical macro timing, final stream packing/destination and real compiler padding remain unverified.\nReproduce: python scripts/plot_mxm_timing.py --simulate\n',encoding='utf-8')
    print(json.dumps(dict(output=str(OUT),instruction_bits=report['instruction_bits'],schedule=main_summary,odd33_fault=91,even34='PASS'),ensure_ascii=False,indent=2))


if __name__=='__main__': main()
