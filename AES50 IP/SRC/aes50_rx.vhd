-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_rx.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Handles the receiving side of the AES50 ethernet-data-stream; unpacks the dataframes and moves audio-samples as well as aux-data into FIFO
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



entity aes50_rx is
	port 	(
			clk100_core_i             	: in  std_logic; 
			clk50_ethernet_i			: in std_logic;
			rst_i               		: in  std_logic;

			-- 00=>44.1k; 01->48k; 10->88.2k; -> 11->96k
			fs_mode_i          			: in std_logic_vector (1 downto 0); 
			
			fs_mode_detect_o			: out std_logic_vector (1 downto 0);
			fs_mode_detect_valid_o		: out std_logic;
			assm_detect_o				: out std_logic;
				
			audio_o						: out std_logic_vector (23 downto 0); 
			audio_ch0_marker_o			: out std_logic;
			
			aux0_o						: out std_logic_vector (15 downto 0);
			aux0_start_marker_o			: out std_logic;

			aux1_o						: out std_logic_vector (15 downto 0);
			aux1_start_marker_o			: out std_logic;
			
			audio_out_rd_en_i			: in std_logic;
			aux0_out_rd_en_i			: in std_logic;
			aux1_out_rd_en_i			: in std_logic;
			
			fifo_fill_count_audio_o 	: out integer range 1056 - 1 downto 0;
			fifo_fill_count_aux0_o 		: out integer range 176 - 1 downto 0;
			fifo_fill_count_aux1_o 		: out integer range 176 - 1 downto 0;	
			
			eth_rx_data_i         		: in std_logic_vector(7 downto 0);
			eth_rx_sof_i          		: in std_logic;
			eth_rx_eof_i          		: in std_logic;
			eth_rx_valid_i        		: in std_logic;
			
			eth_rx_dv_i					: in std_logic;
				
			fifo_debug_o				: out std_logic_vector(3 downto 0)
			
			);
			
end aes50_rx;

architecture rtl of aes50_rx is
	
	--FIFO Interconnects
	
	--audio fifo
	signal	audio_fifo_in		: std_logic_vector (24 downto 0);
	signal 	audio_fifo_in_wr_en	: std_logic;
	signal  audio_fifo_out		: std_logic_vector(24 downto 0);
	
	--aux fifo
	signal 	aux_fifo_in			: std_logic_vector (16 downto 0);	
	signal 	aux_fifo_in_wr_en	: std_logic;
	signal 	aux0_fifo_out		: std_logic_vector(16 downto 0);
	signal 	aux1_fifo_out		: std_logic_vector(16 downto 0);
	
	--RAM signals
	
	--port A (50 MHz P1 side)
	signal 	lc_ram_di_a			: std_logic_vector (31 downto 0);
	signal 	lc_ram_a_addr		: integer range 1408 - 1 downto 0;	-- 2x pingpong * 32x encoded-blocks * 22x subframes 
	signal 	lc_ram_di_a_we		: std_logic;
	
	
	--port B (100 MHz P2 side)
	signal 	lc_ram_di_b			: std_logic_vector (31 downto 0);
	signal  lc_ram_b_addr		: integer range 1408 - 1 downto 0;
	signal 	lc_ram_di_b_we		: std_logic;
	signal 	lc_ram_do_b			: std_logic_vector (31 downto 0);
	
	
	
	--P1 (Process 1) variables
	
	signal reset50M_z, reset50M_zz	: std_logic;
	
	type t_State_p1 is (WaitData, Header, Data, WaitFifoProcessHandshake);
    signal P1_State : t_State_p1;
	signal lc_pingpong			: integer range 1 downto 0;
	
	--edge detectors
	signal eth_rx_dv_edge		: std_logic_vector (1 downto 0);
	
	--Counter variables
	signal lc_counter			: integer range 31	downto 0;	
	signal lc_subframe_counter	: integer range 31 downto 0;
	signal rx_byte_counter		: integer range 1500 downto 0;
	signal rx_round_44k1		: integer range 1 downto 0;
	
	--Temp variables
	signal tmp_rx_word			: std_logic_vector (31 downto 0);
	signal tmp_rx_byte_counter	: integer range 3 downto 0;
	signal found_assm_sync			: std_logic;
	
	--handshake signals
	signal ram_to_fifo_start_50M	: std_logic;
	signal ram_to_fifo_ack_50M_z, ram_to_fifo_ack_50M_zz : std_logic;
	
	
	
	
	
	--P2 (Process 2) variables

	type t_State_p2 is (WaitData, RamReorder, AudioToFifo, AuxToFifo);
    signal P2_State : t_State_p2;
	signal P2_SubState			: integer range 31 downto 0;
	
	signal lc_fifo_pingpong		: integer range 1 downto 0;
	
	--Counter variables
	signal lc2_counter			: integer range 31 downto 0;
	signal lc2_subframe_counter	: integer range 31 downto 0;
	signal encoded_block_no		: integer range 31 downto 0;
	signal tmp_offset_select	: integer range 24 downto 0;
	
	--Temp Variables
	signal reshift_tmp_a		: std_logic_vector(31 downto 0);
	signal reshift_tmp_b		: std_logic_vector(31 downto 0);

	--handshake signals
	signal ram_to_fifo_start_100M_z, ram_to_fifo_start_100M_zz	: std_logic;
	signal ram_to_fifo_ack_100M		: std_logic;
	signal ram_to_fifo_ack_cnt	: integer range 3 downto 0;
	

	signal tmp_sample_a			: std_logic_vector(23 downto 0);
	signal tmp_sample_b			: std_logic_vector(23 downto 0);
	signal tmp_aux_lc24			: std_logic_vector(31 downto 0);
	signal tmp_aux_lc25			: std_logic_vector(31 downto 0);
	signal tmp_aux_vector		: std_logic_vector(63 downto 0);
	signal tmp_slice_vector		: std_logic_vector (63 downto 0);
	
	
	
	
