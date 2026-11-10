"""Build current-source OOC tooling, preserving the approved internal/IO scopes."""
from pathlib import Path
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1]
old=ROOT/'learn/sxm_gap10_20261104/scripts'
s=(old/'physical.tcl').read_text()
s=s.replace('set completed 0','set top [lindex $argv 12]\nset completed 0')
s=s.replace('foreach n {sxm_row_core sxm_compat_decode sxm_compat_engine sxm_compatible_core} {read_verilog -sv [file join $src $n.sv]}', '''set fh [open [file join $src rtl_files.txt] r]
  foreach name [split [string trim [read $fh]] "\\n"] {read_verilog -sv [file join $src $name]}
  close $fh''')
s=s.replace('synth_design -top sxm_compatible_core -part xcvu9p-flga2104-2L-e -mode out_of_context -flatten_hierarchy rebuilt -generic [list T=$tiles PORT_STREAMS=32 TIMER_BITS=16] {*}$extra', '''set generics [list T=$tiles]
  if {$top eq "sxm_triangle_full_core"} {lappend generics PORT_STREAMS=32 TIMER_BITS=16}
  synth_design -top $top -part xcvu9p-flga2104-2L-e -mode out_of_context -flatten_hierarchy rebuilt -generic $generics {*}$extra''')
(E/'scripts/physical.tcl').write_text(s)
for name in ['timing.xdc','io_budget.tcl']:(E/'scripts'/name).write_bytes((old/name).read_bytes())
print('prepared current OOC tooling')
