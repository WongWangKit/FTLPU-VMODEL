"""Validate actual r2 evidence before publishing the integration supplement."""
import argparse
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
import joint

ROOT, HERE, common = joint.ROOT, joint.HERE, joint.common
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--run-id', required=True)
args = p.parse_args()
if not re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id):
    p.error('invalid RunId')
out = ROOT/'build/mem_profiles'/args.run_id
prior = ROOT/'build/mem_profiles/mem_20261027_profiles_r1'


def passed(file, count):
    values = common.read(out/file)
    assert len(values) == count, (file, len(values), count)
    assert all(x['status'] == 'passed' for x in values), file
    return values


combinations = passed('joint_combinations_results.json', 8)
directed = passed('integration_results.json', 3)
collisions = passed('collision_results.json', 3)
legacy_profiles = passed('legacy_profile_results.json', 3)
configuration = passed('configuration_results.json', 7)
limits = passed('joint_limits_results.json', 4)
assert {(r['name'],r['region']) for r in combinations} == {
    (name,region) for name in ['mem_srf_sxm_turnaround','mem_srf_sxm_roundtrip',
    'mem_srf_sxm_existing_workload','dma_store_vector_sink'] for region in ['low','high']}
random = []
coverage = {}
for profile in [16,32,64]:
    values = passed(f'joint_random_{profile}_results.json', 16)
    assert {v['seed'] for v in values} == set(range(0x4a4f4900, 0x4a4f4910))
    assert all(v['profile']==profile and v['coverage']['random_cycles']>=1000 and
               v['coverage']['random_tap_commands']>0 and v['coverage']['random_write_commands']>0
               for v in values)
    for v in values:
        vector = Path(v['result']['log']).parent.parent/(v['name']+'.txt')
        assert common.sha(vector) == v['vector_sha256']
    coverage[profile] = {key: [min(v['coverage'][key] for v in values),
                              max(v['coverage'][key] for v in values)]
                         for key in ['random_jobs','random_waves','random_groups',
                                     'random_streams','random_destination_rows']}
    random += values

legacy = common.read(out/'legacy_results.json')
assert len(legacy)==13
failed = [r for r in legacy if r['status']!='passed']
assert len(failed)==1 and failed[0]['name']=='sxm_command_adapter'
failure_log = next((out/'legacy').glob('sxm_command_adapter_attempt*/run.txt'))
failure_text = failure_log.read_text(encoding='utf-8', errors='replace')
assert 'ERROR illegal map' in failure_text and 'TEST_FAIL errors=1' in failure_text
# The complete list must match r1's FINAL regression sources. r1 also compiled
# its earlier preimplementation snapshot and reproduced the same failure there.
previous_sxm = max((prior/'legacy').glob('sxm_command_adapter_attempt*'),
                   key=lambda x:int(x.name.split('attempt')[-1]))
old_identity = common.read(previous_sxm/'source_identity.json')
for line in (ROOT/'sim/filelist_sxm_command_adapter.f').read_text().splitlines():
    if line.strip():
        path = ROOT/line.strip()
        assert common.sha(path)==old_identity[str(path)]
baseline_sxm_log = (prior/'known_sxm_baseline/run.txt').read_text(encoding='utf-8', errors='replace')
assert 'ERROR illegal map' in baseline_sxm_log and 'TEST_FAIL errors=1' in baseline_sxm_log

history = common.read(out/'cmodel_historical_results.json')
assert len(history)==4
assert [r['status'] for r in history] == ['historical_failure_reproduced']*3+['passed']
for r in history[:3]:
    text = Path(r['result']['log']).read_text(encoding='utf-8', errors='replace')
    expected = 'before all eight weight streams arrived' if r['name']=='mxm_bf16_test' else 'before its activation vector arrived'
    assert expected in text and r['result']['exit']!=0 and not r['result']['timeout']

# Confirm every compiled final-source simulation actually used the files now
# being delivered. Mutants are not part of this run's stages.
identities = list(out.rglob('source_identity.json'))
assert identities
for identity in identities:
    for path, digest in common.read(identity).items():
        assert common.sha(Path(path))==digest, ('source drift', identity, path)
