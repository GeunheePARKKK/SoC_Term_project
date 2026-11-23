# Recreate the stage 3 Vivado project: vivado/stage3.xpr
#   C:\Xilinx\Vivado\2019.1\bin\vivado.bat -mode batch -source create_project.tcl
# (run package_ip.tcl first if ip_repo/capture_1.0/component.xml is missing)
set here [file normalize [file dirname [info script]]]
set src  $here/src
create_project stage3 $here/vivado -part xc7z020clg484-1 -force
set_property ip_repo_paths [list $here/ip_repo] [current_project]
update_ip_catalog

add_files [list \
    $src/term_top.vhd $src/camera_top.vhd \
    $src/camera_i2c.vhd $src/camera_i2c_command.vhd $src/camera_i2c_rom.vhd \
    $src/camera_to_RAM.vhd $src/RAM_to_TFTLCD.vhd $src/clk_generator.vhd ]
add_files $src/ip/RAM_camera/RAM_camera.xci
add_files -fileset constrs_1 $src/top.xdc

source $src/system_bd.tcl
regenerate_bd_layout
validate_bd_design
save_bd_design
generate_target all [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse $here/vivado/stage3.srcs/sources_1/bd/system/hdl/system_wrapper.v

set_property top term_top [current_fileset]
update_compile_order -fileset sources_1
puts "PROJECT CREATED: $here/vivado/stage3.xpr"
