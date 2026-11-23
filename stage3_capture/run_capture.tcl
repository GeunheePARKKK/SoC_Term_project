# Program PL (only if not configured yet), init PS, run capture_app.elf on ARM core 0
#   C:\Xilinx\SDK\2019.1\bin\xsct.bat run_capture.tcl
# Then on the PC:  py -3 tools\capture_to_png.py --port COMxx
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
dow $here/bitstream/capture_app.elf
con
puts "capture_app running - send 'c' over UART (460800) or use tools/capture_to_png.py"
