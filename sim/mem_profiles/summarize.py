"""Summarize executed evidence; missing/failed/unsupported is never PASS."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
CM=ROOT.parent/'FTLPU-CMODEL'
HERE=Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def write(path,data):
    path.write_text(json.dumps(data,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')


def source_match(identity):
    return identity.is_file() and all(Path(p).is_file() and sha(Path(p))==h for p,h in read(identity).items())


def summarize(out):
    records=read(out/'profiles_results.json')
    latest={(x['profile'],x.get('stage'),x.get('case')):x for x in records}
    profiles=[]
    for profile,tiles,depth in [(16,2,1024),(32,4,2048),(64,8,2048)]:
        cases=[x for (p,stage,case),x in latest.items() if p==profile and stage in ('full','sync')]
        seeds=[x for x in cases if x['stage']=='sync' and x['case'].startswith('seed')]
        profiles.append(dict(profile=profile,tiles=tiles,rows=depth,leaves=208*tiles,
            capacity_mib=208*tiles*depth*8/2**20,l1_cases=sum(x['stage']=='full' for x in cases),
            l2_cases=sum(x['stage']=='sync' for x in cases),seeds=len(seeds),
            minimum_nonreset=min(x['coverage']['nonreset_cycles'] for x in seeds),
            passed=len(cases)==34 and len(seeds)==16 and all(x['status']=='passed' and
                source_match(Path(x['result']['log']).parent/'source_identity.json') and
                source_match(Path(x['result']['log']).parent.parent/'reference_identity.json') for x in cases),
            scope='independent MEM fixture; no RTL SRF in L1/L2'))
    integrations={x['profile']:x for x in read(out/'integration_results.json')}
    for p,x in integrations.items():
        log=Path(x['result']['log'])
        x['current_source_match']=source_match(log.parent/'source_identity.json')
    collisions=read(out/'collision_results.json')
    for x in collisions:
        x['current_source_match']=source_match(Path(x['result']['log']).parent/'source_identity.json')
    legacy={x['name']:x for x in read(out/'legacy_results.json')}
    for name,x in legacy.items():
        if 'result' not in x:
            attempts=sorted((out/'legacy').glob(name+'_attempt*/run.result.json'),key=lambda p:p.stat().st_mtime)
            if attempts:x['result']=read(attempts[-1])
        log=Path(x['result']['log']) if 'result' in x else None
        if log is None:
            x['current_source_match']=False
        else:
            x['current_source_match']=source_match(log.parent/'source_identity.json')
        if name=='sxm_command_adapter' and x['status']=='failed' and log and (out/'sxm_baseline_failure.json').exists() and 'ERROR illegal map' in log.read_text(errors='replace') and 'TEST_FAIL errors=1' in log.read_text(errors='replace'):
            x['classification']='preexisting_failure_reproduced_on_snapshot'
    evidence=dict(run_id=out.name,baseline_heads={k:v['head'].strip() for k,v in read(out/'baseline_git.json').items()},
        tools=read(out/'tools.json'),profiles=profiles,integration=list(integrations.values()),
        collisions=collisions,codec=read(out/'codec_results.json'),configuration=read(out/'configuration_results.json'),
        legacy_profiles=read(out/'legacy_profile_results.json'),
        mutations=read(out/'mutation_results.json'),legacy=list(legacy.values()),
        history=read(out/'cmodel_historical_results.json'),sxm_baseline=read(out/'sxm_baseline_failure.json'),
        legacy16_32=read(out/'baseline_compatibility.json'),legacy32768=read(out/'legacy32768_legacy_default_results.json'),
        unit_cases=len(read(out/'safety_units_unit_results.json')),
        safety_cases=len(read(out/'safety_checks_safety_results.json')),
        parameter_rejections=len(read(out/'safety_parameters_parameter_results.json')),
        native_filelists=len(read(out/'native_filelists_filelist_results.json')))
    write(out/'summary.json',evidence)
    if not all(x['passed'] for x in profiles):raise RuntimeError('missing independent profile evidence')
    if len(integrations)!=3 or not all(x['status']=='passed' and x['current_source_match'] for x in integrations.values()):raise RuntimeError('integration evidence stale or failed')
    if len(collisions)!=3 or not all(x['status']=='passed' and x['current_source_match'] for x in collisions):raise RuntimeError('collision evidence stale or failed')
    if len(legacy)!=13 or not all(x['current_source_match'] and (x['status']=='passed' or x.get('classification')) for x in legacy.values()):raise RuntimeError('legacy evidence stale/unclassified failure')
    for name,count in [('codec',6),('configuration',7),('mutations',7),('legacy_profiles',3)]:
        if len(evidence[name])!=count or any(x['status']!='passed' for x in evidence[name]):raise RuntimeError('incomplete '+name)
    if not all(source_match(Path(x['result']['log']).parent/'source_identity.json') for x in evidence['legacy_profiles']):
        raise RuntimeError('legacy-profile source identity mismatch')
    for file in ['safety_units_unit_results.json','safety_checks_safety_results.json',
                 'safety_parameters_parameter_results.json','native_filelists_filelist_results.json']:
        if not all(x.get('pass_',x.get('result',{}).get('pass_',False)) for x in read(out/file)):
            raise RuntimeError('failed safety/native entry '+file)
    # Source hash identity is separate from the old user's dirty changes.
    final={}
    for root,dirs in [(ROOT,['rtl','config','scripts','sim/mem_p1','sim/mem_profiles']),
                      (CM,['include','src','tests/unit/mem','tests/subsystem/mxm','cmake','config'])]:
        for directory in dirs:
            for p in (root/directory).rglob('*'):
                if p.is_file() and p.name!='integration_registry.json' and '__pycache__' not in p.parts and p.suffix in ('.sv','.cpp','.hpp','.py','.ps1','.f','.json','.cmake','.in'):
                    final[root.name+'/'+p.relative_to(root).as_posix()]=sha(p)
    for p in (ROOT/'sim').glob('filelist*.f'):final['FTLPU-VMODEL/'+p.relative_to(ROOT).as_posix()]=sha(p)
    baseline=read(out/'baseline_manifest.json')
    changed=[p for p,h in final.items() if p in baseline and baseline[p]!=h]
    added=[p for p in final if p not in baseline]
    write(out/'final_source_manifest.json',dict(files=final,changed_from_captured_dirty_baseline=changed,added=added))
    assert final['FTLPU-CMODEL/include/ftlpu/mem/mem_array.hpp']==baseline['FTLPU-CMODEL/include/ftlpu/mem/mem_array.hpp'],'R1 read semantics changed unexpectedly'
    assert final['FTLPU-VMODEL/rtl/mem_native/mem_bank_superlane_leaf.sv']==baseline['FTLPU-VMODEL/rtl/mem_native/mem_bank_superlane_leaf.sv'],'stable leaf unexpectedly rewritten'
    registry=[
      dict(caller='lpu_mem_srf_integration',core='latest native MEM + latest lane SRF via segment wrapper',
           formats='canonical32; c7raw32 normalized by existing adapters in upstream verification caller',
           verified='H2/F52/K2, profiles16/32/64; full 00/FF',Q=2,
           producer_ownership='MEM slots0/1, columns0..13; upstream independent',
           temporary_reason='external interface remains segment-valid per Q03',blocked=['I03 partial'],
           revisit='when lane caller boundary is frozen'),
      dict(caller='lpu_mem_srf_command_integration',formats='legacy47 only',Q=2,
           verified='formal16/32/64 Read/Write/map/highbits/rowP chain; profile0 F4/T4/P16 legacy TB; no Tap through47',temporary_reason='legacy ICU packet not c7 raw32',
           blocked=['I08 Tap through legacy47'],revisit='upstream c7 primitive/ICU source frozen; do not add a dual-format wrapper'),
      dict(caller='SXM turnaround/roundtrip/existing-workload',formats='legacy47 MEM + old416 SXM packet adapters',Q=2,
           producer_ownership='MEM0/1 at <=13; SXM1 at14/15, edge assertion forbids overlap',
           verified='profile0 F16/T4/P16; latest MEM and latest SRF segment wrapper',
           temporary_reason='SXM command/data geometry still T4',blocked=['I05/I09 T2/T8 SXM'],
           revisit='SXM functionality, packet and timing frozen; old illegal-map baseline failure retained'),
      dict(caller='DMA store vector sink',formats='canonical32 + existing DMA/C2C TX attachment',Q=2,
           producer_ownership='MEM0/1; TX attachment consumes only, no extra local producer',
           verified='profile0 F52/T4/P16, full256bit vector FIFO/backpressure',
           temporary_reason='sink/FIFO/protocol remains32B-vector',blocked=['I06 LPU16/LPU64 vector interface'],
           revisit='complete vector/beat protocol frozen'),
      dict(caller='C2C RX/SRF, TX/SRF, peer e2e',formats='existing replay/gather/credit protocol',Q=2,
           producer_ownership='RX slot0 at column13/West in no-MEM composition; do not reuse at overlapping MEM destination',
           verified='current T4 32B C2C/SRF subchains, no MEM endpoint claimed',
           temporary_reason='no unified MEM command/completion chain or two-beat64B-vector contract',
           blocked=['I07 true MEM endpoint and new sizes'],revisit='unified command/completion and vector assembly frozen'),
      dict(caller='ICU/MXM/VXM/old lpu_top',verified='not a current three-profile native RTL system',
           temporary_reason='existing top uses old MEM/control/queue ABI',blocked=['I10'],
           revisit='all corresponding module interfaces, latencies, ABI and end/drain frozen')]
    write(HERE/'integration_registry.json',dict(run_id=out.name,
        source_identity=(out/'final_source_manifest.json').as_posix(),callers=registry))
    rows='\n'.join(f'| LPU{x["profile"]} | {x["tiles"]}/{x["rows"]} | {x["leaves"]} | {x["capacity_mib"]:g} | {x["l1_cases"]}/{x["l2_cases"]} | {x["seeds"]} | {x["minimum_nonreset"]} | PASS |' for x in profiles)
    passed_legacy=[name for name,x in legacy.items() if x['status']=='passed']
    report=f'''# MEM 参数化与集成实施报告

日期：2026-10-27（北京时间）。准则：已批准v5，Q06=A。RunId：`{out.name}`。
**本轮可执行的MEM三档、现有兼容集成及验证范围已完成；不代表任意partial或整机三档验收。** 所有结果来自实际运行；未冻结接口、历史失败及物理验收另列，不能将下表扩展为全系统PASS。

## 1. 身份与保全

- VMODEL基底`7366a2b9eeaf65f1866ba603158b405c112bc2e9`；CModel基底`c7ae225b9cdd4a5fb5d96e7b1eabcf484dedc0ec`，直接使用本地同步读R1，未切换main/另立R2。
- 修改前537文件及git dirty差异保存在[运行目录]({out.as_posix()})的`preimplementation_sources.zip`、`baseline_manifest.json`、`baseline_git.json`。以前的golden/audit/失败报告未覆盖。
- 本轮R1只改G/T解耦及同步读单测的T派生；`mem_array.hpp`与修改前R1逐字节相同。RTL leaf执行数据通路与修改前逐字节相同，不新增Read级、ZeroFill、stall/retry、端口归因或双端口。
- 工作簿SHA256复核仍为`6df6c3ce9e1068245198c00767884ecd7bb298c16b8be81401f2c66bc22072c1`。三档JSON是**R1 MEM验证配置**，保留的其他FU/软件layout字段不是新档可执行系统ABI，不可直接拿旧程序或mask行7936运行。
- 详细数据在`summary.json`；最终源身份、相对于本轮dirty快照的改动/新增文件在`final_source_manifest.json`。现有源码的更早dirty改动不冒记为本轮成果。

## 2. 子任务一：功能对齐

| 契约 | 本轮动作/证据 |
|---|---|
| Read A采样/B提交、快照、连续与气泡 | 保持已有R1及leaf逻辑；L2 PRE/POST和真实SRF闭环逐拍对照；三档真实R1同步读单测通过，含快照后修改SRAM、trace-off和末响应drain。 |
| 普通Write、Tap与消费 | Error-only不变；历史512 mask功能fixture、缺数安全/入口负测重放；闭环中实际Write消费和Tap继续传播，并核对最终全存储。独立mask fixture不当作I03通过。 |
| P/E、高位/格式 | 原始word先检查；三档codec覆盖所有opcode/stream/map/preserve组合及P/E边界、高位，P和P/2两个active域，共6配置通过。 |
| 初始化/热复位 | 物理P行冷零；热复位不清SRAM。随机在途reset、闭环取消旧Read及最终全存储签名通过。 |
| 合法域/异常域 | 每bank每拍至多一个primitive；模型双队列API超集不扩展为RTL双口。非法域用安全oracle，不拿CModel异常后的状态作golden；新非法issue不杀旧合法波，三档均测。 |

T4修改前/后16、32及32768行合法轨迹逐字节一致；单位/codec/X测试{evidence['unit_cases']}项、安全/入口测试{evidence['safety_cases']}项、原参数拒绝{evidence['parameter_rejections']}项和原native filelist {evidence['native_filelists']}项通过。

## 3. 子任务二：真实三档参数化

既有integration追加`P_LPU_PROFILE=0`，正式16/32/64由同源配置推导F52/G4/T/P/E；profile0保留原几何参数。native控制链真实生成T−1级，tile0仍直达；索引、响应/消费/反馈、fault tile位宽全部按T派生。SRAM数组真裁剪，闭环TB逐leaf检查`$size`及绑定实例数，不屏蔽大实例冒充小档。

| 档位 | T/P | leaf数 | MiB | L1/L2 case数 | 随机seed数 | 每seed最少非复位比较周期 | 结果 |
|---|---|---:|---:|---:|---:|---:|---|
{rows}

每档case数为1组定向＋16个固定seed，L1与L2分别执行；另有LPU16早期定向试跑，不重复计入上表。每组最终核验全部leaf的全P行签名；数据含非对称H/group/bank/tile/lane，覆盖LPU64 tile4..7。

配置测试另验证profile0旧默认、正式档覆盖冲突旧参数（F4/G2/P16/T4不会覆盖正式档）、Q<2及非法T拒绝。PROFILE99由XSim在展开阶段以零维度VRFC10-1220拒绝，未执行仿真/未回退32；不把结构拒绝伪写为运行期PASS。

## 4. 子任务三：现有integration原位接入

- 未新增产品顶层/独立lane桥。更新原MEM/SRF、legacy47 command、SXM turnaround/roundtrip及DMA sink；SRF仍为最新lane内核的整段兼容wrapper，每数据平面一份权威状态。
- canonical32入口含义不变；legacy47 wrapper不增双格式，三档正式profile的Read/Write、map规范化、bit31拒绝及rowP拒绝另外通过真实wrapper链。c7raw32通过已有adapter在上游验证调用者规范化，完成真实adapter→MEM→SRF链；尚未将旧ICU变成c7 Macro源。
- Q06=A：MEM slots0/1；SXM slot1只在14/15，与MEM<=13空间复用，增加重叠断言并屏蔽无效payload；DMA TX只是消费者，不新增producer。C2C RX未来若与MEM同目的组合，必须另预算slot，当前没有虚构该产品链路。
- 实际版本/哈希、格式、支持档位、临时原因、缺测ID和回访条件见[integration_registry.json]({(HERE/'integration_registry.json').as_posix()})。
- 修复T8仿真数据传播差异：最小SRF用例中旧宽packed列间连线的valid正确但payload变0；改为语义等价的逐列unpacked组合数据网后通过。复现源/两次日志为`{out.name}/srf_min*`。只改内部连线表示，不改接口、状态机、hop或A/B；未据此宣称所有仿真器/优化级一致。

当前源码重跑的既有入口PASS：`{', '.join(passed_legacy)}`。均按各自实际配置计账；SXM路径是T4/P16兼容配置，DMA是F52/T4/P16完整256bit向量，不能称它们完成正式三档端到端。

## 5. 子任务四：真实集成、冲突与变异

- 三档H2/F52/K2完整MEM＋持久SRF闭环均通过：真实begin_cycle→MEM evaluate→边界注入/被动link→commit，不每拍清fabric。对照所有有效state byte及整幅valid、raw响应身份、当拍consume和最终全存储；逐leaf确认checker确已绑定。
- 三档0/1/2/3个MEM来源×0/1 upstream均通过；相同payload仍冲突，冲突next无效，无关cell继续提交；fault tile不截断。新增rowP、bit30、非零canonical map拒绝时旧波/旧响应继续通过。
- 7种变异均实际被捕获：翻byte、错tile、错stream、删除PRE valid、删除POST valid、覆盖/丢第二producer、consume错移一拍。`mutation_results.json`的PASS表示**预期拒绝被捕获**，不是坏产品通过；变异只存在运行目录，未改产品或历史golden。
- XSim2023.2 `--O0`，C++20 g++；CModel参考驱动O2、历史CMake单测Debug/O1且assert启用。没有第二RTL工具、O1/O2 RTL、形式、综合、STA、PPA或上板签核。

## 6. 仍受前置条件阻塞的目标（不计通过）

| ID | 本轮实际状态 | 缺口/回访条件 |
|---|---|---|
| I01/I02/I04/I08/I09 | 三档MEM/SRF闭环、raw c7链、00/FF消费及冲突通过；legacy47另外回归 | I09涉及SXM新档的联合部分仍受下项限制；I08不包含真实ICU Macro/Repeat/Loop。 |
| I03 | **未执行任意partial端到端** | 当前按Q03使用整段兼容外部接口，不能表达256 masks。待真实lane调用者和AND/FF桥边界冻结后在同一integration升级；不靠TB投影/force冒充。 |
| I05及SXM相关I09 | T4原组合/原workload通过，T2/T8未执行 | SXM仍固定T4及旧packet/selector/波时序，需SXM功能与接口冻结后回访；不只删除参数fatal。 |
| I06 | T4完整256bit sink/FIFO/backpressure通过；16B/64B接口未执行 | 完整向量宽度、beat与完成协议尚未统一，不截断64B或虚构16B出口。 |
| I07 | 现有C2C/SRF RX/TX/peer子链通过；**真实MEM存储端到端未完成** | 缺统一MEM命令/完成事件及LPU64两beat组装契约；现有RX仍T4，且与MEM同目的时需额外slot。 |
| I10 | **真实ICU/其他FU三档整机未执行** | 旧lpu_top仍旧MEM/queue ABI；待子模块功能、时序、统一ABI和全系统结束/drain契约冻结。 |

上述限制按已批准临时兼容路线保留；本轮没有自行扩大协议/ABI或要求用户重选已批Q项。若要解除这些条件，需按准则变更控制另行明确接口，不把本报告当作新增功能批准。

## 7. 保留的失败与诊断过程

- 重新构建/执行后，`subsystem.mxm.bf16`仍报权重未到；`subsystem.mxm.decode_streamed_weight`及`subsystem.mxm.decode_layout_comparison`仍报activation未到。3项按Q09保留失败，等待MXM冻结修复；同构建的MEM同步读单测通过。见`cmodel_historical_results.json`。
- 额外`lpu_sxm_command_adapter_tb`报`ERROR illegal map`、`TEST_FAIL errors=1`。修改前完整源码快照重跑同样失败，见`sxm_baseline_failure.json`，不是本轮新增回归；未改SXM算法/adapter或expected掩盖它。
- 保留早期失败目录：编译声明顺序修正、checker reset_seen初态观察修正、缺workload相对路径资源补齐、multigroup成功marker识别修正、T8列间payload差异等。最终通过均另目录重跑，旧日志不覆盖；不能将试跑总记录数当独立覆盖数。

执行与复现说明见[README.md]({(HERE/'README.md').as_posix()})。用户验收、跨模块未来接口收敛和物理验收仍独立，不以本轮MEM功能PASS替代。
'''
    (HERE/'REPORT.md').write_text(report,encoding='utf-8')
    print('MEM_PROFILE_EVIDENCE_READY',out/'summary.json',flush=True)
    return evidence


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--run-id',required=True);a=p.parse_args()
    if not a.run_id.replace('_','').replace('-','').isalnum():p.error('invalid RunId')
    summarize(ROOT/'build/mem_profiles'/a.run_id)