begin


	audio_o <= audio_fifo_out(24 downto 1);
	audio_ch0_marker_o <= audio_fifo_out(0);
	
	aux0_o <= aux0_fifo_out(16 downto 1);
	aux0_start_marker_o <= aux0_fifo_out(0);
	aux1_o <= aux1_fifo_out(16 downto 1);
	aux1_start_marker_o <= aux1_fifo_out(0);

	
	
	
	process (tmp_aux_lc24, tmp_aux_lc25)
	begin
		tmp_aux_vector <=   tmp_aux_lc25(31) & tmp_aux_lc24(31) &
							tmp_aux_lc25(30) & tmp_aux_lc24(30) &
							tmp_aux_lc25(29) & tmp_aux_lc24(29) &
							tmp_aux_lc25(28) & tmp_aux_lc24(28) &
							tmp_aux_lc25(27) & tmp_aux_lc24(27) &
							tmp_aux_lc25(26) & tmp_aux_lc24(26) &
							tmp_aux_lc25(25) & tmp_aux_lc24(25) &
							tmp_aux_lc25(24) & tmp_aux_lc24(24) &
							tmp_aux_lc25(23) & tmp_aux_lc24(23) &
							tmp_aux_lc25(22) & tmp_aux_lc24(22) &
							tmp_aux_lc25(21) & tmp_aux_lc24(21) &
							tmp_aux_lc25(20) & tmp_aux_lc24(20) &
							tmp_aux_lc25(19) & tmp_aux_lc24(19) &
							tmp_aux_lc25(18) & tmp_aux_lc24(18) &
							tmp_aux_lc25(17) & tmp_aux_lc24(17) &
							tmp_aux_lc25(16) & tmp_aux_lc24(16) &
							tmp_aux_lc25(15) & tmp_aux_lc24(15) &
							tmp_aux_lc25(14) & tmp_aux_lc24(14) &
							tmp_aux_lc25(13) & tmp_aux_lc24(13) &
							tmp_aux_lc25(12) & tmp_aux_lc24(12) &
							tmp_aux_lc25(11) & tmp_aux_lc24(11) &
							tmp_aux_lc25(10) & tmp_aux_lc24(10) &
							tmp_aux_lc25(9) & tmp_aux_lc24(9) &
							tmp_aux_lc25(8) & tmp_aux_lc24(8) &
							tmp_aux_lc25(7) & tmp_aux_lc24(7) &
							tmp_aux_lc25(6) & tmp_aux_lc24(6) &
							tmp_aux_lc25(5) & tmp_aux_lc24(5) &
							tmp_aux_lc25(4) & tmp_aux_lc24(4) &
							tmp_aux_lc25(3) & tmp_aux_lc24(3) &
							tmp_aux_lc25(2) & tmp_aux_lc24(2) &
							tmp_aux_lc25(1) & tmp_aux_lc24(1) &
							tmp_aux_lc25(0) & tmp_aux_lc24(0);	

	end process;


	--FIX: Feb 25th 2026 
	--see comment in aes50-tx module where the muxed-slice-vector is generated.
	--The reconsutrction of tmp_sample_a in 48k mode needs to follow the same bit-pattern.	
	
	process (tmp_slice_vector, fs_mode_i)
	begin
		if (fs_mode_i = "01") then
			tmp_sample_a <= tmp_slice_vector(0)&
							tmp_slice_vector(2)&
							tmp_slice_vector(4)&
							tmp_slice_vector(6)&
							tmp_slice_vector(8)&
							tmp_slice_vector(10)&
							tmp_slice_vector(12)&
							tmp_slice_vector(14)&
							tmp_slice_vector(16)&
							tmp_slice_vector(18)&
							tmp_slice_vector(20)&
							tmp_slice_vector(22)&
							tmp_slice_vector(24)&
							
							tmp_slice_vector(26+2)&							
							tmp_slice_vector(28+2)&
							tmp_slice_vector(30+2)&
							tmp_slice_vector(32+2)&
							tmp_slice_vector(34+2)&
							tmp_slice_vector(36+2)&
							tmp_slice_vector(38+2)&
							tmp_slice_vector(40+2)&
							tmp_slice_vector(42+2)&
							tmp_slice_vector(44+2)&
							tmp_slice_vector(46+2);
							
			tmp_sample_b <= tmp_slice_vector(0+1)&
							tmp_slice_vector(2+1)&
							tmp_slice_vector(4+1)&
							tmp_slice_vector(6+1)&
							tmp_slice_vector(8+1)&
							tmp_slice_vector(10+1)&
							tmp_slice_vector(12+1)&
							tmp_slice_vector(14+1)&
							tmp_slice_vector(16+1)&
							tmp_slice_vector(18+1)&
							tmp_slice_vector(20+1)&
							tmp_slice_vector(22+1)&
							tmp_slice_vector(24+1)&
							
							tmp_slice_vector(26+1+2)&
							tmp_slice_vector(28+1+2)&
							tmp_slice_vector(30+1+2)&
							tmp_slice_vector(32+1+2)&
							tmp_slice_vector(34+1+2)&
							tmp_slice_vector(36+1+2)&
							tmp_slice_vector(38+1+2)&
							tmp_slice_vector(40+1+2)&
							tmp_slice_vector(42+1+2)&
							tmp_slice_vector(44+1+2)&
							tmp_slice_vector(46+1+2);
							
							
		elsif (fs_mode_i = "00") then
		
			tmp_sample_a <= tmp_slice_vector(0)&
							tmp_slice_vector(2)&
							tmp_slice_vector(4)&
							tmp_slice_vector(6)&
							tmp_slice_vector(8)&
							tmp_slice_vector(10)&
							tmp_slice_vector(12)&
							tmp_slice_vector(14)&
							tmp_slice_vector(16)&
							tmp_slice_vector(18)&
							tmp_slice_vector(20)&
							tmp_slice_vector(22)&
							tmp_slice_vector(24)&
							tmp_slice_vector(26)&
							
							tmp_slice_vector(28+5)&
							tmp_slice_vector(30+5)&
							tmp_slice_vector(32+5)&
							tmp_slice_vector(34+5)&
							tmp_slice_vector(36+5)&
							tmp_slice_vector(38+5)&
							tmp_slice_vector(40+5)&
							tmp_slice_vector(42+5)&
							tmp_slice_vector(44+5)&
							tmp_slice_vector(46+5);
							
			tmp_sample_b <= tmp_slice_vector(0+1)&
							tmp_slice_vector(2+1)&
							tmp_slice_vector(4+1)&
							tmp_slice_vector(6+1)&
							tmp_slice_vector(8+1)&
							tmp_slice_vector(10+1)&
							tmp_slice_vector(12+1)&
							tmp_slice_vector(14+1)&
							tmp_slice_vector(16+1)&
							tmp_slice_vector(18+1)&
							tmp_slice_vector(20+1)&
							tmp_slice_vector(22+1)&
							tmp_slice_vector(24+1)&
							
							tmp_slice_vector(26+1+5)&
							tmp_slice_vector(28+1+5)&
							tmp_slice_vector(30+1+5)&
							tmp_slice_vector(32+1+5)&
							tmp_slice_vector(34+1+5)&
							tmp_slice_vector(36+1+5)&
							tmp_slice_vector(38+1+5)&
							tmp_slice_vector(40+1+5)&
							tmp_slice_vector(42+1+5)&
							tmp_slice_vector(44+1+5)&
							tmp_slice_vector(46+1+5);
		else
			tmp_sample_a <= (others=>'0');
			tmp_sample_b <= (others=>'0');
		end if;
	end process;

	process (clk100_core_i)
	begin
		if (rising_edge(clk100_core_i)) then
			if (lc2_counter>=0 and lc2_counter<= 14) then
				encoded_block_no <= lc2_counter;
			elsif (lc2_counter>=15 and lc2_counter <= 21) then
				encoded_block_no <= lc2_counter+1;
			elsif (lc2_counter>=22 and lc2_counter<= 24) then
				encoded_block_no <= lc2_counter+2;
			elsif (lc2_counter=25) then
				encoded_block_no <= lc2_counter+3;
			else
				encoded_block_no <= 0;
			end if;
		end if;
	end process;


	process(clk50_ethernet_i)
	begin
		if rising_edge(clk50_ethernet_i) then
		
			--resync signals from 100M->50M clock where necessary
			reset50M_z <= rst_i;
			reset50M_zz <= reset50M_z;		
			ram_to_fifo_ack_50M_z <= ram_to_fifo_ack_100M;
			ram_to_fifo_ack_50M_zz <= ram_to_fifo_ack_50M_z;
			
			
			eth_rx_dv_edge <= eth_rx_dv_edge(0) & eth_rx_dv_i;
			
			if reset50M_zz = '1' or eth_rx_dv_edge = "01" then
				
				assm_detect_o <= '0';
							
				lc_ram_di_a <= (others=>'0');
				lc_ram_a_addr <= 0;
				lc_ram_di_a_we <= '0';
							
				lc_counter	<= 0;
				lc_subframe_counter	<= 0;
				
				-- let's start with 8 in here, because the official spec counts the data-offsets starting from preamble... However our ethernet controller starts giving us data when preamble and SFD have finished
				rx_byte_counter <= 8; 
				
				tmp_rx_word <= (others=>'0');
				tmp_rx_byte_counter <= 0;
				
				ram_to_fifo_start_50M <= '0';
				
				--only when reset
				if reset50M_zz = '1'then
					P1_State <= WaitData;
					lc_pingpong <= 0; 
					lc_fifo_pingpong <= 0;
					fs_mode_detect_o <= (others=>'0');
					fs_mode_detect_valid_o <= '0';
					
					found_assm_sync <= '0';
					rx_round_44k1 <= 0;
				
				elsif (eth_rx_dv_edge = "01") then
					P1_State <= Header;
				end if;
				
			else
			
				--Receive process everytime a new byte arrived from Ethernet....
				if ((P1_State = Header) or (P1_State = Data)) and eth_rx_valid_i = '1' then
				
					--Header part
					if (rx_byte_counter >= 8 and rx_byte_counter <= 19) then
						-- dest & src mac address -> we don't need this information
					
					elsif (rx_byte_counter >= 20 and rx_byte_counter <= 21) then
						-- ether type ... we also don't care
						
					elsif (rx_byte_counter = 22) then	
						-- protocol identifier ... don't care at the moment
						
					elsif (rx_byte_counter = 23) then
						-- user octet ... don't care at the moment.. 
						-- at least from protocol sniffing with wire-shark it seems it is used for something as the logging showed varying information on this byte.. 
						-- However there's no specific meaning just from the spec itself
						
					elsif (rx_byte_counter >= 24 and rx_byte_counter <= 29) then	
					
						--check for ASSM flag
						if (rx_byte_counter = 25 and eth_rx_data_i = x"11") then
							assm_detect_o <= '1';
							found_assm_sync <= '1';
							rx_round_44k1 <= 0;
						else
							assm_detect_o <= '0';
						end if;
						
						if (rx_byte_counter = 26 and eth_rx_data_i = x"46") then
							fs_mode_detect_o <= "01"; --48k detected
							fs_mode_detect_valid_o <= '1';
						elsif (rx_byte_counter = 26 and eth_rx_data_i = x"06") then
							fs_mode_detect_o <= "00"; --44k1 detected
							fs_mode_detect_valid_o <= '1';
						end if;
						
						if (rx_byte_counter = 29) then
							P1_State <= Data;
						end if;
					

					--Data part
					elsif (rx_byte_counter >= 30 and rx_byte_counter <= 1437) then
						-- actual data coming
						if (tmp_rx_byte_counter = 0) then
							tmp_rx_word <= tmp_rx_word(31 downto 8) & eth_rx_data_i;
							tmp_rx_byte_counter <= 1;
							
						elsif (tmp_rx_byte_counter = 1) then
							tmp_rx_word <= tmp_rx_word (31 downto 16) & eth_rx_data_i & tmp_rx_word(7 downto 0);
							tmp_rx_byte_counter <= 2;
							
						elsif (tmp_rx_byte_counter = 2) then
							tmp_rx_word <= tmp_rx_word (31 downto 24) & eth_rx_data_i & tmp_rx_word(15 downto 0);
							tmp_rx_byte_counter <= 3;
							
						else 
							lc_ram_di_a <=  eth_rx_data_i & tmp_rx_word(23 downto 0);
							lc_ram_di_a_we <= '1';
							
							if (fs_mode_i = "00" and rx_round_44k1 = 1) then
								lc_ram_a_addr <= lc_pingpong*704 + lc_counter*22 + lc_subframe_counter + 11;
							else
								lc_ram_a_addr <= lc_pingpong*704 + lc_counter*22 + lc_subframe_counter;
							end if;
							
							if (lc_counter < 31) then
									lc_counter <= lc_counter + 1;
									
							else
								
								if lc_subframe_counter < 10 then					
									lc_subframe_counter <= lc_subframe_counter + 1;
									lc_counter <= 0;									
																
								else							
									lc_subframe_counter <= 0;							
									lc_counter <= 0;
												
									-- this is the finish condition....
									if ( (fs_mode_i = "01" or (fs_mode_i = "00" and rx_round_44k1=1)) and found_assm_sync = '1') then
																	
										P1_State <= WaitFifoProcessHandshake;
										rx_round_44k1 <= 0;
										
										lc_fifo_pingpong <= lc_pingpong;
										ram_to_fifo_start_50M <= '1';
										if (lc_pingpong = 0) then
											lc_pingpong <= 1;
										else
											lc_pingpong <= 0;
										end if;
										
									elsif (fs_mode_i = "00" and rx_round_44k1 = 0 and found_assm_sync = '1') then
										P1_State <= WaitData;
										rx_round_44k1 <= 1;
									end if;
									
									
										
								end if;
							end if;
							
							tmp_rx_byte_counter <= 0;
								
						end if;
						
					end if;
					rx_byte_counter <= rx_byte_counter + 1;
					
					
				elsif P1_State = Data and lc_ram_di_a_we = '1' then			
					-- reset ram write
					lc_ram_di_a_we <= '0';
					
					
				
				elsif P1_State = WaitFifoProcessHandshake then
					lc_ram_di_a_we <= '0';
					if (ram_to_fifo_ack_50M_zz = '1') then
						ram_to_fifo_start_50M <= '0';
						P1_State <= WaitData;
					end if;
				end if;	
			
			end if;
		end if;
			
			
	end process;		


	process(clk100_core_i)
	begin
		if rising_edge(clk100_core_i) then
		
			--resync signals from 50M->100M clock where necessary
			ram_to_fifo_start_100M_z <= ram_to_fifo_start_50M;
			ram_to_fifo_start_100M_zz <= ram_to_fifo_start_100M_z;
			
			if rst_i = '1' then
			
				P2_State <= WaitData;
				P2_SubState <= 0;
				
				
				lc_ram_di_b	<= (others => '0');
				lc_ram_di_b_we <= '0';
				lc_ram_b_addr <= 0;
				
				lc2_counter <= 0;
				lc2_subframe_counter <= 0;
				tmp_offset_select <= 0;
				
				tmp_slice_vector <= (others=> '0');
				
				
				reshift_tmp_a <= (others=> '0');
				reshift_tmp_b <= (others=> '0');
				
				tmp_aux_lc24 <= (others=>'0');
				tmp_aux_lc25 <= (others=>'0');
				
				ram_to_fifo_ack_100M <= '0';
				ram_to_fifo_ack_cnt <= 0;
				
			else
			
				--Let's wait for the signal coming from process 1
				if P2_State = WaitData and P2_SubState = 0 and ram_to_fifo_start_100M_zz = '1' and ram_to_fifo_ack_cnt = 0 then
					
					--we need to wait a bit, because this process runs faster then P1, therefore we wait 4 cycles to indicate the acknowledge
					ram_to_fifo_ack_100M <= '1';
					ram_to_fifo_ack_cnt  <= 3;
		
					P2_SubState <= 1;
					
				
				--let's signal the acknowledge and check if we need to start reorder process or not depending on sample-rate
				elsif P2_State = WaitData and P2_SubState = 1 then
					ram_to_fifo_ack_cnt <= ram_to_fifo_ack_cnt - 1;
					
					if (ram_to_fifo_ack_cnt = 1) then
					
						ram_to_fifo_ack_100M <= '0';
						
						if (fs_mode_i = "01") then
							P2_State <= RamReorder;
							P2_SubState <= 0;
						elsif (fs_mode_i = "00") then
							P2_State <= AudioToFifo;
							P2_SubState <= 0;
						end if;
						
						lc2_counter <= 0;
						lc2_subframe_counter <= 0;
						
					end if;
					
					
				--Ram Reorder Process -> only needed for 48k mode
				
				--read out manually word 10	
				elsif P2_State = RamReorder and P2_SubState = 0 then	
					lc_ram_di_b_we <= '0';
					
					P2_SubState <= 1;
					
				elsif P2_State = RamReorder and P2_SubState = 1 then		
					
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + 10;
					
					P2_SubState <= 2;
				
				--and read out manually word 9 and we also need to wait dummy cycle for readback of word 10			
				elsif P2_State = RamReorder and P2_SubState = 2 then
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + 9;
					
					P2_SubState <= 3;
				
				--readback of word 10
				elsif P2_State = RamReorder and P2_SubState = 3 then
					reshift_tmp_a <= lc_ram_do_b; --word 10 in a
					
					P2_SubState <= 4;
					
				--readback of word 9 and save back sub-slice 11
				elsif P2_State = RamReorder and P2_SubState = 4 then
					reshift_tmp_b <= lc_ram_do_b; --word 9 in b
					
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + 11;
					lc_ram_di_b <= "000" & reshift_tmp_a (27 downto 0) & lc_ram_do_b(31);
					lc_ram_di_b_we <= '1';
					
					P2_SubState <= 5;
					
				--save back sub-slice 10
				elsif P2_State = RamReorder and P2_SubState = 5 then
				
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + 10;
					lc_ram_di_b <= "000" & reshift_tmp_b (30 downto 2);
					lc_ram_di_b_we <= '1';
					
					P2_SubState <= 6;
				
				--disable write-enable of RAM and set subframe-counter to 9 as we start looping now
				elsif P2_State = RamReorder and P2_SubState = 6 then
					lc_ram_di_b_we <= '0';
					lc2_subframe_counter <= 9;
					
					P2_SubState <= 7;
				
				--readback subframecounter and subframecounter-1
				elsif P2_State = RamReorder and P2_SubState = 7 then
					lc_ram_di_b_we <= '0';
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + lc2_subframe_counter;
					
					P2_SubState <= 8;
					
				elsif P2_State = RamReorder and P2_SubState = 8 then
					if (lc2_subframe_counter>0) then
						lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + (lc2_subframe_counter - 1);
					end if;
					
					P2_SubState <= 9;
				
				--save back the two words
				elsif P2_State = RamReorder and P2_SubState = 9 then
					reshift_tmp_a <= lc_ram_do_b;
					
					P2_SubState <= 10;
					
				elsif P2_State = RamReorder and P2_SubState = 10 then
					reshift_tmp_b <= lc_ram_do_b;
					
					P2_SubState <= 11;	
					
					--timing optimization -> see original below
					if (lc2_subframe_counter > 0) then
						tmp_offset_select <= (9-lc2_subframe_counter)*3;
					end if;
					
				--and now reshift and write back to ram
				elsif P2_State = RamReorder and P2_SubState = 11 then
					if (lc2_subframe_counter > 0) then
						--lc_ram_di_b <= "000" & reshift_tmp_a (1 + (9-lc2_subframe_counter)*3 downto 0) & reshift_tmp_b (31 downto 5 + (9-lc2_subframe_counter)*3);
						lc_ram_di_b <= "000" & reshift_tmp_a (1 + tmp_offset_select  downto 0) & reshift_tmp_b (31 downto 5 + tmp_offset_select);
						
					else
						-- special condition 0
						lc_ram_di_b <= "000" & reshift_tmp_a (28 downto 0);
					end if;
					
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + lc2_subframe_counter;
					lc_ram_di_b_we <= '1';
					
					--if there is still to process...
					if (lc2_subframe_counter > 0) then
						lc2_subframe_counter <= lc2_subframe_counter - 1;
						P2_SubState <= 7;
					else
						--check if we have all channels, if now, start from beginning
						if (lc2_counter < 23) then
							lc2_counter <= lc2_counter + 1;
							P2_SubState <= 0; 
							
						else
							-- finished
							P2_SubState <= 12;
						end if;
						
					end if;
					
				elsif P2_State = RamReorder and P2_SubState = 12 then
					lc_ram_di_b_we <= '0';
					lc2_counter <= 0;
					lc2_subframe_counter <= 0;
					
					P2_State <= AudioToFifo;
					P2_SubState <= 0;
					
				
				
				--AudioToFifo Process
				
				--start copy audio to fifos	
				elsif P2_State = AudioToFifo and P2_SubState = 0 then
				
					P2_SubState <= 1;
					
				elsif P2_State = AudioToFifo and P2_SubState = 1 then
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + lc2_subframe_counter;
					
					P2_SubState <= 2;
					
				elsif P2_State = AudioToFifo and P2_SubState = 2 then
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + lc2_subframe_counter+1;
					
					P2_SubState <= 3;
					
				elsif P2_State = AudioToFifo and P2_SubState = 3 then				
					if (fs_mode_i = "01") then
						tmp_slice_vector(28 downto 0) <= lc_ram_do_b (28 downto 0);		
					elsif (fs_mode_i = "00") then
						tmp_slice_vector(31 downto 0) <= lc_ram_do_b;
					end if;
					P2_SubState <= 4;
				
				elsif P2_State = AudioToFifo and P2_SubState = 4 then
					
					if (fs_mode_i = "01") then
						tmp_slice_vector(57 downto 29) <= lc_ram_do_b (28 downto 0);	
					else
						tmp_slice_vector(63 downto 32) <= lc_ram_do_b;
					end if;
					P2_SubState <= 5;
					
				elsif P2_State = AudioToFifo and P2_SubState = 5 then
					
					--always mark the sample from ch0 with an additional '1' in the FIFO to check FIFO-stream integrity
					if (lc2_counter = 0) then
						audio_fifo_in <= tmp_sample_a & "1";
					else
						audio_fifo_in <= tmp_sample_a & "0";
					end if;
					
					audio_fifo_in_wr_en <= '1';
					
					P2_SubState <= 6;
					
				elsif P2_State = AudioToFifo and P2_SubState = 6 then
					
					audio_fifo_in <= tmp_sample_b & "0";
					audio_fifo_in_wr_en <= '1';
					
					P2_SubState <= 7;			
				
				elsif P2_State = AudioToFifo and P2_SubState = 7 then			
					audio_fifo_in_wr_en <= '0';
					
					if lc2_counter < 23 then
						lc2_counter <= lc2_counter + 1;
						P2_SubState <= 0;					
					else
						lc2_counter <= 0;
						
						if (fs_mode_i = "01" and lc2_subframe_counter < 10) or (fs_mode_i = "00" and lc2_subframe_counter < 20) then
							lc2_subframe_counter <= lc2_subframe_counter + 2;
							P2_SubState <= 0;	
												
						else
						
							lc2_subframe_counter <= 0;
							lc2_counter <= 24;
							P2_State <= AuxToFifo;
							P2_SubState <= 0;
						end if;					
					
					end if;
					
				
					
				--start copy aux to fifos	

				--init read of lc24
				elsif P2_State = AuxToFifo and P2_SubState = 0 then		
					lc2_counter <= 25;
					P2_SubState <= 1;
					
				elsif P2_State = AuxToFifo and P2_SubState = 1 then		
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + lc2_subframe_counter;	
					
					
					P2_SubState <= 2;	
					
				--init read of lc25
				elsif P2_State = AuxToFifo and P2_SubState = 2 then	
					lc_ram_b_addr <= lc_fifo_pingpong*704 + encoded_block_no*22 + lc2_subframe_counter;
					
					P2_SubState <= 3;
				
				--save readback of lc24
				elsif P2_State = AuxToFifo and P2_SubState = 3 then		
					tmp_aux_lc24 <= lc_ram_do_b;					
					P2_SubState <= 4;
					
				--save readback of lc25
				elsif P2_State = AuxToFifo and P2_SubState = 4 then	
					tmp_aux_lc25 <= lc_ram_do_b;				

					P2_SubState <= 5;	

				--write first 16-bit word to fifo
				elsif P2_State = AuxToFifo and P2_SubState = 5 then	
					if (lc2_subframe_counter = 0 or lc2_subframe_counter = 11) then
						aux_fifo_in <= tmp_aux_vector(15 downto 0) & "1";
					else
						aux_fifo_in <= tmp_aux_vector(15 downto 0) & "0";
					end if;
					aux_fifo_in_wr_en <= '1';
					
					P2_SubState <= 6;	

				--write second 16-bit word to fifo					
				elsif P2_State = AuxToFifo and P2_SubState = 6 then
					aux_fifo_in <= tmp_aux_vector(31 downto 16) & "0";					
			
					P2_SubState <= 7;
				
				--write third 16-bit word to fifo
				elsif P2_State = AuxToFifo and P2_SubState = 7 then
					aux_fifo_in <= tmp_aux_vector(47 downto 32) & "0";
					
					P2_SubState <= 8;
					
				--write fourth 16-bit word to fifo			
				elsif P2_State = AuxToFifo and P2_SubState = 8 then
					aux_fifo_in <= tmp_aux_vector(63 downto 48) & "0";
					
					P2_SubState <= 9;
					
				
				--disable fifo-write, check if we are through or we need to loop. Jump back to wait-data state if finished
				elsif P2_State = AuxToFifo and P2_SubState = 9 then
					aux_fifo_in_wr_en <= '0';

					if (fs_mode_i = "01" and lc2_subframe_counter < 10) or (fs_mode_i = "00" and lc2_subframe_counter < 21) then
						lc2_subframe_counter <= lc2_subframe_counter + 1;
						lc2_counter <= 24;
						P2_SubState <= 0;						
					else
						--finish
						P2_State <= WaitData;
						P2_SubState <= 0;
					end if;					
			
				end if;
				
			end if;
			
		end if;
	end process;

