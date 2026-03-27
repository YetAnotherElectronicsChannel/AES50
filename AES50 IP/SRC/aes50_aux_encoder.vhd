-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_aux_encoder.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel), Chris Nöding
-- Created      : <2026-03-08>
--
-- Description  : Receives data via UART and encodes it for the AES50 Aux Bitstream
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

entity aes50_aux_encoder is
    generic (
        G_MSB_FIRST : boolean := false
    );
    port (
        clk100_core_i           : in  std_logic;
        rst_i                   : in  std_logic;
        
        uart_i                  : in  std_logic;
        uart_clks_per_bit_i     : in  natural;
        uart_timeout_clks_i     : in  natural;
                       
        fs_mode_i               : in  std_logic_vector(1 downto 0); 
        aux_request_i           : in  std_logic; 

        aux_o                   : out std_logic_vector(15 downto 0);
        aux_data_start_marker_o : out std_logic;
        aux_out_wr_en_o         : out std_logic
    );
end aes50_aux_encoder;

architecture rtl of aes50_aux_encoder is

    -- UART & FIFO Signals
    signal uart_rx_dv          	: std_logic;
    signal uart_rx_data        	: std_logic_vector(7 downto 0);
    signal fifo_rd_en          	: std_logic;
    signal fifo_data           	: std_logic_vector(7 downto 0);
    signal fifo_count          	: natural range 0 to 2047;
    signal fifo_empty          	: std_logic;

	signal fifo_temp			: std_logic_vector(7 downto 0);
	
    -- Timeout Logic
    signal timeout_cnt         	: natural 			:= 0;
    signal data_ready_to_send  	: std_logic 		:= '0';

    -- Encoder States
    type enc_state_t is (SEND_IDLE_DELIM, SEND_FRAME_DELIM_START, WAIT_FIFO, WAIT_FIFO2, SEND_DATA, SEND_STUFF, SEND_FRAME_DELIM_END);
    signal enc_state : enc_state_t := SEND_IDLE_DELIM;

    -- Bitstream Signals
    signal scramble_reg        : std_logic_vector(8 downto 0) 	:= (others => '0');
    signal ones_cnt            : natural range 0 to 8 			:= 0;
    signal delim_cnt           : natural range 0 to 10 			:= 0;
    signal byte_bit_cnt        : natural range 0 to 7 			:= 0;
    signal data_reg            : std_logic_vector(7 downto 0);
    
    -- Packer Signals
    signal out_shift_reg       : std_logic_vector(15 downto 0) 	:= (others => '0');
    signal out_bit_idx         : natural range 0 to 15 			:= 0;
    signal word_cnt            : natural range 0 to 127 		:= 0;
    signal target_word_count   : natural range 0 to 127 		:= 44;
    signal block_active        : std_logic 						:= '0';

