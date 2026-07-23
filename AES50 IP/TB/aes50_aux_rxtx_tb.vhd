-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_aux_rxtx_tb.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Testbench to check the Aux encoder / decoder module.
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

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;


entity aux_rxtx_tb is
--  Port ( );
end aux_rxtx_tb;

architecture Behavioral of aux_rxtx_tb is

    signal clk100 									: std_logic := '0';
    signal rst										: std_logic := '1';

	signal fifo_to_decoder_data						: std_logic_vector(15 downto 0) := "0000000000000000";
	signal fifo_to_decoder_data_start				: std_logic := '0';
	signal fifo_to_decoder_rd						: std_logic;
	signal fifo_to_decoder_count					: integer range 176 - 1 downto 0 := 0;
	
	signal encoder_to_fifo_data						: std_logic_vector(15 downto 0) := "0000000000000000";
	signal encoder_to_fifo_data_start				: std_logic := '0';
	signal encoder_to_fifo_wr_en					: std_logic := '0';
	
	signal fifo_data_in								: std_logic_vector(16 downto 0);
	signal fifo_data_out							: std_logic_vector(16 downto 0);
	
	signal dat_out									: std_logic_vector(7 downto 0);
	signal dat_out_valid							: std_logic;
	
	signal uart_from_decoder						: std_logic;
	signal uart_to_encoder							: std_logic;
	
	signal fs_mode									: std_logic_vector(1 downto 0) := "01";
	signal aux_request								: std_logic := '0';


	signal uart_byte_from_uc						: std_logic_vector(7 downto 0) := "00000000";
	signal uart_byte_from_uc_tx_en					: std_logic := '0';
	
	signal uart_byte_to_uc							: std_logic_vector(7 downto 0) := "00000000";
	signal uart_byte_to_uc_dv						: std_logic := '0';
	
begin

	fifo_data_in <= encoder_to_fifo_data & encoder_to_fifo_data_start;
	fifo_to_decoder_data <= fifo_data_out(16 downto 1);
	fifo_to_decoder_data_start <= fifo_data_out(0);
	
    clk100 <= not clk100 after 5ns;
    rst <= '1', '0' after 100ns;



aux_decoder : entity work.aes50_aux_decoder(rtl)
port map(
			clk100_core_i           => clk100,
			rst_i                   => rst,              
    
			-- FIFO / Bitstream Interface
			aux_i                   => fifo_to_decoder_data,
			aux_data_start_marker_i => fifo_to_decoder_data_start,
			aux_in_rd_en_o          => fifo_to_decoder_rd,
			fifo_fill_count_aux_i   => fifo_to_decoder_count,
        
			uart_clks_per_bit_i		=> 868,
			-- Application Interface (Output)
			uart_o           		=> uart_from_decoder
           );



aux_encoder : entity work.aes50_aux_encoder(rtl)
port map(
			clk100_core_i           => clk100,
			rst_i                   => rst,  
			
			-- UART Interface
			uart_i                  => uart_to_encoder,
			uart_clks_per_bit_i     => 868,
			uart_timeout_clks_i          => 1000000,
					
			-- Control Interface
			fs_mode_i               => fs_mode,
			aux_request_i           => aux_request,
			
			-- AES50 Physical Interface (FIFO-In)
			aux_o                   => encoder_to_fifo_data,
			aux_data_start_marker_o => encoder_to_fifo_data_start,
			aux_out_wr_en_o         => encoder_to_fifo_wr_en
           );
	
                                                                                                                                                                                                                                         


aux_data_buffer : entity work.aes50_ring_buffer(rtl)
	generic map (
		RAM_WIDTH 		=> 16+1, -- actually 16-bit aux words + 1 bit start indicator
		RAM_DEPTH 		=> 176 -- 2* blocks with 88* aux-data-words (considered worst case in 44k1 mode)
	)
	port map (
		clk_i 			=> clk100,
		rst_i 			=> rst,
		wr_en_i 		=> encoder_to_fifo_wr_en,
		wr_data_i 		=> fifo_data_in,
		rd_en_i 		=> fifo_to_decoder_rd,
		rd_valid_o 		=> open,
		rd_data_o 		=> fifo_data_out,
		empty_o 		=> open,
		empty_next_o 	=> open,
		full_o 			=> open,
		full_next_o 	=> open,
		fill_count_o 	=> fifo_to_decoder_count
	);
					

