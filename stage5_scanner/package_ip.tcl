# Package the custom IPs in ip_repo/ (capture, objdet)
#   C:\Xilinx\Vivado\2019.1\bin\vivado.bat -mode batch -source package_ip.tcl
set here [file normalize [file dirname [info script]]]

proc package_one {root top name disp desc} {
    create_project -in_memory -part xc7z020clg484-1 -force
    add_files $root/hdl/$top.v
    set_property top $top [current_fileset]
    update_compile_order -fileset sources_1
    ipx::package_project -root_dir $root -vendor user.org -library user -taxonomy /UserIP -import_files false -force
    set core [ipx::current_core]
    set_property name $name $core
    set_property display_name $disp $core
    set_property description $desc $core
    set_property version 1.0 $core
    # pclk is the camera pixel clock (plain wire from term_top), not a bus interface
    if {[ipx::get_bus_interfaces pclk -of_objects $core] ne ""} { ipx::remove_bus_interface pclk $core }
    ipx::create_xgui_files $core
    ipx::update_checksums $core
    ipx::save_core $core
    close_project
    puts "IP PACKAGED: $name -> $root"
}

package_one $here/ip_repo/capture_1.0 capture_v1_0 capture \
    {capture_v1.0 (128x128 camera frame capture)} \
    {AXI4-Lite: center 256x256 of one OV5640 frame, 2x2 averaged into 128x128 RGB888}
package_one $here/ip_repo/objdet_1.0 objdet_v1_0 objdet \
    {objdet_v1.0 (background subtraction + bounding box)} \
    {AXI4-Lite: 8x8 block background subtraction, bounding box of changed blocks for the TFT overlay}