begin



    process(clk100_core_i)
    begin
        if rising_edge(clk100_core_i) then
            if rst_i = '1' then
                timeout_cnt <= 0;
                data_ready_to_send <= '0';
            else
                if uart_rx_dv = '1' then
                    timeout_cnt <= 0;
                    data_ready_to_send <= '0';
					
                elsif fifo_empty = '0' then
                    if timeout_cnt < uart_timeout_clks_i then
                        timeout_cnt <= timeout_cnt + 1;
                    else
                        data_ready_to_send <= '1';
                    end if;
                else
                    data_ready_to_send <= '0';
                    timeout_cnt <= 0;
                end if;
            end if;
        end if;
    end process;


    process(clk100_core_i)
        variable next_bit       : std_logic;
        variable scrambled_bit : std_logic;
        variable is_payload     : boolean;
        variable bit_valid      : boolean;
    begin
        if rising_edge(clk100_core_i) then
            if rst_i = '1' then
                enc_state <= SEND_IDLE_DELIM;
                out_bit_idx <= 0;
                word_cnt <= 0;
                block_active <= '0';
                aux_out_wr_en_o <= '0';
                scramble_reg <= (others => '0');
                fifo_rd_en <= '0';
            else
                aux_out_wr_en_o <= '0';
                fifo_rd_en      <= '0';
                bit_valid       := false;
                is_payload      := false;

               
                if aux_request_i = '1' then
                    block_active <= '1';
                    word_cnt     <= 0;
                    if fs_mode_i = "00" then 
						target_word_count <= 88;
                    elsif fs_mode_i = "01" then                     
						target_word_count <= 44;
                    end if;
                end if;

                if block_active = '1' then
				
                    if out_bit_idx = 0 and (word_cnt = 0 or word_cnt = 44) then
                        scramble_reg <= (others => '0');
                    end if;

                    
                    case enc_state is
                        when SEND_IDLE_DELIM =>
                            if delim_cnt = 0 or delim_cnt = 10 then 
								next_bit := '0';
                            else                                   
								next_bit := '1';
                            end if;
                            bit_valid := true;
                            
                            if delim_cnt = 10 then
                                delim_cnt <= 0;
								
                                if data_ready_to_send = '1' then
                                    enc_state <= WAIT_FIFO;
                                    fifo_rd_en <= '1'; -- Erstes Byte holen
                                    byte_bit_cnt <= 0;
                                end if;
								
                            else
                                delim_cnt <= delim_cnt + 1;
                            end if;

						when WAIT_FIFO =>
							enc_state <= WAIT_FIFO2;
						
						when WAIT_FIFO2 =>
							fifo_temp <= fifo_data;
							enc_state <= SEND_DATA;
                        when SEND_DATA =>
                            -- Scrambler 
							if out_bit_idx = 0 and (word_cnt = 0 or word_cnt = 44) then
								scrambled_bit := fifo_temp(byte_bit_cnt);								
								scramble_reg <= "00000000"&scrambled_bit;
							else
								scrambled_bit := fifo_temp(byte_bit_cnt) xor scramble_reg(4) xor scramble_reg(8);								
								scramble_reg <= scramble_reg(7 downto 0)&scrambled_bit;
							end if;
							
							                            
                            next_bit := scrambled_bit;
                            bit_valid := true;
                            is_payload := true;

                            -- Bit-Stuffing Check
                            if scrambled_bit = '1' then
                                if ones_cnt = 7 then
                                    enc_state <= SEND_STUFF;
                                    ones_cnt <= 0; 
                                else
                                    ones_cnt <= ones_cnt + 1;
                                end if;
                            else
                                ones_cnt <= 0;
                            end if;

                            
                            if enc_state /= SEND_STUFF then
                                if byte_bit_cnt = 7 then
                                    byte_bit_cnt <= 0;
                                    if fifo_empty = '1' or data_ready_to_send = '0' then
                                        enc_state <= SEND_IDLE_DELIM; 
                                    else
                                        fifo_rd_en <= '1'; 
										enc_state <= WAIT_FIFO;
                                    end if;
                                else
                                    byte_bit_cnt <= byte_bit_cnt + 1;
                                end if;
                            end if;

                        when SEND_STUFF =>
                            next_bit := '0';
                            bit_valid := true;
                            ones_cnt <= 0;
                            enc_state <= SEND_DATA; 

                        when others => enc_state <= SEND_IDLE_DELIM;
                    end case;

                    
                    if bit_valid then
                        -- Scrambler Update
                        --if is_payload then
                        --    scramble_reg <= scramble_reg(7 downto 0) & next_bit;
                        --end if;

                        -- Bit in Wort einfügen
                        if G_MSB_FIRST then
                            out_shift_reg(15 - out_bit_idx) <= next_bit;
                        else
                            out_shift_reg(out_bit_idx) <= next_bit;
                        end if;

                        if out_bit_idx = 15 then
                            out_bit_idx <= 0;
                            aux_o <= out_shift_reg; 
							
                            if G_MSB_FIRST then 	
								aux_o(0) <= next_bit; 
							else 
								aux_o(15) <= next_bit; 
							end if;
                            
                            aux_out_wr_en_o <= '1';
                            
                            if word_cnt = 0 or word_cnt = 44 then
                                aux_data_start_marker_o <= '1';
                            else
                                aux_data_start_marker_o <= '0';
                            end if;

                            if word_cnt = target_word_count - 1 then
                                block_active <= '0';
                            else
                                word_cnt <= word_cnt + 1;
                            end if;
                        else
                            out_bit_idx <= out_bit_idx + 1;
                        end if;
                    end if; 
                end if; 
            end if;
        end if;
    end process;


aes50_uart_rx: entity work.aes50_uart_rx(rtl)
    port map (
        i_Clk          => clk100_core_i,
        i_RX_Serial    => uart_i,
        i_CLKS_PER_BIT => uart_clks_per_bit_i,
        o_RX_DV        => uart_rx_dv,
        o_RX_Byte      => uart_rx_data
    );

    uart_rx_data_buffer: entity work.aes50_ring_buffer(rtl)
    generic map ( 
		RAM_WIDTH => 8, 
		RAM_DEPTH => 2048 
		)
    port map (
        clk_i 			=> clk100_core_i, 
		rst_i 			=> rst_i,
        wr_en_i 		=> uart_rx_dv, 
		wr_data_i 		=> uart_rx_data,
        rd_en_i 		=> fifo_rd_en,
		rd_valid_o 		=> open,		
		rd_data_o 		=> fifo_data,
        empty_o 		=> fifo_empty,
		empty_next_o 	=> open,
		full_o 			=> open,
		full_next_o 	=> open,		
		fill_count_o => fifo_count
    );

end architecture;