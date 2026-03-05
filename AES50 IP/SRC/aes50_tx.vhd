-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_tx.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Handles the transmitting side of the AES50 ethernet-data-stream; receives audio-samples and aux-data over FIFO interface, data-frame packing, bit-error-correction calculations and streaming to eth-interface
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


entity aes50_tx is
	port 	(
				clk100_core_i         		: in  std_logic; 
				clk50_ethernet_i			: in  std_logic;
				rst_i               		: in  std_logic;
				
				-- 00=>44.1k; 01->48k; 10->88.2k; -> 11->96k
				fs_mode_i          			: in std_logic_vector (1 downto 0); 
				assm_is_active_o			: out std_logic;
				
				--fifo input interface
				audio_i						: in std_logic_vector (23 downto 0);
				audio_ch0_marker_i			: in std_logic;
				aux_i						: in std_logic_vector (15 downto 0);
				audio_in_wr_en_i			: in std_logic;
				aux_in_wr_en_i				: in std_logic;
				
				audio_fifo_misalign_panic_o	: out std_logic;
				
				--phy serializer interface
				phy_tx_data_o         		: out  std_logic_vector(7 downto 0);
				phy_tx_eof_o          		: out  std_logic;
				phy_tx_valid_o        		: out  std_logic;
				phy_tx_ready_i        		: in std_logic;
				
				fifo_debug_o				: out std_logic_vector(3 downto 0)
				
				
			);
end aes50_tx;

architecture rtl of aes50_tx is

	--FIFO Interconnects
	
	--audio fifo
	signal audio_fifo_in			: std_logic_vector(24 downto 0);
	signal fill_count_audio_in 		: integer range 1056 - 1 downto 0;
	signal audio_fifo_out			: std_logic_vector(24 downto 0);
	signal audio_fifo_out_rd_en		: std_logic;
	
	--aux fifo
	signal fill_count_aux_in 		: integer range 176 - 1 downto 0;
	signal aux_fifo_out				: std_logic_vector(15 downto 0);
	signal aux_fifo_out_rd_en		: std_logic;
	
	
	
	--RAM signals
	
	--port A (100 MHz P1 side)
	signal 	lc_ram_di_a				: std_logic_vector (31 downto 0);
	signal 	lc_ram_a_addr			: integer range 1408 - 1 downto 0;	-- 2x pingpong * 32x encoded-blocks * 22x subframes 
	signal 	lc_ram_di_a_we			: std_logic;
	signal 	lc_ram_do_a				: std_logic_vector (31 downto 0);
	
	
	--port B (50 MHz P2 side)
	signal 	lc_ram_do_b				: std_logic_vector (31 downto 0);
	signal  lc_ram_b_addr			: integer range 1408 - 1 downto 0;



	--P1 (Process 1) Variables
	
	--State-Counter
	type t_State_p1 is (WaitSamples, AudioFifoToRam, AuxFifoToRam, RamReorder, ParityCalc, GlobalParity, WaitTransmit);
    signal P1_State : t_State_p1;
	signal P1_SubState				: integer range 15 downto 0;
	
	signal lc_pingpong				: integer range 1 downto 0;
	signal use_aux_fifo				: std_logic;
	
	--Counter Variables	
	signal  lc_counter				: integer range 31 downto 0;
	signal 	encoded_block_no		: integer range 31 downto 0;
	signal  lc_subframe_counter		: integer range 31 downto 0;
	signal 	aux_empty_counter		: integer range 15 downto 0;
	
	--Temp Variables
	signal tmp_sample_a				: std_logic_vector(23 downto 0);
	signal tmp_sample_b				: std_logic_vector(23 downto 0);
	signal tmp_aux_vector			: std_logic_vector(63 downto 0);
	signal tmp_aux_lc24				: std_logic_vector(31 downto 0);
	signal tmp_aux_lc25				: std_logic_vector(31 downto 0);
	signal tmp_ucm_a				: std_logic_vector(2 downto 0);
	signal tmp_ucm_b				: std_logic_vector(2 downto 0);
	signal tmp_slice_vector			: std_logic_vector(63 downto 0);
	signal reshift_tmp_a			: std_logic_vector(31 downto 0);
	signal reshift_tmp_b			: std_logic_vector(31 downto 0);
	signal parity_in_a				: std_logic_vector(31 downto 0);
	signal parity_in_b				: std_logic_vector(31 downto 0);
	signal parity_out				: std_logic_vector(31 downto 0);
	signal parity_temp				: std_logic_vector(31 downto 0);
	signal parity_counter			: integer range 7 downto 0;	
	
	--Handshake signals
	signal lc_tx_pingpong_100M			: integer range 1 downto 0;
	signal lc_tx_ready_100M						: std_logic;
	signal lc_tx_ack_100M_z, lc_tx_ack_100M_zz 	: std_logic;
	--Lookup-Tables		
	type paritylut_t is array (0 to 4, 0 to 15) of integer range 0 to 30;	
	constant par_lut: paritylut_t:=( 
						--the first 0-14 elements define which bits needs to be calculcated for parity 
						--last element defines in which location parity needs to be stored
						(0, 1, 2, 3, 4, 5, 	6, 	7, 	8, 		9, 		10, 	11, 	12 ,	13 ,	14, 	15),
                        (0, 1, 2, 3, 4, 5, 	6, 	7, 	15+1, 	16+1, 	17+1, 	18+1, 	19+1,	20+1 ,	21+1, 	23),
                        (0, 1, 2, 3, 8, 9, 	10, 11, 15+1, 	16+1, 	17+1, 	18+1, 	22+2 ,	23+2 ,	24+2, 	27),
                        (0, 1, 4, 5, 8, 9, 	12, 13, 15+1, 	16+1, 	19+1, 	20+1, 	22+2 ,	23+2 ,	25+3, 	29),
                        (0, 2, 4, 6, 8, 10, 12, 14, 15+1, 	17+1, 	19+1, 	21+1, 	22+2 ,	24+2 ,	25+3, 	30)
						);
	
	signal aux_empty_data			: std_logic_vector(352*2-1 downto 0) := "01111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110011111111100111111111001111111110";
	
	
	
	
	
	
	--P2 (Process 2) Variables
	
	--state variables
	signal reset50M_z, reset50M_zz	: std_logic;
	
	type t_State_p2 is (WaitForData, TransmitHeader, TransmitData,WaitRoundTwo);
    signal P2_State : t_State_p2;
	signal P2_SubState				: integer range 31 downto 0;
	
	--assm 
	signal assm_do					: std_logic;
	signal assm_counter				: integer range 2047 downto 0;
	
	--Variables	
	signal tx_round_44k1			: integer range 1 downto 0;
	signal tmp_ram_word				: std_logic_vector (31 downto 0);
	
	
	--Counter Variables
	signal lc2_counter				: integer range 31 downto 0;
	signal lc2_subframe_counter		: integer range 31 downto 0;
	signal wait_round_two_counter	: integer range 1000 downto 0;
	

	--Handshake Signals
	signal lc_tx_pingpong_50M_z, lc_tx_pingpong_50M_zz : integer range 1 downto 0;
	signal lc_tx_ready_50M_z, lc_tx_ready_50M_zz : std_logic;
	signal lc_tx_ack_50M				: std_logic;

	
	signal phy_tx_ready_edge		: std_logic_vector (1 downto 0);	


	
	-- mac-data frame header data
	type 	mac_addr is array(0 to 6) of std_logic_vector(7 downto 0);
	signal  mac_source				: mac_addr;
	signal  mac_dest				: mac_addr;
	
	type 	eth_t is array(0 to 1) of std_logic_vector(7 downto 0);
	signal  ether_type				: eth_t;
	
	signal protocol_identifier		: std_logic_vector (7 downto 0);
	signal user_octet				: std_logic_vector (7 downto 0);
	type   ffi_t is array(0 to 8) of std_logic_vector(7 downto 0);
	signal  frame_format_id			: ffi_t;
	
	

