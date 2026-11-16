# Vivado 2019.1 batch build:  vivado -mode batch -source build.tcl
set here [file normalize [file dirname [info script]]]
open_project $here/ch13_pl_cis.xpr
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "SYNTH_STATUS: [get_property STATUS [get_runs synth_1]]"
puts "IMPL_STATUS:  [get_property STATUS [get_runs impl_1]]"
file copy -force $here/ch13_pl_cis.runs/impl_1/top.bit $here/bitstream/top.bit
close_project
