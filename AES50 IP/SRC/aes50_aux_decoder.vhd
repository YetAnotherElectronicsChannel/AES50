-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_aux_decoder.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2026-03-05>
--
-- Description  : Decodes the AES50 Aux Bitstream and sends received data out via UART
--
-- License      : GNU General Public License v3.0 or later (GPL-3.0-or-later)
--
-- This file is part of the AES50 VHDL IP-CORE.
--
-- The AES50 VHDL IP-CORE is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as published
-- by the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- The AES50 VHDL IP-CORE is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <https://www.gnu.org/licenses/>.
-- ===========================================================================


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_aux_decoder is
    generic (
        G_MSB_FIRST : boolean := false
    );
    port (
        clk100_core_i           : in  std_logic; 
        rst_i                   : in  std_logic;                
            
        aux_i                   : in  std_logic_vector(15 downto 0);
		aux_data_start_marker_i : in  std_logic; 
        aux_in_rd_en_o          : out std_logic;
        fifo_fill_count_aux_i   : in  integer range 176 - 1 downto 0;
        
		uart_clks_per_bit_i		: in integer;
        uart_o					: out std_logic
	);
end aes50_aux_decoder;

architecture rtl of aes50_aux_decoder is

    signal bit_idx              : integer range 0 to 15 := 0;
    signal is_processing        : std_logic := '0';
    signal fifo_wait_data       : integer range 0 to 3 := 0;
    signal shift_reg_in         : std_logic_vector(15 downto 0);
    signal current_start_mkr    : std_logic := '0';    
    signal first_valid_detect   : std_logic := '0';    
    signal descramble_reg       : std_logic_vector(8 downto 0) := (others => '0'); 
    signal pattern_detect       : std_logic_vector(10 downto 0) := (others => '0');	
    signal ones_cnt             : integer range 0 to 15 := 0;    
    signal byte_shifter         : std_logic_vector(7 downto 0) := (others => '0');
    signal byte_bit_cnt         : integer range 0 to 7 := 0;
    signal flush_cnt            : integer range 0 to 11 := 0;
    signal frame_reset_pending  : std_logic := '0';
	
    signal data_out_8bit        : std_logic_vector(7 downto 0);
    signal data_out_valid       : std_logic;
	
    -- UART signals
    signal uart_tx_byte         : std_logic_vector(7 downto 0);
    signal uart_tx_enable       : std_logic;
    signal uart_tx_busy         : std_logic;
    signal uart_tx_done         : std_logic;
	
    signal fifo_to_uart_data    : std_logic_vector(7 downto 0);
    signal fifo_to_uart_rd_en   : std_logic;
    signal fifo_to_uart_count   : integer range 2047 downto 0;
    signal fifo_uart_tx_state   : integer range 15 downto 0;

