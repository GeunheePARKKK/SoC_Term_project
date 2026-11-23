--------------------------------------------------------------------------------
-- term_top : Term project stage 2 top level
--   - system_wrapper : Zynq PS (ARM) block design (UART1, no DDR, no AXI yet)
--   - camera_top     : stage 1 camera path (OV5640 -> BRAM -> TFT-LCD), PL only
-- Stage 3 will add an AXI capture IP inside the block design and wire the
-- camera pixel stream to it through this file.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity term_top is
port(
    -- Zynq PS fixed I/O (from block design)
    FIXED_IO_mio        :   inout   std_logic_vector(53 downto 0);
    FIXED_IO_ps_clk     :   inout   std_logic;
    FIXED_IO_ps_porb    :   inout   std_logic;
    FIXED_IO_ps_srstb   :   inout   std_logic;

    -- PL
    clk                 :   in      std_logic;                      -- 25 MHz (M19)
    SW_1                :   in      std_logic;                      -- DIP SW1-1 : '1' = OV5640

    camera_SCL          :   inout   std_logic;
    camera_SDA          :   inout   std_logic;
    camera_MCLK         :   out     std_logic;
    camera_RESETn       :   out     std_logic;
    camera_PWDN         :   out     std_logic;
    camera_PCLK         :   in      std_logic;
    camera_VSYNC        :   in      std_logic;
    camera_HSYNC        :   in      std_logic;
    camera_data         :   in      std_logic_vector(7 downto 0);

    TFTLCD_TCLK         :   out     std_logic;
    TFTLCD_Hsync        :   out     std_logic;
    TFTLCD_Vsync        :   out     std_logic;
    TFTLCD_DE_out       :   out     std_logic;
    TFTLCD_D            :   out     std_logic_vector(15 downto 0);
    TFTLCD_Tpower       :   out     std_logic;

    LED                 :   out     std_logic_vector(7 downto 0)
);
end entity;

architecture rtl of term_top is

component system_wrapper is
port(
    FIXED_IO_mio        :   inout   std_logic_vector(53 downto 0);
    FIXED_IO_ps_clk     :   inout   std_logic;
    FIXED_IO_ps_porb    :   inout   std_logic;
    FIXED_IO_ps_srstb   :   inout   std_logic
);
end component;

component camera_top is
port(
    clk                 :   in      std_logic;
    SW_1                :   in      std_logic;
    camera_SCL          :   inout   std_logic;
    camera_SDA          :   inout   std_logic;
    camera_MCLK         :   out     std_logic;
    camera_RESETn       :   out     std_logic;
    camera_PWDN         :   out     std_logic;
    camera_PCLK         :   in      std_logic;
    camera_VSYNC        :   in      std_logic;
    camera_HSYNC        :   in      std_logic;
    camera_data         :   in      std_logic_vector(7 downto 0);
    TFTLCD_TCLK         :   out     std_logic;
    TFTLCD_Hsync        :   out     std_logic;
    TFTLCD_Vsync        :   out     std_logic;
    TFTLCD_DE_out       :   out     std_logic;
    TFTLCD_D            :   out     std_logic_vector(15 downto 0);
    TFTLCD_Tpower       :   out     std_logic;
    LED                 :   out     std_logic_vector(7 downto 0)
);
end component;

begin

u_ps : system_wrapper
port map(
    FIXED_IO_mio        =>  FIXED_IO_mio,
    FIXED_IO_ps_clk     =>  FIXED_IO_ps_clk,
    FIXED_IO_ps_porb    =>  FIXED_IO_ps_porb,
    FIXED_IO_ps_srstb   =>  FIXED_IO_ps_srstb
);

u_camera : camera_top
port map(
    clk                 =>  clk,
    SW_1                =>  SW_1,
    camera_SCL          =>  camera_SCL,
    camera_SDA          =>  camera_SDA,
    camera_MCLK         =>  camera_MCLK,
    camera_RESETn       =>  camera_RESETn,
    camera_PWDN         =>  camera_PWDN,
    camera_PCLK         =>  camera_PCLK,
    camera_VSYNC        =>  camera_VSYNC,
    camera_HSYNC        =>  camera_HSYNC,
    camera_data         =>  camera_data,
    TFTLCD_TCLK         =>  TFTLCD_TCLK,
    TFTLCD_Hsync        =>  TFTLCD_Hsync,
    TFTLCD_Vsync        =>  TFTLCD_Vsync,
    TFTLCD_DE_out       =>  TFTLCD_DE_out,
    TFTLCD_D            =>  TFTLCD_D,
    TFTLCD_Tpower       =>  TFTLCD_Tpower,
    LED                 =>  LED
);

end architecture;
