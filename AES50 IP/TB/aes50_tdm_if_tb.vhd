-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_tdm_if_tb.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Testbench to check the TDM serializer module.
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



entity aes50_tdm_if_tb is

end aes50_tdm_if_tb;


architecture Behavioral of aes50_tdm_if_tb is

	
	constant audio_width 						: natural := 24;
	constant audio_depth 						: natural := 1056;
	constant aux_width 							: natural := 16;
	constant aux_depth 							: natural := 176;  
	
	-- samplerate select "00" => 44k1; "01" => 48k
	signal fs_mode								: std_logic_vector (1 downto 0) := "01";
	-- tdm8 / i2s mode => 0=tdm8 48x48; 1=i2s 2x2
	signal tdm8_i2s_mode_select					: std_logic := '1';
	
    signal clk100 								: std_logic := '0';
    signal rst									: std_logic := '1';
	signal audio_ok, audio_ok_n					: std_logic := '0';
	
	signal mclk									: std_logic := '0';	
	signal bclk 								: std_logic := '0';
	signal wclk 								: std_logic := '1';
	
	signal bclk_counter							: integer range 3 downto 0;
	signal wclk_counter							: integer range 1023 downto 0;
	
	signal tdm_data								: std_logic_vector(5 downto 0);
	signal tdm_aux_data							: std_logic;	
	
	
	--FIFO interface to/from TDM Module
	signal audio_out							: std_logic_vector (23 downto 0) := (others=>'0');
	signal audio_out_ch0_marker					: std_logic := '0';
	signal aux_out								: std_logic_vector (15 downto 0) := (others=>'0');
	signal audio_out_wr_en						: std_logic;
	signal aux_out_wr_en						: std_logic;

	signal audio_in								: std_logic_vector(24 downto 0);
	signal aux_in								: std_logic_vector(15 downto 0);
	signal audio_in_rd_en						: std_logic;
	signal aux_in_rd_en							: std_logic;
	signal fill_count_audio_in 					: integer range 767 downto 0;
	signal fill_count_aux_in					: integer range 127 downto 0;
	
	signal audio_send_fifo_in					: std_logic_vector(23 downto 0) := (others=>'0');
	signal audio_send_fifo_ch0_marker_in		: std_logic := '0';
	signal audio_send_fifo_in_with_marker		: std_logic_vector(24 downto 0);
	signal aux_send_fifo_in						: std_logic_vector(15 downto 0) := (others=>'0');
	signal audio_send_fifo_in_wr_en				: std_logic := '0';
	signal aux_send_fifo_in_wr_en				: std_logic := '0';
	
	signal audio_fifo_misalign_panic			: std_logic;

	
	

	
	signal negpos								: std_logic := '1';
	

	

	
	
begin
	--for a 49.152MHz clock, 10ns would be the more fitting value, but setting it to 11 keeps mclk (visibly) async to the 100M clock in simulation
	mclk 			<= not mclk after 11ns; 
	audio_ok 		<= '1', '0' after 9874ns;

		
	clk100 			<= not clk100 after 6ns;
    rst 			<= '1', '0' after 100ns;

	audio_ok_n 		<= not audio_ok;


--this is the TDM clock generator as can be found also in the aes50-clockmanager Module
--will generate a ~approx. 48kHz sync-pulse and a 12.288 MHz BCLK.. (see above statement in clock definition)	
process (mclk)
begin

	if (rising_edge(mclk)) then
	
		if (rst='1') then
			bclk_counter <= 0;
			if (tdm8_i2s_mode_select = '0') then
				wclk_counter <= 2;
			else
				wclk_counter <= 8;
			end if;
		else
		
			if (tdm8_i2s_mode_select = '0') then
				if (bclk_counter <3 ) then
					bclk_counter <= bclk_counter + 1;
				else
					bclk_counter <= 0;
				end if;
				
				if (wclk_counter < 1023) then
					wclk_counter <= wclk_counter + 1;
				else
					wclk_counter <= 0;
				end if;
				
				if (wclk_counter < 128) then
					wclk <= '1';
				else
					wclk <= '0';
				end if;
				
				if (bclk_counter < 2) then
					bclk <= '1';
				else
					bclk <= '0';
				end if;
				
			else
			
			
				if (bclk_counter <15 ) then
					bclk_counter <= bclk_counter + 1;
				else
					bclk_counter <= 0;
				end if;
				
				if (wclk_counter < 1023) then
					wclk_counter <= wclk_counter + 1;
				else
					wclk_counter <= 0;
				end if;
				
				if (wclk_counter < 512) then				
					wclk <= '0';
				else				
					wclk <= '1';
				end if;
				
				if (bclk_counter < 8) then				
					bclk <= '1';
				else				
					bclk <= '0';
				end if;
				
			end if;
		end if;
		
		
	end if;	

