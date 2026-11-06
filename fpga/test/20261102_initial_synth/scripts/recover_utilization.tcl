set_param general.maxThreads 1
open_checkpoint [lindex $argv 0]
report_utilization -file [lindex $argv 1]
puts "RECOVER_UTILIZATION_COMPLETED"
exit
