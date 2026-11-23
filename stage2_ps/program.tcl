# Program the PL only (once per power-on!).
#   C:\Xilinx\SDK\2019.1\bin\xsct.bat program.tcl
set here [file normalize [file dirname [info script]]]
connect
puts [jtag targets]
targets -set -nocase -filter {name =~ "xc7z020*"}
if {[string match "*is configured*" [fpga -state]]} {
    puts "FPGA already configured -> not reprogramming (power-cycle first if you need to)"
} else {
    fpga -f $here/bitstream/term_top.bit
    puts "DONE: [fpga -state]"
}