begin

    process(clk100_core_i)
        variable descrambled_bit  : std_logic;
        variable payload_bit      : std_logic;
        variable pattern_detect_v : std_logic_vector(10 downto 0);  
        variable current_bit      : std_logic;
    begin
	
        if rising_edge(clk100_core_i) then
		
            if rst_i = '1' then
                is_processing       <= '0';
                fifo_wait_data      <= 0;
                aux_in_rd_en_o      <= '0';
                data_out_valid      <= '0';
                descramble_reg      <= (others => '0');
                pattern_detect      <= (others => '0'); 
                ones_cnt            <= 0;
                byte_bit_cnt        <= 0;
                first_valid_detect  <= '0';
                frame_reset_pending <= '0';
				
            else
                data_out_valid  <= '0';
                aux_in_rd_en_o  <= '0';
				
                if is_processing = '0' and fifo_wait_data = 0 then
                    if fifo_fill_count_aux_i > 0 then
                        aux_in_rd_en_o <= '1';
                        fifo_wait_data  <= 1;
                    end if;
					
                elsif fifo_wait_data = 1 then
                    fifo_wait_data <= 2;
					
                elsif fifo_wait_data = 2 then
                    shift_reg_in      <= aux_i;
                    current_start_mkr <= aux_data_start_marker_i;
                    bit_idx           <= 0;
                    fifo_wait_data    <= 0;
                    is_processing     <= '1';
                end if;

                if is_processing = '1' then

                    if G_MSB_FIRST then
                        current_bit := shift_reg_in(15 - bit_idx);
                    else
                        current_bit := shift_reg_in(bit_idx);
                    end if;

                    pattern_detect_v := pattern_detect(9 downto 0) & current_bit;
                    pattern_detect   <= pattern_detect_v;

                    if current_start_mkr = '1' and bit_idx = 10 then
                        descramble_reg      <= "000000000";
                        frame_reset_pending <= '1';
                    end if;
					
                    if pattern_detect_v = "01111111110" then
					
                        flush_cnt           <= 10;
                        ones_cnt            <= 0;
                        byte_bit_cnt        <= 0;
                        first_valid_detect  <= '1';
                        frame_reset_pending <= '0';

                    elsif flush_cnt > 0 then
                        flush_cnt <= flush_cnt - 1;
                        if flush_cnt = 1 then
                            byte_bit_cnt <= 0;
                            ones_cnt     <= 0;
                        end if;

                    else
                        payload_bit := pattern_detect_v(10);

                        if ones_cnt = 8 and payload_bit = '0' then
                            ones_cnt <= 0;
							
                        else
                            
                            if frame_reset_pending = '1' then
                                ones_cnt            <= 0;
                                byte_bit_cnt        <= 0;
                                frame_reset_pending <= '0';
                            end if;
                            
                            descrambled_bit := payload_bit
                                               xor descramble_reg(4)
                                               xor descramble_reg(8);
                            descramble_reg  <= descramble_reg(7 downto 0) & payload_bit;
							

                            if payload_bit = '1' and ones_cnt < 8 then
                                ones_cnt <= ones_cnt + 1;
                            else
                                ones_cnt <= 0;
                            end if;

                            -- Byte assembler
                            byte_shifter <= byte_shifter(6 downto 0) & descrambled_bit;
                            if byte_bit_cnt = 7 then
                                data_out_8bit <= descrambled_bit
                                              & byte_shifter(0) & byte_shifter(1)
                                              & byte_shifter(2) & byte_shifter(3)
                                              & byte_shifter(4) & byte_shifter(5)
                                              & byte_shifter(6);
                                if first_valid_detect = '1' then 
                                    data_out_valid <= '1';
                                end if;
                                byte_bit_cnt <= 0;
                            else
                                byte_bit_cnt <= byte_bit_cnt + 1;
                            end if;

                        end if; 
                    end if; 

                    if bit_idx = 15 then
                        is_processing <= '0';
                    else
                        bit_idx <= bit_idx + 1;
                    end if;

                end if; 
				
            end if;
        end if;
		
    end process;
	
	
    aes50_uart_tx: entity work.aes50_uart_tx(rtl)
    port map (
        i_Clk          => clk100_core_i,
        i_TX_DV        => uart_tx_enable,
        i_TX_Byte      => uart_tx_byte,
        i_CLKS_PER_BIT => uart_clks_per_bit_i,
        o_TX_Active    => uart_tx_busy,
        o_TX_Serial    => uart_o,
        o_TX_Done      => uart_tx_done
    );
		
    uart_tx_data_buffer : entity work.aes50_ring_buffer(rtl)
    generic map (
        RAM_WIDTH => 8, 	
        RAM_DEPTH => 2048 		
    )
    port map (
        clk_i        => clk100_core_i,
        rst_i        => rst_i,
        wr_en_i      => data_out_valid,
        wr_data_i    => data_out_8bit,
        rd_en_i      => fifo_to_uart_rd_en,
        rd_valid_o   => open,
        rd_data_o    => fifo_to_uart_data,
        empty_o      => open,
        empty_next_o => open,
        full_o       => open,
        full_next_o  => open,
        fill_count_o => fifo_to_uart_count
    );
		
    -- UART TX controller
    process (clk100_core_i)
    begin
        if rising_edge(clk100_core_i) then 
            if rst_i = '1' then
                uart_tx_enable     <= '0';
                uart_tx_byte       <= (others => '0');
                fifo_to_uart_rd_en <= '0';	
                fifo_uart_tx_state <= 0;
				
            else
			
                if fifo_to_uart_count > 0 and uart_tx_busy = '0' and fifo_uart_tx_state = 0 then
                    fifo_to_uart_rd_en <= '1';
                    fifo_uart_tx_state <= 1;
					
                elsif fifo_uart_tx_state = 1 then
                    fifo_to_uart_rd_en <= '0';
                    fifo_uart_tx_state <= 2;
					
                elsif fifo_uart_tx_state = 2 then
                    uart_tx_byte       <= fifo_to_uart_data;
                    uart_tx_enable     <= '1';
                    fifo_uart_tx_state <= 3;
					
                elsif fifo_uart_tx_state = 3 then
                    uart_tx_enable     <= '0';
                    fifo_uart_tx_state <= 4;
					
                elsif fifo_uart_tx_state = 4 and uart_tx_busy = '1' then
                    fifo_uart_tx_state <= 5;
					
                elsif fifo_uart_tx_state = 5 and uart_tx_done = '1' then
                    fifo_uart_tx_state <= 0;
                end if;
				
            end if;
        end if;
		
    end process;

end architecture;
