library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity RAM_to_TFTLCD is
port(
    clk                                             :   in      std_logic;

    RAM_read_address                                :   out     std_logic_vector(16 downto 0);
    RAM_read_data                                   :   in      std_logic_vector(15 downto 0);

    TFTLCD_Hsync                                    :   out     std_logic;
    TFTLCD_Vsync                                    :   out     std_logic;
    TFTLCD_R                                        :   out     std_logic_vector(7 downto 3);
    TFTLCD_G                                        :   out     std_logic_vector(7 downto 2);
    TFTLCD_B                                        :   out     std_logic_vector(7 downto 3);
    -- stage 5: bounding box overlay (from objdet IP, camera pclk domain, quasi-static)
    box_en                                          :   in      std_logic;
    box_x0                                          :   in      std_logic_vector(8 downto 0);
    box_x1                                          :   in      std_logic_vector(8 downto 0);
    box_y0                                          :   in      std_logic_vector(8 downto 0);
    box_y1                                          :   in      std_logic_vector(8 downto 0);
    box_color                                       :   in      std_logic_vector(15 downto 0);
    box_tog                                         :   in      std_logic
);
end entity;

architecture ar_RAM_to_TFTLCD of RAM_to_TFTLCD is

    signal  sig_h_count                             :            std_logic_vector(15 downto 0) := (others => '0');
    signal  sig_h_sync                              :            std_logic := '0';
    signal  sig_h_sync_delay_1                      :            std_logic := '0';
    signal  sig_h_sync_delay_2                      :            std_logic := '0';

    signal  sig_v_count                             :            std_logic_vector(15 downto 0) := (others => '0');
    signal  sig_v_sync                              :            std_logic := '0';
    signal  sig_v_sync_delay_1                      :            std_logic := '0';
    signal  sig_v_sync_delay_2                      :            std_logic := '0';

    signal  sig_RAM_read_address                    :            std_logic_vector(16 downto 0) := (others => '0');
    signal  sig_RAM_read_data                       :            std_logic_vector(15 downto 0) := (others => '0');

    signal  sig_TFTLCD_R                            :           std_logic_vector(7 downto 3) := (others => '0');
    signal  sig_TFTLCD_G                            :           std_logic_vector(7 downto 2) := (others => '0');
    signal  sig_TFTLCD_B                            :           std_logic_vector(7 downto 3) := (others => '0');
    -- stage 5: box overlay
    signal  sig_tog_sync                            :           std_logic_vector(2 downto 0) := (others => '0');
    signal  sig_bx_en                               :           std_logic := '0';
    signal  sig_bx_x0, sig_bx_x1                    :           std_logic_vector(8 downto 0) := (others => '0');
    signal  sig_bx_y0, sig_bx_y1                    :           std_logic_vector(8 downto 0) := (others => '0');
    signal  sig_bx_color                            :           std_logic_vector(15 downto 0) := (others => '0');
    signal  sig_px, sig_py                          :           std_logic_vector(15 downto 0);
    signal  sig_on_box                              :           std_logic;

begin

