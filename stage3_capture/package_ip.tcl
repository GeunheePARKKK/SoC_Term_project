# Package hdl/capture_v1_0.v as a Vivado IP (user.org:user:capture:1.0) in ip_repo/capture_1.0
#   C:\Xilinx\Vivado\2019.1\bin\vivado.bat -mode batch -source package_ip.tcl
set here [file normalize [file dirname [info script]]]
set root $here/ip_repo/capture_1.0
create_project -in_memory -part xc7z020clg484-1
add_files $root/hdl/capture_v1_0.v
set_property top capture_v1_0 [current_fileset]
update_compile_order -fileset sources_1
ipx::package_project -root_dir $root -vendor user.org -library user -taxonomy /UserIP -import_files false -force
set core [ipx::current_core]
set_property name         capture        $core
set_property display_name {capture_v1.0 (128x128 camera frame capture)} $core
set_property description  {AXI4-Lite: center 256x256 of one OV5640 frame, 2x2 averaged into 128x128 RGB888} $core
set_property version      1.0            $core
# pclk is the camera pixel clock driven from term_top as a plain wire, not a bus interface
foreach bi {pclk} { if {[ipx::get_bus_interfaces $bi -of_objects $core] ne ""} { ipx::remove_bus_interface $bi $core } }
puts "BUS INTERFACES: [ipx::get_bus_interfaces -of_objects $core]"
puts "MEMORY MAPS:    [ipx::get_memory_maps -of_objects $core]"
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core
puts "IP PACKAGED: $root"