begin

	audio_fifo_in <= audio_i & audio_ch0_marker_i;

	process (tmp_aux_vector)
	begin
		tmp_aux_lc24 <= tmp_aux_vector (63-1) & 
						tmp_aux_vector (61-1) & 
						tmp_aux_vector (59-1) & 
						tmp_aux_vector (57-1) & 
						tmp_aux_vector (55-1) & 
						tmp_aux_vector (53-1) & 
						tmp_aux_vector (51-1) & 
						tmp_aux_vector (49-1) & 
						tmp_aux_vector (47-1) & 
						tmp_aux_vector (45-1) & 
						tmp_aux_vector (43-1) & 
						tmp_aux_vector (41-1) & 
						tmp_aux_vector (39-1) & 
						tmp_aux_vector (37-1) & 
						tmp_aux_vector (35-1) & 
						tmp_aux_vector (33-1) & 
						tmp_aux_vector (31-1) & 
						tmp_aux_vector (29-1) & 
						tmp_aux_vector (27-1) & 
						tmp_aux_vector (25-1) & 
						tmp_aux_vector (23-1) & 
						tmp_aux_vector (21-1) & 
						tmp_aux_vector (19-1) & 
						tmp_aux_vector (17-1) & 
						tmp_aux_vector (15-1) & 
						tmp_aux_vector (13-1) & 
						tmp_aux_vector (11-1) & 
						tmp_aux_vector (9-1)  & 
						tmp_aux_vector (7-1)  & 
						tmp_aux_vector (5-1)  & 
						tmp_aux_vector (3-1)  & 
						tmp_aux_vector (1-1)  ;
		
		tmp_aux_lc25 <= tmp_aux_vector (63) & 
						tmp_aux_vector (61) & 
						tmp_aux_vector (59) & 
						tmp_aux_vector (57) & 
						tmp_aux_vector (55) & 
						tmp_aux_vector (53) & 
						tmp_aux_vector (51) & 
						tmp_aux_vector (49) & 
						tmp_aux_vector (47) & 
						tmp_aux_vector (45) & 
						tmp_aux_vector (43) & 
						tmp_aux_vector (41) & 
						tmp_aux_vector (39) & 
						tmp_aux_vector (37) & 
						tmp_aux_vector (35) & 
						tmp_aux_vector (33) & 
						tmp_aux_vector (31) & 
						tmp_aux_vector (29) & 
						tmp_aux_vector (27) & 
						tmp_aux_vector (25) & 
						tmp_aux_vector (23) & 
						tmp_aux_vector (21) & 
						tmp_aux_vector (19) & 
						tmp_aux_vector (17) & 
						tmp_aux_vector (15) & 
						tmp_aux_vector (13) & 
						tmp_aux_vector (11) & 
						tmp_aux_vector (9)  & 
						tmp_aux_vector (7)  & 
						tmp_aux_vector (5)  & 
						tmp_aux_vector (3)  & 
						tmp_aux_vector (1)  ;	
							
	end process;

	--slice vector generator
	
	--FIX: Feb 25th 2026 
	--During integration into Open-X32 project, it was detected that all odd channels are showing slight distortion behavior.
	--To fix this, the position of the two padding bits in 48k mode while generating tmp_slice_vector was changed by one bit position.
	--Even though this is !!not obvious!! from specification point of view (as the first padding bits come after 26 muxed PCM-bits and the second padding-bits after 28 - instead of both being 27 as per spec) this is confirmed to work. 
	--Audio-Passthrough checked with audio-analyzer.
	
	process (tmp_sample_a, tmp_sample_b, tmp_ucm_a, tmp_ucm_b, fs_mode_i)
	begin
		if (fs_mode_i = "01") then
			--in 48k mode- 1x LC-subsegment has 29-bits - 2 bits zero-padding after each lc-subsegment; upper 6 bits not needed
			tmp_slice_vector <= 	"000000"&
									"00"&
										tmp_ucm_b(2)	&tmp_ucm_a(2)&
										tmp_ucm_b(1)	&tmp_ucm_a(1)&
										tmp_ucm_b(0)	&tmp_ucm_a(0)&
										tmp_sample_b(0)	&tmp_sample_a(0)&
										tmp_sample_b(1)	&tmp_sample_a(1)&
										tmp_sample_b(2)	&tmp_sample_a(2)&
										tmp_sample_b(3)	&tmp_sample_a(3)&
										tmp_sample_b(4)	&tmp_sample_a(4)&
										tmp_sample_b(5)	&tmp_sample_a(5)&
										tmp_sample_b(6)	&tmp_sample_a(6)&
										tmp_sample_b(7)	&tmp_sample_a(7)&
										tmp_sample_b(8)	&tmp_sample_a(8)&
										tmp_sample_b(9)	&tmp_sample_a(9)&
										tmp_sample_b(10)&tmp_sample_a(10)&
										
									"00"&
										tmp_sample_b(11)&
										tmp_sample_a(11)&tmp_sample_b(12)&
										tmp_sample_a(12)&tmp_sample_b(13)&
										tmp_sample_a(13)&tmp_sample_b(14)&
										tmp_sample_a(14)&tmp_sample_b(15)&
										tmp_sample_a(15)&tmp_sample_b(16)&
										tmp_sample_a(16)&tmp_sample_b(17)&
										tmp_sample_a(17)&tmp_sample_b(18)&
										tmp_sample_a(18)&tmp_sample_b(19)&
										tmp_sample_a(19)&tmp_sample_b(20)&
										tmp_sample_a(20)&tmp_sample_b(21)&
										tmp_sample_a(21)&tmp_sample_b(22)&
										tmp_sample_a(22)&tmp_sample_b(23)&
										tmp_sample_a(23);
										
		elsif (fs_mode_i = "00") then
			--in 44k1 mode- 1x LC-subsegment has 32-bits - 5 bits zero-padding after each lc-subsegment
			tmp_slice_vector <= 	"00000"&
										tmp_ucm_b(2)	&tmp_ucm_a(2)&
										tmp_ucm_b(1)	&tmp_ucm_a(1)&
										tmp_ucm_b(0)	&tmp_ucm_a(0)&
										tmp_sample_b(0)	&tmp_sample_a(0)&
										tmp_sample_b(1)	&tmp_sample_a(1)&
										tmp_sample_b(2)	&tmp_sample_a(2)&
										tmp_sample_b(3)	&tmp_sample_a(3)&
										tmp_sample_b(4)	&tmp_sample_a(4)&
										tmp_sample_b(5)	&tmp_sample_a(5)&
										tmp_sample_b(6)	&tmp_sample_a(6)&
										tmp_sample_b(7)	&tmp_sample_a(7)&
										tmp_sample_b(8)	&tmp_sample_a(8)&
										tmp_sample_b(9)	&tmp_sample_a(9)&
										tmp_sample_b(10)&
										
									"00000"&
										tmp_sample_a(10)&tmp_sample_b(11)&
										tmp_sample_a(11)&tmp_sample_b(12)&
										tmp_sample_a(12)&tmp_sample_b(13)&
										tmp_sample_a(13)&tmp_sample_b(14)&
										tmp_sample_a(14)&tmp_sample_b(15)&
										tmp_sample_a(15)&tmp_sample_b(16)&
										tmp_sample_a(16)&tmp_sample_b(17)&
										tmp_sample_a(17)&tmp_sample_b(18)&
										tmp_sample_a(18)&tmp_sample_b(19)&
										tmp_sample_a(19)&tmp_sample_b(20)&
										tmp_sample_a(20)&tmp_sample_b(21)&
										tmp_sample_a(21)&tmp_sample_b(22)&
										tmp_sample_a(22)&tmp_sample_b(23)&
										tmp_sample_a(23);
		else
			tmp_slice_vector <= (others=>'0');
			
		end if;
	end process;

	--parity calculator
	process (parity_in_a,parity_in_b)
	begin	
		parity_out <= parity_in_a xor parity_in_b;		
	end process;

	--logical-channel to encoded-block-number converter
	process (clk100_core_i)
	begin
		if (rising_edge(clk100_core_i)) then
			if (lc_counter>=0 and lc_counter<= 14) then
				encoded_block_no <= lc_counter;
			elsif (lc_counter>=15 and lc_counter <= 21) then
				encoded_block_no <= lc_counter+1;
			elsif (lc_counter>=22 and lc_counter<= 24) then
				encoded_block_no <= lc_counter+2;
			elsif (lc_counter=25) then
				encoded_block_no <= lc_counter+3;
			else
				encoded_block_no <= 0;
			end if;
		end if;
	end process;
		
		

	--audio to lc process
	process(clk100_core_i)
	begin
		if rising_edge(clk100_core_i) then
		
			--resync signals from 50M->100M clock where necessary
			lc_tx_ack_100M_z <= lc_tx_ack_50M;
			lc_tx_ack_100M_zz <= lc_tx_ack_100M_z;

			if rst_i = '1' then
						
				--RAM
				lc_ram_a_addr <= 0;
				lc_ram_di_a_we <= '0';
				lc_ram_di_a <= (others=>'0');
		
				--FIFOs
				audio_fifo_out_rd_en <= '0';
				aux_fifo_out_rd_en <= '0';
			
				--panic signal
				audio_fifo_misalign_panic_o <= '0';
				
				--state machine
				P1_State <= WaitSamples;
				P1_SubState <= 0;
				
				lc_pingpong <= 0;	
				use_aux_fifo <= '0';
				
				lc_counter <= 0;
				lc_subframe_counter <= 0;
				aux_empty_counter <= 0;
				
				tmp_sample_a <= (others=>'0');
				tmp_sample_b <= (others=>'0');
				tmp_aux_vector <= (others=>'0');
				tmp_ucm_a <= (others=>'0');
				tmp_ucm_b <= (others=>'0');
		
				reshift_tmp_a <= (others=>'0');
				reshift_tmp_b <= (others=>'0');
							
				parity_in_a <= (others=>'0');
				parity_in_b <= (others=>'0');
				parity_temp <= (others=>'0');
				parity_counter <= 0;
				
				lc_tx_ready_100M <= '0';
				lc_tx_pingpong_100M <= 0;	
				
			else
				
							
				-- wait for start condition of input fifos
				if P1_State = WaitSamples then
				
					--in 48 kHz mode we'll wait for 6x 48 samples to package one ethernet-frame
					if (fs_mode_i = "01" and fill_count_audio_in>= 288) then
										
						--for 48k mode we'll pack 44 16-bit aux words
						if (fill_count_aux_in >= 44) then
							use_aux_fifo <= '1';
						else
							use_aux_fifo <= '0';
						end if;
						
						--check if FIFO matches with CH0 - the CH0 marker bit is stored in the FIFO LSB
						if (audio_fifo_out(0) /= '1') then
							--indicate panic signal -> will lead to system reset -> we don't have anything to do further here
							audio_fifo_misalign_panic_o <= '1';
						end if;
						
						--Set State to start
						P1_State <= AudioFifoToRam;
						P1_SubState <= 0;
						
						--start enable read audio fifo
						audio_fifo_out_rd_en <= '1';	
						
						--reset counter variables
						lc_counter <= 0;
						lc_subframe_counter <= 0;

						
						
						
					--in 44k1 mode we'll wait for 11x 48 samples to package two ethernet frames
					elsif (fs_mode_i = "00" and fill_count_audio_in >= 528) then
						
						--for 44k1 mode we'll pack 88 16-bit aux words
						if (fill_count_aux_in >= 88) then
							use_aux_fifo <= '1';
						else
							use_aux_fifo <= '0';
						end if;
						
						--check if FIFO matches with CH0 - the CH0 marker bit is stored in the FIFO LSB
						if (audio_fifo_out(0) /= '1') then
							--indicate panic signal -> will lead to system reset -> we don't have anything to do further here
							audio_fifo_misalign_panic_o <= '1';
						end if;
						
						--Set State to start
						P1_State <= AudioFifoToRam;
						P1_SubState <= 0;
						
						--start enable read audio fifo
						audio_fifo_out_rd_en <= '1';	
					
						--reset counter variables
						lc_counter <= 0;
						lc_subframe_counter <= 0;
						
					end if;
					
					
						
				-- at first we'll start fetching all audio samples and copy them over to the blockram
				
				--stall cycle to read from fifo until data is valid
				elsif P1_State = AudioFifoToRam and P1_SubState = 0 then					
					lc_ram_di_a_we <= '0';
					
					P1_SubState <= 1;
					
				-- save back first received audio-sample and disable fifo-read (fifo-read has been high now for two cycles)
				elsif P1_State = AudioFifoToRam and P1_SubState = 1 then
					tmp_sample_a <= audio_fifo_out(24 downto 1);
					audio_fifo_out_rd_en <= '0';
					
					P1_SubState <= 2;
					
				-- save back second received audio-sample
				elsif P1_State = AudioFifoToRam and P1_SubState = 2 then
					tmp_sample_b <= audio_fifo_out(24 downto 1);
					
					P1_SubState <= 3;
					
					
				--let's save the first lc-subsegment
				elsif P1_State = AudioFifoToRam and P1_SubState = 3 then				
					-- the address where the first part of the encoded audio-sample is stored is pingpong*704 + (encoded block no 0-31)*22 + lc_subframe_counter (0-21)
					lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + lc_subframe_counter;
					
					if (fs_mode_i = "01") then
						lc_ram_di_a <= "000"&tmp_slice_vector(28 downto 0);
					elsif (fs_mode_i = "00") then
						lc_ram_di_a <= tmp_slice_vector(31 downto 0);
					end if;
					lc_ram_di_a_we <= '1';
					
					
					P1_SubState <= 4;
					
				
				elsif P1_State = AudioFifoToRam and P1_SubState = 4 then	
					-- the address where the second part of the encoded audio-sample is stored is pingpong*704 + (encoded block no 0-31)*22 + lc_subframe_counter (0-21) + 1				
					lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + lc_subframe_counter + 1;
					
					if (fs_mode_i = "01") then
						lc_ram_di_a <= "000"&tmp_slice_vector(57 downto 29);
					elsif (fs_mode_i = "00") then
						lc_ram_di_a <= tmp_slice_vector(63 downto 32);
					end if;
					lc_ram_di_a_we <= '1';
					
					
					
					--let's check if we're through all 24 logical-channels of the audio-part; if not, let's count lc_counter one up and restart
					if lc_counter <23 then
						lc_counter <= lc_counter +1;
						audio_fifo_out_rd_en <= '1';
						
						P1_SubState <= 0; 
					else
						
						--we have all 24-channels of the first
						--in 48k mode we wait until we have processed 11 subframes
						if lc_subframe_counter = 10 and fs_mode_i = "01" then													
							audio_fifo_out_rd_en <= '0';							
							--if yes start to fetch aux-samples
							P1_SubState <= 5;
							
						
						--in 44k1 mode we wait until we have processed 22 subframes						
						elsif lc_subframe_counter = 20 and fs_mode_i = "00" then
							audio_fifo_out_rd_en <= '0';
							
							--if yes start to fetch aux-samples
							P1_SubState <= 5;
							
							
						else
							lc_counter <= 0;
							lc_subframe_counter <= lc_subframe_counter + 2;
							
							audio_fifo_out_rd_en <= '1';
							
							P1_SubState <= 0;  
						end if;
					end if;
					
				
				-- last state of AudioFifoToRam -> disable the ram-write enable and switch over the aux-data-fetch
				elsif (P1_State = AudioFifoToRam and P1_SubState = 5) then
					lc_ram_di_a_we <= '0';					
					
					--reset lc-subframe-Counter
					lc_subframe_counter <= 0;
					aux_empty_counter <= 0;
					P1_State <= AuxFifoToRam;
					P1_SubState <= 0;
					
					
					
					
				--start fetching aux-data, but only if the use_aux_fifo flag is set - otherwise we'll just send empty aux-data during this process
				elsif P1_State = AuxFifoToRam and P1_SubState = 0 then
									
					
					--enable fifo read-flag if we use the aux-fifo
					if (use_aux_fifo = '1') then
						aux_fifo_out_rd_en <= '1';
					end if;
					
					P1_SubState <= 1;
					
				--wait the stall cycle and disable ram-write if we're returning from the loop
				elsif P1_State = AuxFifoToRam and P1_SubState = 1 then
					lc_ram_di_a_we <= '0';
					
					P1_SubState <= 2;
				
				--save back first 16-bit word
				elsif P1_State = AuxFifoToRam and P1_SubState = 2 then		
					tmp_aux_vector(15 downto 0) <= aux_fifo_out;
					
					P1_SubState <= 3;
				
				--save back second 16-bit word			
				elsif P1_State = AuxFifoToRam and P1_SubState = 3 then
					tmp_aux_vector(31 downto 16) <= aux_fifo_out;					
				
					P1_SubState <= 4;
				
				--save back third 16-bit word				
				elsif P1_State = AuxFifoToRam and P1_SubState = 4 then			
					tmp_aux_vector(47 downto 32) <= aux_fifo_out;				
					aux_fifo_out_rd_en <= '0';
					
					lc_counter <= 24;
					P1_SubState <= 5;
					
				--save back fourth 16-bit word or let's use the default data (if we don't use fifo data) and overwrite full 64-bit aux vector			
				elsif P1_State = AuxFifoToRam and P1_SubState = 5 then
				
					if (use_aux_fifo = '1') then
						tmp_aux_vector(63 downto 48) <= aux_fifo_out;
					else
						tmp_aux_vector(63 downto 0) <= aux_empty_data(aux_empty_counter*64+63 downto aux_empty_counter*64);
					end if;
					
					
					lc_counter <= 25;
					P1_SubState <= 6;
					
				--now we're writing into lc24	
				elsif P1_State = AuxFifoToRam and P1_SubState = 6 then			
					lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + lc_subframe_counter;				
					lc_ram_di_a <= tmp_aux_lc24;
					
					
					--enable write-flag
					lc_ram_di_a_we <= '1';
					
					
					
					P1_SubState <= 7;
					
				
				--now we're writing into lc25	
				--check also state of counter variables and jump loop or move forward to last state
				elsif P1_State = AuxFifoToRam and P1_SubState = 7 then
					lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + lc_subframe_counter;				
					lc_ram_di_a <= tmp_aux_lc25;				
					
					--if we have all 12 subframes in 48k mode of aux-data -> continue with data-reshifting
					if (lc_subframe_counter = 10 and  fs_mode_i = "01") then					
						--continue
						P1_SubState <= 8;
						
					--if we have all 22 subframes in 44k1 mode of aux-data -> continue with crc
					elsif (lc_subframe_counter = 21 and fs_mode_i = "00") then
						--continue
						P1_SubState <= 8;
						
					--we don't have process all subframes of aux-data
					else					
						lc_subframe_counter <= lc_subframe_counter + 1;
						
						if (fs_mode_i = "00" and aux_empty_counter=10) then
							aux_empty_counter <= 0;
						else
							aux_empty_counter <= aux_empty_counter + 1;
						end if;
						
						if (use_aux_fifo = '1') then
							aux_fifo_out_rd_en <= '1';
						end if;
						P1_SubState <= 1;
						
					end if;
					
					
				-- last state - used to disable ram-write flag and switch over to either ram-reshift (only needed in 48k mode) or to crc calc (in 44k1 mode)
				elsif P1_State = AuxFifoToRam and P1_SubState = 8 then
					lc_ram_di_a_we <= '0';
					
					
					-- now we'll start reshift everything to a continuous 352-bit stream distributed over 11 32-bit blocks in RAM_DEPTH		
					if (fs_mode_i = "01") then
						lc_counter <= 0;
						lc_subframe_counter <= 0;
						
						P1_State <= RamReorder;
						P1_SubState <= 0;
						
					elsif (fs_mode_i = "00") then
						parity_counter <= 0;
						lc_subframe_counter <= 0;	
						lc_counter <= 0;
					
						P1_State <= ParityCalc;
						P1_SubState <= 0;
					end if;
					




				--------------------------------------	
				-- reshifting from 12 ram slices per lc to merge them together to 11 (352 bits)	- this operation is only needed in 48k-mode
				-- In 48k mode, one lc-slice consists of 27-data-bits + 2-padding-bits. In Sum there are 12 of them.
				-- As the ram is organized in 32-bit width, we always have 3 not-used bits 
				-- Now we merge all the 12x 29-bit words (=348 bits) to one continuous stream of 352 bits (4 additional padding bits needed).
				-- We don't need this in 44k1 mode, because there, every lc-slice has 5-padding-bits (to the 27 data-bits) and therefore matching exactly the 352 bits
				--------------------------------------					
				
				--read first two words back from ram
				elsif P1_State = RamReorder and P1_SubState = 0 then --marker a
					lc_ram_di_a_we <= '0';
				
					P1_SubState <= 1;
					
				elsif P1_State = RamReorder and P1_SubState = 1 then
					
					
					lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + lc_subframe_counter;	
						
					P1_SubState <= 2;
					
				-- this is also used as stall-cycle for first data word become valid - give second address
				elsif P1_State = RamReorder and P1_SubState = 2 then
					lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + lc_subframe_counter + 1;		
					
					P1_SubState <= 3;
				
				--put into reshift_tmp_a variable
				elsif P1_State = RamReorder and P1_SubState = 3 then
					reshift_tmp_a <= lc_ram_do_a;
					
					P1_SubState <= 4;

				--put into reshift_tmp_b variable
				elsif P1_State = RamReorder and P1_SubState = 4 then
					reshift_tmp_b <= lc_ram_do_a;
					
					P1_SubState <= 5;
					
			
				--in this state we reorder the bits into a new word and write it back to ram
				elsif P1_State = RamReorder and P1_SubState = 5 then		
				
					--but only if we have reached the 10th word, we have a special case
					if lc_subframe_counter = 9 then
						P1_SubState <= 6;
					else
						lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + lc_subframe_counter;	
						lc_ram_di_a <= reshift_tmp_b(2+3*lc_subframe_counter downto 0) & reshift_tmp_a(28 downto lc_subframe_counter*3);
						lc_ram_di_a_we <= '1';
						lc_subframe_counter <= lc_subframe_counter+1;
						P1_SubState <= 0; 
					end if;
				
				
				--this is the last state and a bit special as we need to fetch data from word 11, 10 and 9.
				--as of now, reshift_tmp_a should be filled with word(9) and reshift_tmp_b with word(10)
				elsif P1_State = RamReorder and P1_SubState = 6 then				
					--so let's fetch word 11
					lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + 11;
					
					P1_SubState <= 7;
					
				--stall cycle for ram readback
				elsif P1_State = RamReorder and P1_SubState = 7 then
					P1_SubState <= 8;
					
				--create the word which shall be saved back to offset 9	
				elsif P1_State = RamReorder and P1_SubState = 8 then
					
					lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + 9;
					lc_ram_di_a <= lc_ram_do_a(0) & reshift_tmp_b(28 downto 0) & reshift_tmp_a(28 downto 27);
					lc_ram_di_a_we <= '1';
					
					-- save back word 11
					reshift_tmp_b <= lc_ram_do_a; 
					
					
					P1_SubState <= 9;

				--here we create the word which is saved to offset 10 - also the 4 padding bits at the end of our 352-bit stream is inserted here
				elsif P1_State = RamReorder and P1_SubState = 9 then
				
					lc_ram_di_a_we <= '1';
					lc_ram_a_addr <= lc_pingpong*704 + encoded_block_no*22 + 10;
					lc_ram_di_a <= "0000" & reshift_tmp_b (28 downto 1);
					
					--now check if we have done this fun with all 24 channels, if not jump to sub-state 0
					if lc_counter<23 then
						lc_counter <= lc_counter +1;
						lc_subframe_counter <= 0;						
						P1_SubState <= 0; 
					else
					
						--switch over to parity calculation
						parity_counter <= 0;
						lc_subframe_counter <= 0;	
						lc_counter <= 0;
						
						P1_State <= ParityCalc;
						P1_SubState <= 0;
						
					end if;
					
					
					
				--------------------------------------	
				-- start caluclation of parity p1-p5	
				--------------------------------------
				
				--read first data-word 
				elsif P1_State = ParityCalc and P1_SubState = 0 then				
					lc_ram_di_a_we <= '0';	
					lc_ram_a_addr <= lc_pingpong*704 + par_lut(parity_counter,lc_counter)*22 + lc_subframe_counter;
					
					P1_SubState <= 1;
									
				--wait stall cycle for ram-readback				
				elsif P1_State = ParityCalc and P1_SubState = 1 then	
					
					P1_SubState <= 2;
					
				--save back data-word in parity_in_a
				elsif P1_State = ParityCalc and P1_SubState = 2 then
					parity_in_a <= lc_ram_do_a;
					lc_counter <= lc_counter +1;
					
					P1_SubState <= 3;
					
					
				--read second word
				elsif P1_State = ParityCalc and P1_SubState = 3 then 
					lc_ram_a_addr <= lc_pingpong*704 + par_lut(parity_counter,lc_counter)*22 + lc_subframe_counter;
					
					P1_SubState <= 4;
								
				--wait stall cycle for ram-readback		
				elsif P1_State = ParityCalc and P1_SubState = 4 then
				
					P1_SubState <= 5;
					
				--save back data-word in parity_in_b	
				elsif P1_State = ParityCalc and P1_SubState = 5 then
					parity_in_b <= lc_ram_do_a;
					P1_SubState <= 6;
					
				--save back output of CRC calculation in parity-temp and parity_in_a (as this is an iterative CRC calculation  over 15 words)
				elsif P1_State = ParityCalc and P1_SubState = 6 then
				
					parity_temp <= parity_out;
					parity_in_a <= parity_out;
					
					if (lc_counter <14 ) then 
						--jump back to the readout of second ram readback
						lc_counter <= lc_counter +1;
						P1_SubState <= 3; 
					else
						--it seems we're finished calculating the crc of 15 words of the P_x
						P1_SubState <= 7;
					end if;
					
					
				--we save back the negative of the CRC output (as it should be the XNOR of all those data words).	
				elsif P1_State = ParityCalc and P1_SubState = 7 then
					
					lc_ram_a_addr <= lc_pingpong*704 + par_lut(parity_counter,15)*22 + lc_subframe_counter;
					lc_ram_di_a <= not parity_temp;					
					lc_ram_di_a_we <= '1';
					
					--check if we have all 5 parity-bits
					if (parity_counter<4) then	
						
						--if not, we jump back to the start
						parity_counter <= parity_counter + 1;
						lc_counter <= 0;
						P1_SubState <= 0; 						
					else
						
						--check if we have done this for all 11 slices when 48k mode
						if (fs_mode_i = "01" and lc_subframe_counter < 10) then
						
							--if not, let's increment the lc_subframe_counter variable and jump to the start
							lc_subframe_counter <= lc_subframe_counter + 1;
							parity_counter <= 0;
							lc_counter <= 0;
							P1_SubState <= 0; 
						
						--check if we have done this for all 22 slices when 44k1 mode						
						elsif (fs_mode_i = "00" and lc_subframe_counter < 21) then
							--if not, let's increment the lc_subframe_counter variable and jump to the start
							lc_subframe_counter <= lc_subframe_counter + 1;
							parity_counter <= 0;
							lc_counter <= 0;
							P1_SubState <= 0; 
						
						else
							-- we're finished - now let's calc the global parity bit
							lc_counter <= 0;
							lc_subframe_counter <= 0;
							P1_SubState <= 0;
							P1_State <= GlobalParity;
						end if;
						
					end if;
				
				
				
				--------------------------------------	
				-- start caluclation of global parity	
				--------------------------------------		
				
				--start reading from RAM
				elsif P1_State = GlobalParity and P1_SubState = 0 then
				
					lc_ram_di_a_we <= '0';	
					lc_ram_a_addr <= lc_pingpong*704 + lc_counter*22 + lc_subframe_counter;
					
					P1_SubState <= 1;
					
				--stall cycle for RAM readback
				elsif P1_State = GlobalParity and P1_SubState = 1 then
				
					P1_SubState <= 2;
					
				--save back word in parity_in_a
				elsif P1_State = GlobalParity and P1_SubState = 2 then
				
					parity_in_a <= lc_ram_do_a;
					lc_counter <= lc_counter +1;
					
					P1_SubState <= 3;
					
				--start reading second word
				elsif P1_State = GlobalParity and P1_SubState = 3 then
				
					lc_ram_a_addr <= lc_pingpong*704 + lc_counter*22 + lc_subframe_counter;			

					P1_SubState <= 4;
				
				--stall cycle for RAM readback				
				elsif P1_State = GlobalParity and P1_SubState = 4 then
				
					P1_SubState <= 5;
					
				--save back second word in parity_in_b
				elsif P1_State = GlobalParity and P1_SubState = 5 then
					parity_in_b <= lc_ram_do_a;
					
					P1_SubState <= 6;

				--save back the output of the CRC-cal in parity_temp and parity_in_a (as this is an iterative calculation)	
				elsif P1_State = GlobalParity and P1_SubState = 6 then
					
					parity_temp <= parity_out;
					parity_in_a <= parity_out;		

					--check if we are through all 31 encoded blocks...
					if (lc_counter < 30 ) then 
						--if not, continue read words...
						lc_counter <= lc_counter +1;
						P1_SubState <= 3; 
					else
						--if we're finished continue saving the data
						P1_SubState <= 7;
					end if;
					
				-- let's save back the negative of the CRC word (as we're supposed to generate an XNOR actually)
				elsif P1_State = GlobalParity and P1_SubState = 7 then				
					
						lc_ram_a_addr <= lc_pingpong*704 + 31*22 + lc_subframe_counter;
						lc_ram_di_a <= not parity_temp;						
						lc_ram_di_a_we <= '1';
						
						lc_counter <= 0;
						
						--now let's check if we have done this with all 11 slices when 48k mode
						if (fs_mode_i = "01" and lc_subframe_counter < 10) then
							--increment offset and restart
							lc_subframe_counter <= lc_subframe_counter + 1;
							
							P1_SubState <= 0; --marker a
						
						--now let's check if we have done this with all 22 slices when 44k1 mode						
						elsif (fs_mode_i = "00" and lc_subframe_counter < 21) then
							--increment offset and restart
							lc_subframe_counter <= lc_subframe_counter + 1;
							
							P1_SubState <= 0; --marker a
						
						else
							--if yes, we're finished and we can start transmit
							P1_SubState <= 0;
							P1_State <= WaitTransmit;
						end if;
					
					
					
					
				--------------------------------------	
				-- start transmit process	
				--------------------------------------	
				elsif P1_State = WaitTransmit and P1_SubState = 0 then			
					lc_ram_di_a_we <= '0';
					
					-- start transmit			
					lc_tx_ready_100M <= '1';
					
					--remember which ping-pong side of the ram we shall use from P1				
					P1_SubState <= 1;				
				
			-- wait for tx acknowledge
				elsif P1_State = WaitTransmit and P1_SubState = 1 then 
				
					if lc_tx_ack_100M_zz = '1' then
						lc_tx_pingpong_100M <= lc_pingpong;
						lc_tx_ready_100M <= '0';
						
						if lc_pingpong = 0 then
							lc_pingpong <= 1;
						else
							lc_pingpong <= 0;
						end if;
						
						P1_SubState <= 0;	
						P1_State <= WaitSamples;
					end if;

				else
					
						
					P1_SubState <= 0;
					P1_State <= WaitSamples;
				end if;
				
				
				
				
				  

			end if;
		end if;
		
		
	end process;





	assm_is_active_o <= assm_do;

	process(clk50_ethernet_i)
	begin


		if rising_edge(clk50_ethernet_i) then
		
			--resync signals from 100M->50M clock where necessary
			reset50M_z <= rst_i;
			reset50M_zz <= reset50M_z;	
			lc_tx_ready_50M_z <= lc_tx_ready_100M;
			lc_tx_ready_50M_zz <= lc_tx_ready_50M_z;		
			lc_tx_pingpong_50M_z <= lc_tx_pingpong_100M;
			lc_tx_pingpong_50M_zz <= lc_tx_pingpong_50M_z;
			
			if reset50M_zz = '1'then
			
				P2_State <= WaitForData;
				P2_SubState <= 0;
			
				
				lc_ram_b_addr <= 0;
				
				phy_tx_data_o	<= (others=>'0');
				phy_tx_eof_o	<= '0';
				phy_tx_valid_o <= '0';
				phy_tx_ready_edge <= "00";
				
				assm_do <= '0';
				assm_counter <= 0;
				
				tx_round_44k1 <= 0;
				tmp_ram_word <= (others=>'0');
				
				lc2_counter <= 0;
				lc2_subframe_counter <= 0;
				wait_round_two_counter <= 0;
				
				lc_tx_ack_50M <= '0';	
				
				
				--init header data
				mac_dest(0) <= x"02";
				mac_dest(1) <= x"00";
				mac_dest(2) <= x"00";
				mac_dest(3) <= x"00";
				mac_dest(4) <= x"00";
				mac_dest(5) <= x"00";
				
				mac_source(0) <= x"00";
				mac_source(1) <= x"00";
				mac_source(2) <= x"00";
				mac_source(3) <= x"00";
				mac_source(4) <= x"00";
				mac_source(5) <= x"00";
				
				--this is the ether-type assigned to AES
				ether_type(0) <= x"88";
				ether_type(1) <= x"DD";
				
				--protocol identifier -> is defined by AESSC secretariat for AES50-2005
				protocol_identifier <= x"01";
				
				--user octet -> usage tbd
				user_octet <= x"00";
				
				--frame format identifier
				--those bytes are always the same
				frame_format_id(0) <= x"31"; -- protocol minor version + protocol major version
				frame_format_id(1) <= x"01"; -- frame type + flags -> aes3 compatible audio, associated only with f_s sync period (no 2048xf_s mode)
				frame_format_id(3) <= x"00"; -- frame content structure
				frame_format_id(4) <= x"00"; -- reserved
				
				--48k mode
				if (fs_mode_i = "01") then 
					frame_format_id(2) <= x"46"; -- audio format -> indicates 48k with 24 bits audio				
					frame_format_id(5) <= x"1a"; -- crc-8 checksum
					
					frame_format_id(6) <= x"11"; --this is frame type + flags with ASSM flag set
					frame_format_id(7) <= x"aa"; --crc8 checksum when ASSM flag set
				
				--44k1 mode
				elsif (fs_mode_i = "00") then
					frame_format_id(2) <= x"06"; -- audio format -> indicates 44k1 with 24 bits audio
					frame_format_id(5) <= x"cc"; -- crc-8 checksum
					
					frame_format_id(6) <= x"11"; --this is frame type + flags with ASSM flag set
					frame_format_id(7) <= x"7c"; --crc8 checksum when ASSM flag set
				end if;
				
			else
			
				--shift signals in edge-detector
				phy_tx_ready_edge <= phy_tx_ready_edge(0)&phy_tx_ready_i;
		
			
				if P2_State = WaitForData and lc_tx_ready_50M_zz = '1' then
				
				
					
					--send back acknowledge to P1
					lc_tx_ack_50M <= '1';
					
					--as we'll always send two frames in 44k1 mode, let's reset this variable
					tx_round_44k1 <= 0;
					
					P2_State <= TransmitHeader;
					P2_SubState <= 0;
					
					if (fs_mode_i = "00" and tx_round_44k1 = 0 and assm_counter < 2047) then
						assm_counter <= assm_counter + 1;
					elsif (fs_mode_i = "01" and assm_counter < 1023) then
						assm_counter <= assm_counter +1;
					else
						assm_counter <= 0;
					end if;
					
					if ( (assm_counter = 0 and fs_mode_i = "00" and tx_round_44k1 = 0) or (assm_counter = 0 and fs_mode_i = "01")) then
						assm_do <= '1';
					end if;
					
						
				--now start the rmii-tx with sending first byte of mac-dest (pre-amble and sfd will be auto-generated by the rmii-tx-module) and pullback tx_ack to 0
				elsif P2_State = TransmitHeader and P2_SubState = 0 then
					lc_tx_ack_50M <= '0';
					
					phy_tx_data_o <= mac_dest(0);
					phy_tx_valid_o <= '1';
					P2_SubState <= 1;
					
				--rmii-module will signal by phy_tx_ready_i that it can consume the next byte of data....
				--send mac-destination header
				elsif P2_State = TransmitHeader and P2_SubState=1 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_dest(1);				
					P2_SubState <= 2;				
				elsif P2_State = TransmitHeader and P2_SubState=2 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_dest(2);				
					P2_SubState <= 3;
				elsif P2_State = TransmitHeader and P2_SubState=3 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_dest(3);				
					P2_SubState <= 4;
				elsif P2_State = TransmitHeader and P2_SubState=4 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_dest(4);				
					P2_SubState <= 5;
				elsif P2_State = TransmitHeader and P2_SubState=5 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_dest(5);				
					P2_SubState <= 6;	

				--send mac-source address
				elsif P2_State = TransmitHeader and P2_SubState=6 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_source(0);				
					P2_SubState <= 7;
				elsif P2_State = TransmitHeader and P2_SubState=7 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_source(1);				
					P2_SubState <= 8;
				elsif P2_State = TransmitHeader and P2_SubState=8 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_source(2);				
					P2_SubState <= 9;
				elsif P2_State = TransmitHeader and P2_SubState=9 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_source(3);				
					P2_SubState <= 10;
				elsif P2_State = TransmitHeader and P2_SubState=10 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_source(4);				
					P2_SubState <= 11;	
				elsif P2_State = TransmitHeader and P2_SubState=11 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= mac_source(5);				
					P2_SubState <= 12;	

				--send ether type tx
				elsif P2_State = TransmitHeader and P2_SubState=12 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= ether_type(0);				
					P2_SubState <= 13;	
				elsif P2_State = TransmitHeader and P2_SubState=13 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= ether_type(1);				
					P2_SubState <= 14;					
					
				--send protocol id
				elsif P2_State = TransmitHeader and P2_SubState=14 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= protocol_identifier;				
					P2_SubState <= 15;		
									
				--send user octet
				elsif P2_State = TransmitHeader and P2_SubState=15 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= user_octet;				
					P2_SubState <= 16;	

				--send frame format identification header
				elsif P2_State = TransmitHeader and P2_SubState=16 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= frame_format_id(0);				
					P2_SubState <= 17;
					
				elsif P2_State = TransmitHeader and P2_SubState=17 and phy_tx_ready_i = '1' then
					
					--now let's check if we had an active assm marker for this frame and send with flag or not...
					if (assm_do = '0') then
						phy_tx_data_o <= frame_format_id(1);	
					else
						phy_tx_data_o <= frame_format_id(6);
					end if;				
					
					P2_SubState <= 18;
					
				elsif P2_State = TransmitHeader and P2_SubState=18 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= frame_format_id(2);				
					P2_SubState <= 19;
				elsif P2_State = TransmitHeader and P2_SubState=19 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= frame_format_id(3);				
					P2_SubState <= 20;
				elsif P2_State = TransmitHeader and P2_SubState=20 and phy_tx_ready_i = '1' then
					phy_tx_data_o <= frame_format_id(4);				
					P2_SubState <= 21;	
				elsif P2_State = TransmitHeader and P2_SubState=21 and phy_tx_ready_i = '1' then
				
					--now let's check which CRC we use depending if we had been sending an ASSM marker or not
					if (assm_do = '0') then
						phy_tx_data_o <= frame_format_id(5);
					else
						phy_tx_data_o <= frame_format_id(7);
					end if;
					
					assm_do <= '0';
					--now transmit of data begins
					P2_State <= TransmitData;
					P2_SubState <= 0;	
					
					
				--elsif P2_State = TransmitData and P2_SubState = 0 and phy_tx_ram_preload = '1' then
				elsif P2_State = TransmitData and P2_SubState = 0 and phy_tx_ready_edge = "01" then
					if fs_mode_i = "00" and tx_round_44k1=1 then
						lc_ram_b_addr <= lc_tx_pingpong_50M_zz*704 + lc2_counter*22 + lc2_subframe_counter + 11;
					else
						lc_ram_b_addr <= lc_tx_pingpong_50M_zz*704 + lc2_counter*22 + lc2_subframe_counter;
					end if;
					
					if (lc2_counter = 31) then
						lc2_counter <= 0;					
						if lc2_subframe_counter /= 10 then			
							lc2_subframe_counter <= lc2_subframe_counter + 1;				
						end if;
					else
						lc2_counter <= lc2_counter + 1;
					end if;
					
					P2_SubState <= 1;
					
				elsif P2_State = TransmitData and P2_SubState = 1 then
					P2_SubState <= 2;
					
					
				elsif P2_State = TransmitData and P2_SubState = 2 and phy_tx_ready_i = '1' then			
					phy_tx_data_o <= lc_ram_do_b(7 downto 0);
					tmp_ram_word <= lc_ram_do_b;
					P2_SubState <= 3;
					
				elsif P2_State = TransmitData and P2_SubState = 3 and phy_tx_ready_i = '1' then			
					phy_tx_data_o <= tmp_ram_word(15 downto 8);				
					P2_SubState <= 4;
					
				elsif P2_State = TransmitData and P2_SubState = 4 and phy_tx_ready_i = '1' then			
					phy_tx_data_o <= tmp_ram_word(23 downto 16);				
					P2_SubState <= 5;
					
				elsif P2_State = TransmitData and P2_SubState = 5 and phy_tx_ready_i = '1' then			
					phy_tx_data_o <= tmp_ram_word(31 downto 24);

					if (lc2_subframe_counter = 10 and lc2_counter = 31) then
						
						P2_SubState <= 6;
						phy_tx_eof_o <= '1';
					else
					
						P2_SubState <= 0;
					end if;
					
			
				elsif (P2_State = TransmitData and P2_SubState = 6 and phy_tx_ready_i = '1') then
					phy_tx_eof_o <= '0';
					phy_tx_valid_o <= '0';
					lc2_subframe_counter <= 0;
					lc2_counter <= 0;
					P2_SubState <= 31;
					
					if (fs_mode_i = "00" and tx_round_44k1 = 0) then
						tx_round_44k1 <= 1;
						wait_round_two_counter <= 450;
						
						P2_State <= WaitRoundTwo;
						P2_SubState <= 0;
						
						
					else
						tx_round_44k1 <= 0;
						P2_State <= WaitForData;
						P2_SubState <= 0;
					
					end if;
			
				elsif P2_State = WaitRoundTwo and P2_SubState = 0 then
					if wait_round_two_counter > 0 then
						wait_round_two_counter <= wait_round_two_counter - 1;
					else
						P2_State <= TransmitHeader;
						P2_SubState <= 0;
					end if;
					
				else
					
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
		clka_i 			=> clk100_core_i,
		clkb_i 			=> clk50_ethernet_i,
		ena_i 			=> '1',
		enb_i 			=> '1',
		wea_i 			=> lc_ram_di_a_we,
		web_i 			=> '0',
		addra_i 		=> lc_ram_a_addr,
		addrb_i 		=> lc_ram_b_addr,
		da_i 			=> lc_ram_di_a,
		db_i 			=> (others => '0'),
		da_o 			=> lc_ram_do_a,
		db_o 			=> lc_ram_do_b
	);