-- stage 5: take a new box when objdet toggles box_tog (values are stable for a whole frame)
process(clk)
begin
    if(clk'event and clk = '1')then
        sig_tog_sync <= sig_tog_sync(1 downto 0) & box_tog;
        if(sig_tog_sync(2) /= sig_tog_sync(1))then
            sig_bx_en    <= box_en;
            sig_bx_x0    <= box_x0;
            sig_bx_x1    <= box_x1;
            sig_bx_y0    <= box_y0;
            sig_bx_y1    <= box_y1;
            sig_bx_color <= box_color;
        end if;
    end if;
end process;

-- displayed pixel position: visible area is h_count 42..521, v_count 12..283
sig_px <= sig_h_count - 42;
sig_py <= sig_v_count - 12;

-- 2-pixel thick rectangle outline
sig_on_box <= '1' when ( sig_bx_en = '1' and
                         sig_px >= ("0000000" & sig_bx_x0) and sig_px <= ("0000000" & sig_bx_x1) and
                         sig_py >= ("0000000" & sig_bx_y0) and sig_py <= ("0000000" & sig_bx_y1) and
                         ( sig_px <= ("0000000" & sig_bx_x0) + 1 or sig_px + 1 >= ("0000000" & sig_bx_x1) or
                           sig_py <= ("0000000" & sig_bx_y0) + 1 or sig_py + 1 >= ("0000000" & sig_bx_y1) ) )
              else '0';

process(clk)
begin
    if(clk'event and clk = '1')then
        if(sig_h_count < 40)then
            sig_h_sync  <=  '0';
            sig_h_count <=  sig_h_count + 1;
        elsif((sig_h_count >= 40) and (sig_h_count < 522))then
            sig_h_sync  <=  '1';
            sig_h_count <=  sig_h_count + 1;
        else
            sig_h_sync  <=  '0';
            sig_h_count <=  (others => '0');

            if(sig_v_count < 10)then
                sig_v_sync  <=  '0';
                sig_v_count <=  sig_v_count + 1;
            elsif((sig_v_count >= 10) and (sig_v_count < 284))then
                sig_v_sync  <=  '1';
                sig_v_count <=  sig_v_count + 1;
            else
                sig_v_sync  <=  '0';
                sig_v_count <=  (others => '0');
            end if;
        end if;
    end if;
end process;

process(clk)
begin
    if(clk'event and clk = '1')then
        if(sig_v_sync = '0')then
            sig_RAM_read_address <= (others => '0');
        else
            if(sig_v_count >= 12 and sig_v_count < 284)then
                if((sig_h_count >= 42) and (sig_h_count < 522))then
                    sig_RAM_read_address <= sig_RAM_read_address + 1;
                end if;
            end if;
        end if;
    end if;
end process;

RAM_read_address <= sig_RAM_read_address;

process(clk)
begin
    if(clk'event and clk = '0')then
        sig_h_sync_delay_1 <= sig_h_sync;
        sig_h_sync_delay_2 <= sig_h_sync_delay_1;

        sig_v_sync_delay_1 <= sig_v_sync;
        sig_v_sync_delay_2 <= sig_v_sync_delay_1;
    end if;
end process;

TFTLCD_Hsync    <=  sig_h_sync_delay_2;
TFTLCD_Vsync    <=  sig_v_sync_delay_2;

process(clk)
begin
	if(clk'event and clk = '1')then
        if(sig_v_count = 12)then
            if(sig_h_count = 43)then
                sig_RAM_read_data <= (others => '1');
            elsif(sig_h_count = 522)then
                sig_RAM_read_data <= (others => '1');
            else
                sig_RAM_read_data <= RAM_read_data;
            end if;
        elsif(sig_v_count = 283)then
            if(sig_h_count = 43)then
                sig_RAM_read_data <= (others => '1');
            elsif(sig_h_count = 522)then
                sig_RAM_read_data <= (others => '1');
            else
                sig_RAM_read_data <= RAM_read_data;
            end if;
        else
            if(sig_on_box = '1')then
                sig_RAM_read_data <= sig_bx_color;      -- stage 5: box outline
            else
                sig_RAM_read_data <= RAM_read_data;
            end if;
        end if;
    end if;
end process;

process(clk)
begin
	if(clk'event and clk = '0')then
        sig_TFTLCD_R	<=	sig_RAM_read_data(4 downto 0);
        sig_TFTLCD_G	<=	sig_RAM_read_data(10 downto 5);
        sig_TFTLCD_B	<=	sig_RAM_read_data(15 downto 11);
	end if;
end process;

TFTLCD_R    <=  sig_TFTLCD_R;
TFTLCD_G    <=  sig_TFTLCD_G;
TFTLCD_B    <=  sig_TFTLCD_B;

end architecture;