-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_rx.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Co-Author	: Chris Nöding (implemented modifications for better synthesis on original X32 FPGA platforms)
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
			
			fifo_fill_count_audio_o 	: out natural range 0 to 1056 - 1;
			fifo_fill_count_aux0_o 		: out natural range 0 to 176 - 1;
			fifo_fill_count_aux1_o 		: out natural range 0 to 176 - 1;	
			
			eth_rx_data_i         		: in std_logic_vector(7 downto 0);
			eth_rx_sof_i          		: in std_logic;
			eth_rx_eof_i          		: in std_logic;
			eth_rx_valid_i        		: in std_logic;
			
			eth_rx_dv_i					: in std_logic;
				
			fifo_debug_o				: out std_logic_vector(3 downto 0)
			
			);
			
end aes50_rx;

architecture rtl of aes50_rx is
	
	function lc_ram_addr(pingpong  : natural; enc_block : natural; subframe  : natural) return natural is
    begin
        return pingpong * 704 + enc_block * 22 + subframe;
    end function;
	
	
	--FIFO Interconnects
	
	--audio fifo
	signal	audio_fifo_in					: std_logic_vector (24 downto 0);
	signal 	audio_fifo_in_wr_en				: std_logic;
	signal  audio_fifo_out					: std_logic_vector(24 downto 0);
	
	--aux fifo
	signal 	aux_fifo_in						: std_logic_vector (16 downto 0);	
	signal 	aux_fifo_in_wr_en				: std_logic;
	signal 	aux0_fifo_out					: std_logic_vector(16 downto 0);
	signal 	aux1_fifo_out					: std_logic_vector(16 downto 0);
	
	--RAM signals
	
	--port A (50 MHz P1 side)
	signal 	lc_ram_di_a						: std_logic_vector (31 downto 0);
	signal 	lc_ram_a_addr					: natural range 0 to 1408-1;
	signal 	lc_ram_di_a_we					: std_logic;
	
	
	--port B (100 MHz P2 side)
	signal 	lc_ram_di_b						: std_logic_vector (31 downto 0);
	signal  lc_ram_b_addr					: natural range 0 to 1408-1;
	signal 	lc_ram_di_b_we					: std_logic;
	signal 	lc_ram_do_b						: std_logic_vector (31 downto 0);
	
	
	
	--P1 (Process 1) variables
	
	signal reset50M_z						: std_logic;
	signal reset50M_zz						: std_logic;
	
	type t_State_p1 is (WaitData, HeaderOrData, WaitFifoProcessHandshake);
    signal P1_State 						: t_State_p1;
	signal lc_pingpong						: natural range 0 to 1;
	
	--edge detectors
	signal eth_rx_dv_edge					: std_logic_vector (1 downto 0);
	
	--Counter variables
	signal lc_counter						: natural range 0 to 31;
	signal lc_subframe_counter				: natural range 0 to 31;
	signal rx_byte_counter					: natural range 0 to 1500;
	signal rx_round_44k1					: natural range 0 to 1;
	
	--Temp variables
	signal tmp_rx_word						: std_logic_vector (31 downto 0);
	signal tmp_rx_byte_counter				: natural range 0 to 3;
	signal found_assm_sync					: std_logic;
	
	--handshake signals
	signal ram_to_fifo_start_50M			: std_logic;
	signal ram_to_fifo_ack_50M_z			: std_logic;
	signal ram_to_fifo_ack_50M_zz 			: std_logic;
	

	
	--P2 (Process 2) variables

	type t_State_p2 is (WaitData, RamReorder, AudioToFifo, AuxToFifo);
    signal P2_State : t_State_p2;
	signal P2_SubState						: natural range 0 to 31;
	
	signal lc_pingpong_50M         			: natural range 0 to 1;   
    signal lc_pingpong_100M_z      			: natural range 0 to 1;      
    signal lc_pingpong_100M_zz     			: natural range 0 to 1;   
	
	--Counter variables
	signal lc2_counter						: natural range 0 to 31; 
	signal lc2_subframe_counter				: natural range 0 to 31; 
	signal encoded_block_no					: natural range 0 to 31; 
	signal tmp_offset_select				: natural range 0 to 24;
	
	--Temp Variables
	signal reshift_tmp_a					: std_logic_vector(31 downto 0);
	signal reshift_tmp_b					: std_logic_vector(31 downto 0);

	--handshake signals
	signal ram_to_fifo_start_100M_z			: std_logic; 
	signal ram_to_fifo_start_100M_zz		: std_logic;
	signal ram_to_fifo_ack_100M				: std_logic;
	signal ram_to_fifo_ack_cnt				: natural range 0 to 3;
	

	signal tmp_sample_a						: std_logic_vector(23 downto 0);
	signal tmp_sample_b						: std_logic_vector(23 downto 0);
	signal tmp_aux_lc24						: std_logic_vector(31 downto 0);
	signal tmp_aux_lc25						: std_logic_vector(31 downto 0);
	signal tmp_aux_vector					: std_logic_vector(63 downto 0);
	signal tmp_slice_vector					: std_logic_vector (63 downto 0);
	
	
	
	