lc_ram : entity work.aes50_dual_port_bram (rtl)
	generic map(
		RAM_WIDTH 		=> 32,
		RAM_DEPTH 		=> 1408	-- 2* (pingpong) x 32*encoded-blocks x 22*subslices (max in 44k1 mode; only) - pingpong offset = 704
	)
	port map(
		clka_i 			=> clk50_ethernet_i,
		clkb_i 			=> clk100_core_i,
		ena_i 			=> '1',
		enb_i 			=> '1',
		wea_i 			=> lc_ram_di_a_we,
		web_i 			=> lc_ram_di_b_we,
		addra_i 		=> lc_ram_a_addr,
		addrb_i 		=> lc_ram_b_addr,
		da_i 			=> lc_ram_di_a,
		db_i 			=> lc_ram_di_b,
		da_o 			=> open,
		db_o 			=> lc_ram_do_b
	);


	
audio_in_buffer : entity work.aes50_ring_buffer(rtl)
	generic map (
		RAM_WIDTH 		=> 24+1,	-- actually 24-bit sample + 1 bit CH0-indicator
		RAM_DEPTH 		=> 1056		-- 2* blocks with 11*samples * 48 channels (considered worst case in 44k1 mode)
	)
	port map (
		clk_i 			=> clk100_core_i,
		rst_i 			=> rst_i,
		wr_en_i 		=> audio_fifo_in_wr_en,
		wr_data_i 		=> audio_fifo_in,
		rd_en_i 		=> audio_out_rd_en_i,
		rd_valid_o 		=> open,
		rd_data_o 		=> audio_fifo_out,
		empty_o 		=> fifo_debug_o(0),
		empty_next_o 	=> open,
		full_o 			=> fifo_debug_o(1),
		full_next_o 	=> open,
		fill_count_o 	=> fifo_fill_count_audio_o
	);
					
