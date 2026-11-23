# Block design "system": Zynq PS + capture IP
#   PS : UART1 (MIO 48..49, 1.8V), DDR off, M_AXI_GP0 on, FCLK_CLK0 100 MHz
#   capture_0 : AXI4-Lite @ 0x43C0_0000 (128 KB), pixel inputs from term_top (cap_*)
create_bd_design system

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0
set_property -dict [list \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
    CONFIG.PCW_EN_DDR {0} \
    CONFIG.PCW_UIPARAM_DDR_ENABLE {0} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
] [get_bd_cells processing_system7_0]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO" Master "Disable" Slave "Disable"} [get_bd_cells processing_system7_0]

create_bd_cell -type ip -vlnv user.org:user:capture:1.0 capture_0
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/processing_system7_0/M_AXI_GP0" Clk "Auto"} [get_bd_intf_pins capture_0/s00_axi]

create_bd_port -dir I cap_pclk
create_bd_port -dir I cap_we
create_bd_port -dir I -from 16 -to 0 cap_addr
create_bd_port -dir I -from 15 -to 0 cap_data
connect_bd_net [get_bd_ports cap_pclk] [get_bd_pins capture_0/pclk]
connect_bd_net [get_bd_ports cap_we]   [get_bd_pins capture_0/pix_we]
connect_bd_net [get_bd_ports cap_addr] [get_bd_pins capture_0/pix_addr]
connect_bd_net [get_bd_ports cap_data] [get_bd_pins capture_0/pix_data]

assign_bd_address
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces processing_system7_0/Data] -filter {NAME =~ "*capture_0*"}]
set_property offset 0x43C00000 $seg
set_property range  128K       $seg