audio_in_buffer : entity work.aes50_ring_buffer(rtl)
	generic map (
		RAM_WIDTH 		=> 25,  -- actually 24-bit sample + 1 bit CH0-indicator
		RAM_DEPTH 		=> 1056 -- 2* blocks with 11*samples * 48 channels (considered worst case in 44k1 mode)
	)
	port map (
		clk_i 			=> clk100_core_i,
		rst_i 			=> rst_i,
		wr_en_i 		=> audio_in_wr_en_i,
		wr_data_i 		=> audio_fifo_in,
		rd_en_i 		=> audio_fifo_out_rd_en,
		rd_valid_o 		=> open,
		rd_data_o 		=> audio_fifo_out,
		empty_o 		=> fifo_debug_o(0),
		empty_next_o 	=> open,
		full_o 			=> fifo_debug_o(1),
		full_next_o 	=> open,
		fill_count_o 	=> fill_count_audio_in
	);
					
aux_data_buffer : entity work.aes50_ring_buffer(rtl)
	generic map (
		RAM_WIDTH 		=> 16,
		RAM_DEPTH 		=> 176 -- 2* blocks with 88* aux-data-words (considered worst case in 44k1 mode)
	)
	port map (
		clk_i 			=> clk100_core_i,
		rst_i 			=> rst_i,
		wr_en_i 		=> aux_in_wr_en_i,
		wr_data_i 		=> aux_i,
		rd_en_i 		=> aux_fifo_out_rd_en,
		rd_valid_o 		=> open,
		rd_data_o 		=> aux_fifo_out,
		empty_o 		=> fifo_debug_o(2),
		empty_next_o 	=> open,
		full_o 			=> fifo_debug_o(3),
		full_next_o 	=> open,
		fill_count_o 	=> fill_count_aux_in
	);
					
					

					
end architecture;