begin


	audio_o 			<= audio_fifo_out(24 downto 1);
	audio_ch0_marker_o 	<= audio_fifo_out(0);
	
	aux0_o 				<= aux0_fifo_out(16 downto 1);
	aux0_start_marker_o <= aux0_fifo_out(0);
	
	aux1_o 				<= aux1_fifo_out(16 downto 1);
	aux1_start_marker_o <= aux1_fifo_out(0);

		
	process(tmp_aux_lc25, tmp_aux_lc24)
	begin
		for i in 0 to 31 loop
			tmp_aux_vector(2*i + 1) <= tmp_aux_lc25(i);
			tmp_aux_vector(2*i)     <= tmp_aux_lc24(i);
		end loop;
	end process;	

	--FIX: Feb 25th 2026 
	--see comment in aes50-tx module where the muxed-slice-vector is generated.
	--The reconsutrction of tmp_sample_a in 48k mode needs to follow the same bit-pattern.	
		
	process (tmp_slice_vector, fs_mode_i)
		variable offset : integer;
	begin
		tmp_sample_a <= (others => '0');
		tmp_sample_b <= (others => '0');

		if (fs_mode_i = "01" or fs_mode_i = "00") then
			if fs_mode_i = "01" then
				offset := 2;
			else -- fs_mode_i = "00"
				offset := 5;
			end if;

			for i in 0 to 12 loop
				tmp_sample_a(23 - i) <= tmp_slice_vector(2*i);
				tmp_sample_b(23 - i) <= tmp_slice_vector(2*i + 1);
			end loop;

			if fs_mode_i = "00" then				
				tmp_sample_a(10) <= tmp_slice_vector(26);  
				tmp_sample_b(10) <= tmp_slice_vector(32);  
				for i in 14 to 23 loop
					tmp_sample_a(23 - i) <= tmp_slice_vector(2*i + offset);
					tmp_sample_b(23 - i) <= tmp_slice_vector(2*i + 1 + offset);
				end loop;
			else
            
				for i in 13 to 23 loop
					tmp_sample_a(23 - i) <= tmp_slice_vector(2*i + offset);
					tmp_sample_b(23 - i) <= tmp_slice_vector(2*i + 1 + offset);
				end loop;
			end if;
		end if;
	end process;

    process(clk100_core_i)
    begin
        if rising_edge(clk100_core_i) then
            case lc2_counter is
                when 0  to 14 => encoded_block_no <= lc2_counter;
                when 15 to 21 => encoded_block_no <= lc2_counter + 1;
                when 22 to 24 => encoded_block_no <= lc2_counter + 2;
                when 25       => encoded_block_no <= lc2_counter + 3;
                when others   => encoded_block_no <= 0;
            end case;
        end if;
    end process;

	process(clk50_ethernet_i)
	begin
		if rising_edge(clk50_ethernet_i) then
		
			--resync signals from 100M->50M clock where necessary
			reset50M_z 	<= rst_i;
			reset50M_zz <= reset50M_z;		
			
			ram_to_fifo_ack_50M_z 	<= ram_to_fifo_ack_100M;
			ram_to_fifo_ack_50M_zz 	<= ram_to_fifo_ack_50M_z;
			
			
			eth_rx_dv_edge <= eth_rx_dv_edge(0) & eth_rx_dv_i;
			
			-- write-enable inactive unless explicitly asserted below
            lc_ram_di_a_we 	<= '0';
			assm_detect_o   <= '0';
			
			if reset50M_zz = '1' or eth_rx_dv_edge = "01" then
				
                assm_detect_o       		<= '0';
                lc_ram_di_a         		<= (others => '0');
                lc_ram_a_addr       		<= 0;
                lc_counter          		<= 0;
                lc_subframe_counter 		<= 0;
				-- let's start with 8 in here, because the official spec counts the data-offsets starting from preamble... However our ethernet controller starts giving us data when preamble and SFD have finished
				rx_byte_counter 			<= 8; 
                tmp_rx_word         		<= (others => '0');
                tmp_rx_byte_counter 		<= 0;
                ram_to_fifo_start_50M 		<= '0';
				
				--only when reset
				if reset50M_zz = '1'then
                    P1_State                <= WaitData;
                    lc_pingpong             <= 0;
                    lc_pingpong_50M    		<= 0;
                    fs_mode_detect_o        <= (others => '0');
                    fs_mode_detect_valid_o  <= '0';
                    found_assm_sync         <= '0';
                    rx_round_44k1           <= 0;				
				else
					P1_State 				<= HeaderOrData;
				end if;
				
			else
			
				--Receive process everytime a new byte arrived from Ethernet....
				case P1_State is
					when WaitData => 
						null; -- wait for dv rising edge (handled above)
						
					when HeaderOrData =>
						if eth_rx_valid_i = '1' then
						
							case rx_byte_counter is
								--Header part
								when 8 to 21 =>	
									-- dest & src mac address / ethertype  -> we don't need this information
									null;
							
								when 22 to 23 =>
									-- protocol ID & user octet ... don't care at the moment.. 
									-- at least from protocol sniffing with wire-shark it seems it is used for something as the logging showed varying information on this byte.. 
									-- However there's no specific meaning just from the spec itself
									null;							
							
								when 25  =>
								
									--check for ASSM flag									
									if eth_rx_data_i = x"11" then
										assm_detect_o   <= '1';
										found_assm_sync <= '1';
										rx_round_44k1   <= 0;
									end if;
								
								
								when 26  =>
									case eth_rx_data_i is
										when x"46" =>
											fs_mode_detect_o       <= "01";  -- 48 kHz
											fs_mode_detect_valid_o <= '1';
										when x"06" =>
											fs_mode_detect_o       <= "00";  -- 44.1 kHz
											fs_mode_detect_valid_o <= '1';
										when others =>
											null;
									end case;
									


							--Data part
								when 30 to 1437 =>
									-- actual data coming
									case tmp_rx_byte_counter is
									
										when 0 =>
											tmp_rx_word <= tmp_rx_word(31 downto 8) & eth_rx_data_i;
											tmp_rx_byte_counter <= 1;
											
										when 1 =>
											tmp_rx_word <= tmp_rx_word (31 downto 16) & eth_rx_data_i & tmp_rx_word(7 downto 0);
											tmp_rx_byte_counter <= 2;
											
										when 2 =>
											tmp_rx_word <= tmp_rx_word (31 downto 24) & eth_rx_data_i & tmp_rx_word(15 downto 0);
											tmp_rx_byte_counter <= 3;
											
										when others =>  -- 3: word complete 
											lc_ram_di_a <=  eth_rx_data_i & tmp_rx_word(23 downto 0);
											lc_ram_di_a_we <= '1';
											
											if fs_mode_i = "00" and rx_round_44k1 = 1 then
												lc_ram_a_addr <= lc_ram_addr(lc_pingpong, lc_counter, lc_subframe_counter) + 11;
											else
												lc_ram_a_addr <= lc_ram_addr(lc_pingpong, lc_counter, lc_subframe_counter);
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
																					
														P1_State 			<= WaitFifoProcessHandshake;
														rx_round_44k1 		<= 0;
														
														
														ram_to_fifo_start_50M <= '1';
														
														if (lc_pingpong = 0) then
															lc_pingpong_50M <= 0;
															lc_pingpong <= 1;
														else
															lc_pingpong_50M <= 1;
															lc_pingpong <= 0;
														end if;
														
													elsif (fs_mode_i = "00" and rx_round_44k1 = 0 and found_assm_sync = '1') then
														P1_State <= WaitData;
														rx_round_44k1 <= 1;
													end if;										
														
												end if;
											end if;
											
											tmp_rx_byte_counter <= 0;									
									end case; 
									
								when others =>  null;
							end case;  -- rx_byte_counter
							rx_byte_counter <= rx_byte_counter + 1;
						end if;
						
									
					when WaitFifoProcessHandshake =>
						
						if (ram_to_fifo_ack_50M_zz = '1') then
							ram_to_fifo_start_50M 	<= '0';
							P1_State 				<= WaitData;
						end if;
					
					when others => null;
				end case;  -- P1_State
			
			end if;
		end if;
			
			
	end process;		


	process(clk100_core_i)
	begin
		if rising_edge(clk100_core_i) then
		
			--resync signals from 50M->100M clock where necessary
			ram_to_fifo_start_100M_z 	<= ram_to_fifo_start_50M;
			ram_to_fifo_start_100M_zz 	<= ram_to_fifo_start_100M_z;
			
			lc_pingpong_100M_z    		<= lc_pingpong_50M;
            lc_pingpong_100M_zz   		<= lc_pingpong_100M_z;
			
			lc_ram_di_b_we    			<= '0';
            audio_fifo_in_wr_en 		<= '0';
            aux_fifo_in_wr_en   		<= '0';


			if rst_i = '1' then
			
                P2_State             <= WaitData;
                P2_SubState          <= 0;
                lc_ram_di_b          <= (others => '0');
                lc_ram_b_addr        <= 0;
                lc2_counter          <= 0;
                lc2_subframe_counter <= 0;
                tmp_offset_select    <= 0;
                tmp_slice_vector     <= (others => '0');
                reshift_tmp_a        <= (others => '0');
                reshift_tmp_b        <= (others => '0');
                tmp_aux_lc24         <= (others => '0');
                tmp_aux_lc25         <= (others => '0');
                ram_to_fifo_ack_100M <= '0';
                ram_to_fifo_ack_cnt  <= 0;
				
			else
			
				--Let's wait for the signal coming from process 1
				case P2_State is
				
					when WaitData =>
						case P2_SubState is
							when 0 =>
								if ram_to_fifo_start_100M_zz = '1' and ram_to_fifo_ack_cnt = 0 then
									--we need to wait a bit, because this process runs faster then P1, therefore we wait 4 cycles to indicate the acknowledge
									ram_to_fifo_ack_100M <= '1';
									ram_to_fifo_ack_cnt  <= 3;					
									P2_SubState <= 1;
								end if;
							
							--let's signal the acknowledge and check if we need to start reorder process or not depending on sample-rate
							when 1 =>
								ram_to_fifo_ack_cnt <= ram_to_fifo_ack_cnt - 1;	
								
								if (ram_to_fifo_ack_cnt = 1) then							
									ram_to_fifo_ack_100M <= '0';
									lc2_counter <= 0;
									lc2_subframe_counter <= 0;
									
									case fs_mode_i is
										when "01"   => P2_State <= RamReorder;
										when "00"   => P2_State <= AudioToFifo;
										when others => null;
									end case;
									P2_SubState <= 0;									
									
								end if;
							when others => null;
						end case;
					--Ram Reorder Process -> only needed for 48k mode
					
					--read out manually word 10	
					when RamReorder =>
						case P2_SubState is
						
							when 0 =>							
								P2_SubState <= 1;
								
							when 1 =>								
								lc_ram_b_addr <= lc_ram_addr(lc_pingpong_100M_zz, encoded_block_no, 10);
								P2_SubState <= 2;
							
							--and read out manually word 9 and we also need to wait dummy cycle for readback of word 10			
							when 2 =>
								lc_ram_b_addr <= lc_ram_addr(lc_pingpong_100M_zz, encoded_block_no, 9);
								P2_SubState <= 3;
							
							--readback of word 10
							when 3 =>
								reshift_tmp_a <= lc_ram_do_b; --word 10 in a
								
								P2_SubState <= 4;
								
							--readback of word 9 and save back sub-slice 11
							when 4 =>
								reshift_tmp_b <= lc_ram_do_b; --word 9 in b							
								lc_ram_b_addr <= lc_ram_addr(lc_pingpong_100M_zz,  encoded_block_no, 11);
								lc_ram_di_b <= "000" & reshift_tmp_a (27 downto 0) & lc_ram_do_b(31);
								lc_ram_di_b_we <= '1';
								
								P2_SubState <= 5;
								
							--save back sub-slice 10
							when 5 =>
							
								lc_ram_b_addr  <= lc_ram_addr(lc_pingpong_100M_zz,encoded_block_no, 10);
								lc_ram_di_b <= "000" & reshift_tmp_b (30 downto 2);
								lc_ram_di_b_we <= '1';
								
								P2_SubState <= 6;
							
							--disable write-enable of RAM and set subframe-counter to 9 as we start looping now
							when 6 =>
								lc2_subframe_counter <= 9;							
								P2_SubState <= 7;
							
							--readback subframecounter and subframecounter-1
							when 7 =>
								lc_ram_b_addr <= lc_ram_addr(lc_pingpong_100M_zz,encoded_block_no, lc2_subframe_counter);
								
								P2_SubState <= 8;
								
							when 8 =>
								if lc2_subframe_counter > 0 then
									lc_ram_b_addr <= lc_ram_addr(lc_pingpong_100M_zz,encoded_block_no, lc2_subframe_counter) - 1;
								end if;
								
								P2_SubState <= 9;
							
							--save back the two words
							when 9 =>
								reshift_tmp_a <= lc_ram_do_b;
								
								P2_SubState <= 10;
								
							when 10 =>
								reshift_tmp_b <= lc_ram_do_b;			
								
								--timing optimization -> see original below
								if (lc2_subframe_counter > 0) then
									tmp_offset_select <= (9-lc2_subframe_counter)*3;
								end if;
								
								P2_SubState <= 11;
								
							--and now reshift and write back to ram
							when 11 =>
								if (lc2_subframe_counter > 0) then
									--lc_ram_di_b <= "000" & reshift_tmp_a (1 + (9-lc2_subframe_counter)*3 downto 0) & reshift_tmp_b (31 downto 5 + (9-lc2_subframe_counter)*3);
									lc_ram_di_b <= "000" & reshift_tmp_a (1 + tmp_offset_select  downto 0) & reshift_tmp_b (31 downto 5 + tmp_offset_select);
									
								else
									-- special condition 0
									lc_ram_di_b <= "000" & reshift_tmp_a (28 downto 0);
								end if;
								
								lc_ram_b_addr  <= lc_ram_addr(lc_pingpong_100M_zz,encoded_block_no, lc2_subframe_counter);
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
								
							when 12 =>								
								lc2_counter <= 0;
								lc2_subframe_counter <= 0;
								
								P2_State <= AudioToFifo;
								P2_SubState <= 0;
								
							when others => null;
                        end case;
					
					
					--AudioToFifo Process
					
					--start copy audio to fifos	
					when AudioToFifo =>
						case P2_SubState is
							when 0 =>
							
								P2_SubState <= 1;
								
							when 1 =>
								lc_ram_b_addr <= lc_ram_addr(lc_pingpong_100M_zz,encoded_block_no, lc2_subframe_counter);
								
								P2_SubState <= 2;
								
							when 2 =>
								lc_ram_b_addr <= lc_ram_addr(lc_pingpong_100M_zz, encoded_block_no, lc2_subframe_counter) + 1;
								
								P2_SubState <= 3;
								
							when 3 =>			
								 case fs_mode_i is
									when "01"   => tmp_slice_vector(28 downto 0)  <= lc_ram_do_b(28 downto 0);
									when "00"   => tmp_slice_vector(31 downto 0)  <= lc_ram_do_b;
									when others => null;
								end case;
								
								P2_SubState <= 4;
							
							
							when 4 =>								
								case fs_mode_i is
									when "01"   => tmp_slice_vector(57 downto 29) <= lc_ram_do_b(28 downto 0);
									when "00"   => tmp_slice_vector(63 downto 32) <= lc_ram_do_b;
									when others => null;
								end case;
								
								P2_SubState <= 5;
								
							when 5 =>
								
								--always mark the sample from ch0 with an additional '1' in the FIFO to check FIFO-stream integrity
								if (lc2_counter = 0) then
									audio_fifo_in <= tmp_sample_a & "1";
								else
									audio_fifo_in <= tmp_sample_a & "0";
								end if;							
								audio_fifo_in_wr_en <= '1';
								
								P2_SubState <= 6;
								
							when 6 =>
								
								audio_fifo_in <= tmp_sample_b & "0";
								audio_fifo_in_wr_en <= '1';
								
								P2_SubState <= 7;			
							
							when 7 =>			
															
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
							when others => null;
                        end case;
					
						
					--start copy aux to fifos	

					--init read of lc24
					when AuxToFifo =>
						case P2_SubState is
							when 0 =>	
								lc2_counter <= 25;
								P2_SubState <= 1;
								
							when 1 =>	
								lc_ram_b_addr <= lc_ram_addr(lc_pingpong_100M_zz, encoded_block_no, lc2_subframe_counter);
								P2_SubState <= 2;	
								
							--init read of lc25
							when 2 =>
								lc_ram_b_addr <= lc_ram_addr(lc_pingpong_100M_zz, encoded_block_no, lc2_subframe_counter);
								P2_SubState <= 3;
							
							--save readback of lc24
							when 3 =>		
								tmp_aux_lc24 <= lc_ram_do_b;					
								P2_SubState <= 4;
								
							--save readback of lc25
							when 4 =>
								tmp_aux_lc25 <= lc_ram_do_b;	
								P2_SubState <= 5;	

							--write first 16-bit word to fifo
							when 5 =>	
								if (lc2_subframe_counter = 0 or lc2_subframe_counter = 11) then
									aux_fifo_in <= tmp_aux_vector(15 downto 0) & "1";
								else
									aux_fifo_in <= tmp_aux_vector(15 downto 0) & "0";
								end if;
								aux_fifo_in_wr_en <= '1';
								
								P2_SubState <= 6;	

							--write second 16-bit word to fifo					
							when 6 =>
								aux_fifo_in <= tmp_aux_vector(31 downto 16) & "0";					
								aux_fifo_in_wr_en <= '1';
								P2_SubState <= 7;
							
							--write third 16-bit word to fifo
							when 7 =>
								aux_fifo_in <= tmp_aux_vector(47 downto 32) & "0";
								aux_fifo_in_wr_en <= '1';
								P2_SubState <= 8;
								
							--write fourth 16-bit word to fifo			
							when 8 =>
								aux_fifo_in <= tmp_aux_vector(63 downto 48) & "0";
								aux_fifo_in_wr_en <= '1';
								P2_SubState <= 9;
								
							
							--disable fifo-write, check if we are through or we need to loop. Jump back to wait-data state if finished
							when 9 =>							
								if (fs_mode_i = "01" and lc2_subframe_counter < 10) or (fs_mode_i = "00" and lc2_subframe_counter < 21) then
									lc2_subframe_counter <= lc2_subframe_counter + 1;
									lc2_counter <= 24;
									P2_SubState <= 0;						
								else
									--finish
									P2_State <= WaitData;
									P2_SubState <= 0;
								end if;		
						
							when others => null;
						end case;
				
					when others => null;
				end case;
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