for identity in out.glob('integration/*/reference_identity.json'):
    for path, digest in common.read(identity).items():
        assert common.sha(Path(path))==digest, ('reference drift', identity, path)
# Extra verification-only RNG code must not change the default directed golden.
old_directed = {r['profile']:r for r in common.read(prior/'integration_results.json') if r['status']=='passed'}
assert all(r['vector_sha256']==old_directed[r['profile']]['vector_sha256'] for r in directed)

summary = dict(run_id=args.run_id, combinations=combinations, directed=directed,
               randomized=random, coverage_ranges=coverage, collisions=collisions,
               legacy_profiles=legacy_profiles, configuration=configuration,
               unsupported_attachment_rejections=limits, legacy=legacy, history=history,
               checked_simulation_source_manifests=len(identities),
               random_comparison_cycles=sum(r['coverage']['random_cycles'] for r in random),
               integration_total_cycles=sum(r['coverage']['total_cycles'] for r in random)+
                   sum(int(Path(r['result']['log']).read_text(encoding='utf-8', errors='replace').split('cycles=')[1].split()[0]) for r in directed),
               product_rtl_change_allowed=False, cmodel_change_allowed=False,
               decision='User explicitly declined new attachment ports; MEM+C2C SRAM endpoint waits for command/completion freeze.')
common.save(out/'joint_summary.json', summary)

