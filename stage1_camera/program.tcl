# xsct program.tcl   (SDK 2019.1: C:\Xilinx\SDK\2019.1\bin\xsct.bat program.tcl)
set here [file normalize [file dirname [info script]]]
connect
targets -set -filter {name =~ "xc7z020*"}
fpga -f $here/bitstream/top.bit
puts "DONE: [fpga -state]"
