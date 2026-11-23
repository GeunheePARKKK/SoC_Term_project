# Build bitstream and export hardware (.hdf with bitstream) for SDK.
#   C:\Xilinx\Vivado\2019.1\bin\vivado.bat -mode batch -source build.tcl
set here [file normalize [file dirname [info script]]]
open_project $here/vivado/stage3.xpr
open_bd_design [get_files system.bd]
generate_target all [get_files system.bd]
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "SYNTH_STATUS: [get_property STATUS [get_runs synth_1]]"
puts "IMPL_STATUS:  [get_property STATUS [get_runs impl_1]]"
file mkdir $here/bitstream
file copy -force $here/vivado/stage3.runs/impl_1/term_top.bit    $here/bitstream/term_top.bit
file copy -force $here/vivado/stage3.runs/impl_1/term_top.sysdef $here/bitstream/term_top.hdf
close_project