url = out.as_posix()
report = f'''# MEM 子任务三/四：第二轮联合验证补充报告

日期：2026-10-27。RunId：`{args.run_id}`。准则仍为已批准v5；本文件只记录执行结果，不另定功能或接口。

## 1. 这一轮推进了什么

1. **原有 SXM 和 DMA 组合已在正式 LPU32 的 MEM 几何 F52/T4/P2048 上实际跑通**，不再只停留在小深度兼容测试。仍是完整32B向量和整段00/FF接口。
2. **真实 MEM＋持久 SRF 闭环增加三档各16 seeds**，每seed额外1000个随机比较周期，共{summary['random_comparison_cycles']}个随机周期。不是独立MEM测试：有真实SRF传播、注册提交、Write消费、Tap继续传播、相邻连续命令波和完整SRAM签名。
3. 兼容组合、冲突、legacy47、参数拒绝、C2C原有子链及历史失败重新运行。**没有将未连接的MEM端点或未支持的新尺寸记作通过。**

## 2. 用户本轮决定及实施边界

询问是否给现有主integration追加默认关闭、纯组合的附件端口，以接入真实MEM→C2C→MEM。用户明确选择：**暂不增加接口；只补跑现有组合，等统一命令/完成接口冻结后再接MEM+C2C。** 已遵守：未新增附件端口、产品顶层、独立桥、第二份SRF状态、完成协议或调度器。

本轮**产品RTL和CModel文件均未修改**（相对本RunId开始前的dirty快照逐文件核验）。因此也没有新增同步读补丁、Read级、stall/retry、补零/截断或时序改造。变化仅在验证driver、四个既有TB的测试参数、补测设施及执行记录。CModel继续直接使用原c7本地同步读R1；不另立第二套参考模型。

## 3. 实际结果

| 层级/测试 | 本轮实际结果 | 边界 |
|---|---|---|
| MEM/SRF 三档定向 | 16/32/64全部通过；H2/F52/K2，每个leaf checker和物理深度检查、全SRF状态/数据、raw响应/consume、末尾全SRAM签名 | 原定向向量与r1逐字节相同；另有真实R1同步读单测三档通过 |
| MEM/SRF 三档随机 | 每档16 seeds，共48组通过；每组额外1000个随机比较周期；含前置全leaf真实写入和定向段，总比较周期{summary['integration_total_cycles']} | seed=0x4a4f4900..0x4a4f490f；随机合法日程使用原接口，非法域另测；不是任意partial |
| SXM turnaround | 正式32低/高地址各1组，通过 | F52/P2048实际展开；原workload活动MEM仍是原16 slices，不声称全部52 slices都参与SXM运算 |
| SXM roundtrip | 正式32低/高地址各1组，通过 | 真实MEM→SRF→Transpose/Permute→SRF→MEM→Readback；原cycle检查保留 |
| SXM 原workload | 正式32低/高地址各1组，通过 | 原vector/golden保持；无新tile/packet协议 |
| DMA Store sink | 正式32低/高地址各1组，通过 | 实际group12 MEM→SRF→TX gather→FIFO→完整256bit sink；含hold、选流、背靠背、复位及原cycle检查 |
| 旧组合回归 | 13项重跑：12通过，1项既有失败保留 | 含C2C RX/SRF、TX/SRF、peer e2e；不含MEM存储端点 |
| MEM/SRF 冲突 | 16/32/64三档均通过 | 0/1/2/3 MEM来源×upstream、相同payload、无关cell、原始身份、不杀旧波 |
| legacy47 三档链 | 三档均通过 | 保持47bit原接口；不赋予Tap/preserve新语义 |
| 主路径配置约束 | 7项按预期完成 | 4合法、2仿真拒绝、1非法profile展开拒绝，分别记账 |
| 附件不支持档位 | 4项按预期拒绝 | SXM/DMA各拒绝16/64，防止T4接口冒充16/64B能力；这不是对应功能通过 |
| CModel历史回归 | MEM同步读通过；三个MXM旧失败原样复现 | 当前源码重新构建，不插NOP、不改expected或关闭checker |

正式32地址用例：turnaround行0/2047；roundtrip行0..1/2046..2047；原workload行0、32/2015、2047；DMA行5..8/2044..2047。原profile0的地址、容量和workload保持，由兼容回归重新核验。

随机调度范围是合法域验证，不是硬件新增的避冲突调度功能；每组先运行原全leaf初始化/定向段，再随机选择方向、源/目的group、stream块、1..8连续波、Write/Tap、目标行。每seed统计见`joint_summary.json`的coverage_ranges；不把随机采样当成穷举证明。所有响应、消费、SRF状态及最终所有存储行签名仍由真实本地R1生成期望。

## 4. 保留失败，不改成绿灯

- `sxm_command_adapter`：`ERROR illegal map`、`TEST_FAIL errors=1`。本轮完整源码清单与r1最终回归版本一致；r1还已用其修改前快照复现同一失败，既有失败继续保留。
- `mxm_bf16_test`：IW先于八条weight streams到达。
- `mxm_decode_streamed_weight_test`、`mxm_decode_layout_comparison_test`：activation load先于activation vector到达。

后三项按Q09保留；不是本轮新增MEM/SRF回归失败，也不能将失败写作通过。

## 5. 仍不能闭环的清单

| ID | 当前缺口 | 继续实施的前置条件 |
|---|---|---|
| I03 | 任意partial masks的MEM/SRF端到端未执行 | 真实lane调用者及AND/FF边界冻结，在同一integration升级；当前只测00/FF，不用force冒充 |
| I05、SXM相关I09 | LPU16/64的SXM链路未执行；正式32原组合已补测 | SXM新tile/selector/packet及返回时序冻结；不能只删T4检查 |
| I06 | 16B/64B DMA完整向量接口未执行；正式32的32B链已补测 | 完整vector/beat及完成握手统一，不裁64B、不填造16B |
| I07 | C2C真实MEM存储端点未接；LPU64两beat未实现 | 按用户本轮决定等待统一命令/完成接口；接入时RX列13与MEM真实重叠，须独立slot，不套SXM复用结论 |
| I08/I10 | 真实ICU Macro/Repeat/Loop、其他FU与三档整机未执行 | 统一ABI、各FU接口/功能/延迟、队列及系统结束/drain冻结；TB primitive调度不等于整机 |
| 物理验收 | 综合/STA/PPA/CDC/上板、其他RTL工具未执行 | 单独物理工程与工具环境验收，不从XSim功能结果推断 |

所以结论是：**现有接口能表达的MEM/SRF、SXM T4及DMA32B联合链路已经进一步补验；没有宣称子任务四的全部远期目标完成，更没有宣称整机三档验收。**

## 6. 证据与复现

- [本轮机器汇总]({url}/joint_summary.json)：逐项实际结果、log、vector SHA256及随机coverage。
- [本轮运行目录]({url})：556文件修改前快照、编译/仿真命令、各次source_identity、CModel目标/header/exe身份；原r1目录未覆盖。
- [最终身份]({url}/joint_final_manifest.json)、[源码压缩包校验]({url}/joint_archives.sha256.json)：记录本轮新增/修改文件，并强制校验产品RTL及CModel未变化。
- [执行脚本]({HERE.as_posix()}/joint.py)、[汇总校验]({HERE.as_posix()}/joint_summary.py)。复现命令见README。XSim2023.2 O0，参考g++ C++20 O2静态链接，与r1口径一致。
'''
(HERE/'JOINT_REPORT.md').write_text(report, encoding='utf-8')