end process;
	

fifo_send_stimulus:  process begin
    -- Wait for the Reset to be released before 
    
	wait until (audio_ok = '0');
    wait for 50ns;
    wait until (clk100 = '0');

    for j in 0 to 10 loop	

		wait until rising_edge(wclk);
		wait until rising_edge(wclk);
		wait until rising_edge(wclk);
		wait until rising_edge(wclk);
		wait until rising_edge(wclk);
		wait until rising_edge(wclk);
		
		
		--48k mode
		if (fs_mode = "01") then
		
			--in sum we'll write here 6*48 samples and 44 aux-words into the FIFOS to our TDM-module (TDM out)
			for i in 0 to 5 loop
		
				for y in 1 to 48 loop
					wait until rising_edge(clk100); 
					
					--let's toggle the sign with every sample
					negpos <= not negpos;
					audio_send_fifo_in_wr_en <= '1';
					if (negpos = '0') then 
					   audio_send_fifo_in <= x"aaaaaa";
						--audio_send_fifo_in <= std_logic_vector ( to_signed (y+i*100000,24));
					else
					   audio_send_fifo_in <= x"555555";
						--audio_send_fifo_in <= std_logic_vector ( to_signed ( -(y+i*100000),24));
					end if;
					
					
					if (j/=4) then
						--set ch0-marker with ch0-sample
						if (y=1) then
							audio_send_fifo_ch0_marker_in <= '1';
						else
							audio_send_fifo_ch0_marker_in <= '0';
						end if;
					else
						--let's provoke FIFO misalign panic after a while...
						if (y=22) then
							audio_send_fifo_ch0_marker_in <= '1';
						else
							audio_send_fifo_ch0_marker_in <= '0';
						end if;
					end if;
					
								
					
					
					if (i=0 and y<=44) then
						aux_send_fifo_in <= std_logic_vector ( to_signed (y*1000,16));
						--aux_in <= std_logic_vector ( to_signed (0,16));
						aux_send_fifo_in_wr_en <= '1';
					else
						aux_send_fifo_in_wr_en <= '0';
					end if;
				end loop;
				wait until rising_edge(clk100); 
				audio_send_fifo_in_wr_en <= '0';
				
				
			end loop;
		
		--44k1 mode
		elsif (fs_mode = "00") then
		
			--in sum we'll write here 11*48 samples and 88 aux-words into the FIFOS to our TDM-module (TDM out)			
			for i in 0 to 10 loop
				for y in 1 to 48 loop
					wait until rising_edge(clk100); 
					
					--let's toggle the sign with every sample
					negpos <= not negpos;
					audio_send_fifo_in_wr_en <= '1';
					if (negpos = '0') then 
						audio_send_fifo_in <= std_logic_vector ( to_signed (y+i*100000,24));
					else
						audio_send_fifo_in <= std_logic_vector ( to_signed ( -(y+i*100000),24));
					end if;
					
					if (j/=4) then
						--set ch0-marker with ch0-sample
						if (y=1) then
							audio_send_fifo_ch0_marker_in <= '1';
						else
							audio_send_fifo_ch0_marker_in <= '0';
						end if;
					else
						--let's provoke FIFO misalign panic after a while...
						if (y=22) then
							audio_send_fifo_ch0_marker_in <= '1';
						else
							audio_send_fifo_ch0_marker_in <= '0';
						end if;
					end if;
					
					
					
					
					if ( (i=0 or i=1) and y<=44) then
						aux_send_fifo_in <= std_logic_vector ( to_signed (y*1000+i*100,16));
						--aux_in <= std_logic_vector ( to_signed (0,16));
						aux_send_fifo_in_wr_en <= '1';
					
						
					else
						aux_send_fifo_in_wr_en <= '0';
					end if;
				end loop;
				wait until rising_edge(clk100); 
				audio_send_fifo_in_wr_en <= '0';
				
				
			end loop;

			
		end if;
	
	end loop;
	
  end process fifo_send_stimulus;




