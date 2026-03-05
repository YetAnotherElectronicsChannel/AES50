-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_aux_decoder.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2026-03-05>
--
-- Description  : Decoder for the AES50 Aux Bitstream
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
        G_MSB_FIRST : boolean := false -- True: Bit 15 zuerst, False: Bit 0 zuerst
    );
    port (
        clk100_core_i           : in  std_logic; 
        rst_i                   : in  std_logic;                
    
        
        aux_i                   : in  std_logic_vector(15 downto 0);
		aux_data_start_marker_i : in  std_logic; 
        aux_in_rd_en_o          : out std_logic;
        fifo_fill_count_aux_i   : in  integer range 176 - 1 downto 0;
        
        
        
        data_out_8bit           : out std_logic_vector(7 downto 0);
        data_out_valid          : out std_logic

		
    );
end aes50_aux_decoder;

architecture rtl of aes50_aux_decoder is

   
    
    signal bit_idx           : integer range 0 to 15 := 0;
    signal is_processing     : std_logic := '0';
    signal fifo_wait_data    : integer range 0 to 3 := 0;
    signal shift_reg_in      : std_logic_vector(15 downto 0);
    signal current_start_mkr : std_logic := '0';
    
	signal first_valid_detect : std_logic := '0';
		
    
    signal descramble_reg    : std_logic_vector(8 downto 0) := (others => '0');
    
    
    signal pattern_detect    : std_logic_vector(10 downto 0) := (others => '0');
	
    signal ones_cnt          : integer range 0 to 15 := 0;
    
    
    signal byte_shifter      : std_logic_vector(7 downto 0) := (others => '0');
    signal byte_bit_cnt      : integer range 0 to 7 := 0;

	signal flush_cnt : integer range 0 to 11 := 0;

begin

	
	
    process(clk100_core_i)
        variable descrambled_bit : std_logic;
		variable payload_bit	 : std_logic;
		variable pattern_detect_v : std_logic_vector(10 downto 0);  -- ADD THIS
		variable current_bit      : std_logic;
    begin
	
        if rising_edge(clk100_core_i) then
		
            if rst_i = '1' then
                
                is_processing     <= '0';
                fifo_wait_data    <= 0;
                aux_in_rd_en_o    <= '0';
                data_out_valid    <= '0';
                descramble_reg    <= (others => '0');
                pattern_detect    <= (others => '0'); 
                ones_cnt          <= 0;
                byte_bit_cnt      <= 0;
				first_valid_detect <= '0';
				
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
                    -- Daten vom Bus übernehmen
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

					pattern_detect_v   := pattern_detect(9 downto 0) & current_bit;
					pattern_detect <= pattern_detect_v;

					-- Unconditional per-frame descrambler reset (spec 8.3)
					if current_start_mkr = '1' and bit_idx = 0 then
						descramble_reg <= "000000000";
						--ones_cnt       <= 0;
						--byte_bit_cnt   <= 0;
					end if;
					
						
					if pattern_detect_v = "01111111110" then
						-- Closing delimiter: pattern_detect_v(10) is its leading '0',
						-- correctly not processed as payload
												
						
						flush_cnt    <= 10;
						ones_cnt <= 0;
						byte_bit_cnt <= 0;
						first_valid_detect <= '1';

					elsif flush_cnt > 0 then
						-- Drain the opening delimiter bits from the delay line
						flush_cnt <= flush_cnt - 1;
						if (flush_cnt = 1) then
							byte_bit_cnt   <= 0;
							ones_cnt <= 0;
						end if;

					else
						-- payload_bit is the 10-cycle-delayed bit: guaranteed not
						-- part of any delimiter because the full window was just checked
						payload_bit := pattern_detect_v(10);

						-- Bit-destuffing (operates on the delayed stream)
						if ones_cnt = 8 and payload_bit = '0' then
							ones_cnt <= 0;
							
						else
							--descrambled_bit := payload_bit;
							-- Descrambler
							if current_start_mkr = '1' and bit_idx = 0 then
								descrambled_bit := payload_bit;
								descramble_reg  <= "00000000" & descrambled_bit;
							else
								descrambled_bit := payload_bit
												   xor descramble_reg(4)
												   xor descramble_reg(8);
								--descramble_reg  <= descramble_reg(7 downto 0)  & descrambled_bit;
								descramble_reg  <= descramble_reg(7 downto 0)  & payload_bit;
							end if;

							if payload_bit = '1' and ones_cnt < 8 then
								ones_cnt <= ones_cnt + 1;
							else
								ones_cnt <= 0;
							end if;

							-- Byte assembler
							byte_shifter <= byte_shifter(6 downto 0) & descrambled_bit;
							if byte_bit_cnt = 7 then
							
								
								data_out_8bit <= descrambled_bit & byte_shifter(0) & byte_shifter(1) & byte_shifter(2) & byte_shifter(3) & byte_shifter(4) & byte_shifter(5) & byte_shifter(6);
																
								if (first_valid_detect='1') then 
									data_out_valid <= '1';
								end if;
								byte_bit_cnt   <= 0;
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

end architecture;