uc_uart_tx: entity work.aes50_uart_tx(rtl)
	port map (
		i_Clk       		=> clk100,
		i_TX_DV     		=> uart_byte_from_uc_tx_en,
		i_TX_Byte   		=> uart_byte_from_uc,
		i_CLKS_PER_BIT 		=> 868,
		o_TX_Active 		=> open,
		o_TX_Serial 		=> uart_to_encoder,
		o_TX_Done   		=> open
	);
	
uc_uart_rx: entity work.aes50_uart_rx(rtl)
    port map (
        i_Clk          => clk100,
        i_RX_Serial    => uart_from_decoder,
        i_CLKS_PER_BIT => 868,
        o_RX_DV        => uart_byte_to_uc_dv,
        o_RX_Byte      => uart_byte_to_uc
    );
	
data_requestor: process begin
	
	if (fs_mode = "01") then
		wait for 125us;
		wait until rising_edge(clk100);
		aux_request <= '1';
		wait until rising_edge(clk100);
		aux_request <= '0';
		
	elsif (fs_mode = "00") then
		wait for 250us;
		wait until rising_edge(clk100);
		aux_request <= '1';
		wait until rising_edge(clk100);
		aux_request <= '0';
	end if;


end process data_requestor;
	
stimulus: process 

-- Der Test-String
    constant TEST_MSG : string := "AES50 is fun! Test long long text abcdefghijklmnopqrstuvwxyz blabla Check: " & x"FF" & x"00" & x"55" & x"AA";
    -- Ein Array für die Bytes (um auch kritische Muster wie 0xFF zu senden)
    type byte_array is array (0 to 14) of std_logic_vector(7 downto 0);
    constant STUFFING_TEST : byte_array := (
        x"FF", x"FF", x"FF", x"00", -- Provoziert massives Bit-Stuffing
        x"55", x"AA", x"7F", x"80", 
        x"01", x"02", x"04", x"08", 
        x"10", x"20", x"40"
    );

begin

-- Initialisierung
    uart_byte_from_uc <= (others => '0');
    uart_byte_from_uc_tx_en <= '0';
    wait for 1ms;
    wait until rising_edge(clk100);

    -- 1. Den Text senden
    for i in 1 to TEST_MSG'length loop
        wait for 800 us; -- Etwas schneller als 1ms, um den Puffer zu testen
        wait until rising_edge(clk100);
        uart_byte_from_uc <= std_logic_vector(to_unsigned(character'pos(TEST_MSG(i)), 8));
        uart_byte_from_uc_tx_en <= '1';
        wait until rising_edge(clk100);
        uart_byte_from_uc_tx_en <= '0';
    end loop;

    -- 2. Kritische Bit-Muster für Stuffing & Scrambler senden
    for i in STUFFING_TEST'range loop
        wait for 1 ms;
        wait until rising_edge(clk100);
        uart_byte_from_uc <= STUFFING_TEST(i);
        uart_byte_from_uc_tx_en <= '1';
        wait until rising_edge(clk100);
        uart_byte_from_uc_tx_en <= '0';
    end loop;

    -- 3. Abschluss-Pause
    wait for 50 ms;

    
    
	--4D 61 72 6B 75 73 20 4E 6F 6C 6C -> "Markus Noll"
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"4D";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"61";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"72";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"6B";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"75";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"73";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"20";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"4E";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"6F";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"6C";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';	
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"6C";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';	
	wait for 20ms;




	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"FF";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"00";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"FF";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
	
	wait for 1ms;
	wait until rising_edge(clk100);
	uart_byte_from_uc <= x"00";
	uart_byte_from_uc_tx_en <= '1';
	wait until rising_edge(clk100);
	uart_byte_from_uc_tx_en <= '0';
		

	wait for 20ms;


end process stimulus;



end Behavioral;