audio_send_fifo_in_with_marker <= audio_send_fifo_in&audio_send_fifo_ch0_marker_in;

audio_send_buffer : entity work.aes50_ring_buffer(rtl)
	generic map (
	  RAM_WIDTH 						=> audio_width+1, --24 bit audio + 1bit ch0 marker
	  RAM_DEPTH 						=> audio_depth
	)
	port map (
	  clk_i 							=> clk100,
	  rst_i 							=> rst,
	  
	  wr_en_i 							=> audio_send_fifo_in_wr_en,
	  wr_data_i 						=> audio_send_fifo_in_with_marker,
	  
	  rd_en_i 							=> audio_in_rd_en,
	  rd_valid_o 						=> open,
	  rd_data_o 						=> audio_in,
	  
	  empty_o 							=> open,
	  empty_next_o 						=> open,
	  full_o 							=> open,
	  full_next_o 						=> open,
	  fill_count_o 						=> fill_count_audio_in
	);
					
					
aux_send_buffer : entity work.aes50_ring_buffer(rtl)
	generic map (
	  RAM_WIDTH => aux_width,
	  RAM_DEPTH => aux_depth
	)
	port map (
	  clk_i 							=> clk100,
	  rst_i 							=> rst,
	  wr_en_i 							=> aux_send_fifo_in_wr_en,
	  wr_data_i 						=> aux_send_fifo_in,
	  
	  rd_en_i 							=> aux_in_rd_en,
	  rd_valid_o 						=> open,
	  rd_data_o 						=> aux_in,
	  
	  empty_o 							=> open,
	  empty_next_o 						=> open,
	  full_o 							=> open,
	  full_next_o 						=> open,
	  fill_count_o 						=> fill_count_aux_in
	);
	
					


tdm : entity work.aes50_tdm_if(rtl)

	port map (
	
		clk100_i						=> clk100,
		rst_i							=> audio_ok,
		
		fs_mode_i 						=> fs_mode,
		tdm8_i2s_mode_i					=> tdm8_i2s_mode_select,
		--tdm if
		tdm_bclk_i						=> bclk,
		tdm_wclk_i						=> wclk,
		
		tdm_audio_i						=> tdm_data,
		tdm_audio_o						=> tdm_data,
		
		tdm_aux_i 						=> tdm_aux_data,
		tdm_aux_o						=> tdm_aux_data,
		
		aes_rx_ok_i						=> '1',
		enable_tx_i 					=> audio_ok_n,
		
		--FIFO interface to aes50-tx	
		audio_o							=> audio_out,
		audio_ch0_marker_o				=> audio_out_ch0_marker,
		aux_o							=> aux_out,
		audio_out_wr_en_o				=> audio_out_wr_en,
		aux_out_wr_en_o					=> aux_out_wr_en,
		
		
		--FIFO interface to aes50-rx
		audio_i							=> audio_in(24 downto 1),
		audio_ch0_marker_i				=> audio_in(0),
		aux_i							=> aux_in,
		audio_in_rd_en_o				=> audio_in_rd_en,
		aux_in_rd_en_o					=> aux_in_rd_en,
		fifo_fill_count_audio_i 		=> fill_count_audio_in,
		fifo_fill_count_aux_i			=> fill_count_aux_in,
		
		audio_fifo_misalign_panic_o		=> audio_fifo_misalign_panic,
		
		tdm_debug_o						=> open
	
	);
	

end Behavioral;
