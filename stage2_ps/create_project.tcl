# Recreate the stage 2 Vivado project from sources in this folder.
#   C:\Xilinx\Vivado\2019.1\bin\vivado.bat -mode batch -source create_project.tcl
# Result: vivado/stage2.xpr  (open it in the Vivado GUI afterwards)
set here [file normalize [file dirname [info script]]]
set src  $here/src

create_project stage2 $here/vivado -part xc7z020clg484-1 -force

# HDL sources (referenced in place, not copied)
add_files [list \
    $src/term_top.vhd $src/camera_top.vhd \
    $src/camera_i2c.vhd $src/camera_i2c_command.vhd $src/camera_i2c_rom.vhd \
    $src/camera_to_RAM.vhd $src/RAM_to_TFTLCD.vhd $src/clk_generator.vhd ]
add_files $src/ip/RAM_camera/RAM_camera.xci
add_files -fileset constrs_1 $src/top.xdc

# Block design: Zynq PS only (UART1 on MIO 48..49, DDR off, M_AXI_GP0 off)
source $src/system_bd.tcl
regenerate_bd_layout
validate_bd_design
save_bd_design
generate_target all [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse $here/vivado/stage2.srcs/sources_1/bd/system/hdl/system_wrapper.v

set_property top term_top [current_fileset]
update_compile_order -fileset sources_1
puts "PROJECT CREATED: $here/vivado/stage2.xpr"