# Keep r1's report/results intact; add a visible pointer rather than rewriting
# its old PASS identities or presenting them as current-run evidence.
report_path = HERE/'REPORT.md'
old = report_path.read_text(encoding='utf-8')
pointer = '> 后续联合补测：['+'JOINT_REPORT.md'+']('+ (HERE/'JOINT_REPORT.md').as_posix()+')，RunId `'+args.run_id+'`。原r1结果保留；SXM/DMA正式32及三档随机闭环以补充报告为准。\n\n'
if pointer not in old:
    report_path.write_text(old.replace('\n\n','\n\n'+pointer,1), encoding='utf-8')

registry_path = HERE/'integration_registry.json'
registry = common.read(registry_path)
registry['followup_run_id'] = args.run_id
registry['followup_summary'] = (out/'joint_summary.json').as_posix()
registry['followup_source_identity'] = (out/'joint_final_manifest.json').as_posix()
registry['mem_c2c_decision'] = summary['decision']
for caller in registry['callers']:
    if caller['caller']=='lpu_mem_srf_integration':
        caller['followup_verified'] = 'H2/F52/K2 profiles16/32/64: directed + 16 random seeds/profile, 1000 extra random cycles/seed'
    elif caller['caller'].startswith('SXM turnaround'):
        caller['followup_verified'] = 'formal32 F52/T4/P2048: turnaround, roundtrip, original workload, each low/high rows; original active16 slices only'
    elif caller['caller']=='DMA store vector sink':
        caller['followup_verified'] = 'formal32 F52/T4/P2048 complete256bit vector sink, low/high rows, original FIFO/hold/b2b/cycle checks'
    elif caller['caller'].startswith('C2C RX'):
        caller['followup_verified'] = 'existing T4 RX/TX/peer chains rerun; no MEM storage endpoint or new attachment ports, per user decision'
common.save(registry_path, registry)

# Execution status only: preserve the approved v5 decisions and historical
# table, and explicitly point readers to the later, narrower evidence update.
plan_path = ROOT/'spec_new_c7ae225/mem参数化与集成建议.md'
plan = plan_path.read_text(encoding='utf-8')
note = ('> 后续执行记录（不改变v5审批）：`'+args.run_id+'`已补验正式LPU32 F52/T4/P2048的SXM/DMA原组合低/高地址，以及三档各16 seeds真实MEM/SRF随机闭环。用户本轮决定暂不新增附件接口，MEM+C2C存储端点等待统一命令/完成接口冻结。详见[第二轮联合报告]('+ (HERE/'JOINT_REPORT.md').as_posix()+')；以下首轮状态表保留作历史，后续实测范围以该补充记录为准。\n\n')
if note not in plan:
    plan_path.write_text(plan.replace('### 3.2 每个临时接口必须可追踪\n\n',
                        '### 3.2 每个临时接口必须可追踪\n\n'+note,1), encoding='utf-8')

common.save(out/'joint_archive_results.json', joint.archive(out))
print('JOINT_SUMMARY TEST_PASS', args.run_id, 'random_cycles', summary['random_comparison_cycles'])