aux0_data_buffer : entity work.aes50_ring_buffer(rtl)
	generic map (
		RAM_WIDTH 		=> 16+1,	--actually 16-bit word + 1 bit start indicator (used for data-descrambler reset later)
		RAM_DEPTH 		=> 176		-- 2* blocks with 88* aux-data-words (considered worst case in 44k1 mode)
	)
	port map (
		clk_i 			=> clk100_core_i,
		rst_i 			=> rst_i,
		wr_en_i 		=> aux_fifo_in_wr_en,
		wr_data_i 		=> aux_fifo_in,
		rd_en_i 		=> aux0_out_rd_en_i,
		rd_valid_o 		=> open,
		rd_data_o 		=> aux0_fifo_out,
		empty_o 		=> fifo_debug_o(2),
		empty_next_o 	=> open,
		full_o 			=> fifo_debug_o(3),
		full_next_o 	=> open,
		fill_count_o 	=> fifo_fill_count_aux0_o
	);
					
aux1_data_buffer : entity work.aes50_ring_buffer(rtl)
	generic map (
		RAM_WIDTH 		=> 16+1,	--actually 16-bit word + 1 bit start indicator (used for data-descrambler reset later)
		RAM_DEPTH 		=> 176		-- 2* blocks with 88* aux-data-words (considered worst case in 44k1 mode)
	)
	port map (
		clk_i 			=> clk100_core_i,
		rst_i 			=> rst_i,
		wr_en_i 		=> aux_fifo_in_wr_en,
		wr_data_i 		=> aux_fifo_in,
		rd_en_i 		=> aux1_out_rd_en_i,
		rd_valid_o 		=> open,
		rd_data_o 		=> aux1_fifo_out,
		empty_o 		=> open,
		empty_next_o 	=> open,
		full_o 			=> open,
		full_next_o 	=> open,
		fill_count_o 	=> fifo_fill_count_aux1_o
	);
								


end architecture;