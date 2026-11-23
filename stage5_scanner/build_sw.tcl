# Build the ARM capture application from sdk_src/ against bitstream/term_top.hdf
#   C:\Xilinx\SDK\2019.1\bin\xsct.bat build_sw.tcl
# Output: bitstream/scanner_app.elf, bitstream/ps7_init.tcl
set here [file normalize [file dirname [info script]]]
set ws   $here/vivado/sw
file delete -force $ws
file mkdir $ws
setws $ws
createhw  -name hw_platform -hwspec $here/bitstream/term_top.hdf
createapp -name scanner_app -hwproject hw_platform -proc ps7_cortexa9_0 -os standalone -lang C -app {Empty Application}
importsources -name scanner_app -path $here/sdk_src
projects -build
file copy -force $ws/scanner_app/Debug/scanner_app.elf $here/bitstream/scanner_app.elf
file copy -force $ws/hw_platform/ps7_init.tcl          $here/bitstream/ps7_init.tcl
puts "SW BUILD DONE: $here/bitstream/scanner_app.elf"
