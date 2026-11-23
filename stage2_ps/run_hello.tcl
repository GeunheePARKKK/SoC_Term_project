# Program PL (if not yet), init PS, download and run hello.elf on ARM core 0.
#   C:\Xilinx\SDK\2019.1\bin\xsct.bat run_hello.tcl
# Needs: bitstream/ps7_init.tcl, bitstream/hello.elf  (see README)
set here [file normalize [file dirname [info script]]]
connect
puts [jtag targets]
targets -set -nocase -filter {name =~ "xc7z020*"}
if {![string match "*is configured*" [fpga -state]]} {
    fpga -f $here/bitstream/term_top.bit
}
puts "FPGA: [fpga -state]"
source $here/bitstream/ps7_init.tcl
targets -set -nocase -filter {name =~ "APU*"}
stop
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "ARM*#0"}
rst -processor
dow $here/bitstream/hello.elf
con
puts "hello.elf running - watch the UART terminal (115200)"
