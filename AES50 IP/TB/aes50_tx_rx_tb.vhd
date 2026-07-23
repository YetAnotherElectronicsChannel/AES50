-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_tx_rx_tb.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Testbench example how to test the AES50 TX/RX operation.
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


entity aes50_tx_rx_tb is
--  Port ( );
end aes50_tx_rx_tb;

architecture Behavioral of aes50_tx_rx_tb is
    
	signal clk100 						: std_logic := '0';
    signal clk50						: std_logic := '0';
    signal rst							: std_logic := '1';
	
	-- set sample-rate here -> 00->44k1, 01 -> 48k; others not supported until now
	signal fs_mode 						: std_logic_vector (1 downto 0) := "01";
	

	signal audio_in						: std_logic_vector (23 downto 0) := (others=>'0');
	signal audio_in_ch0_marker			: std_logic := '0';
	signal aux_in						: std_logic_vector (15 downto 0) := (others=>'0');
	signal aux_in_start_marker          : std_logic := '0';
	signal aud_wr 						: std_logic := '0';
	signal aux_wr						: std_logic := '0';
	
	signal fifo_misalign_panic 	       : std_logic;
	
	signal audio_out					: std_logic_vector (23 downto 0);
	signal audio_out_ch0_marker			: std_logic := '0';
	signal audio_out_rd_en				: std_logic := '0';
	
	signal aux0_out						: std_logic_vector (15 downto 0);
	signal aux0_start_marker_o			: std_logic := '0';
	signal aux0_out_rd_en				: std_logic := '0';
	
	signal aux1_out						: std_logic_vector (15 downto 0);
	signal aux1_start_marker_o			: std_logic := '0';
	signal aux1_out_rd_en				: std_logic := '0';
	
	
	signal	phy_tx_data     			: std_logic_vector(7 downto 0);
	signal	phy_tx_eof      			: std_logic;
	signal	phy_tx_valid    			: std_logic;
	signal	phy_tx_ready    			: std_logic;
	
	signal 	phy_rx_data    				: std_logic_vector(7 downto 0);   
	signal	phy_rx_sof    				: std_logic;    
	signal	phy_rx_eof    				: std_logic;    
	signal	phy_rx_valid   				: std_logic; 

	signal	fill_count_audio_out 		: natural range 0 to 1056-1;
	signal	fill_count_aux0_out 		: natural range 0 to  176-1;	
	signal	fill_count_aux1_out 		: natural range 0 to  176-1;	
	
	signal rmii_data 					: std_logic_vector (1 downto 0) := (others=>'0');
	signal rmii_en   					: std_logic := '0';
	
		
	signal assm_tx_is_active 			: std_logic := '0';
	
begin
	clk100 				<= not clk100 after 5ns;
	clk50 				<= not clk50 after 10ns;    
    rst 				<= '1', '0' after 100ns;



aes50tx : entity work.aes50_tx(rtl)
    port map(
	
		clk100_core_i					=> clk100,
		clk50_ethernet_i 				=> clk50,
		rst_i 							=> rst,

		fs_mode_i 						=> fs_mode,
		assm_is_active_o 				=> assm_tx_is_active,
		
		audio_i 						=> audio_in,
		audio_ch0_marker_i				=> audio_in_ch0_marker,
		aux_i							=> aux_in,
		aux_start_marker_i			    => aux_in_start_marker,
		audio_in_wr_en_i 				=> aud_wr,
		aux_in_wr_en_i 					=> aux_wr,
		
		aux_request_o				    => open,
		fifo_misalign_panic_o		   => fifo_misalign_panic,
		
		phy_tx_data_o 					=> phy_tx_data,        
		phy_tx_eof_o  					=> phy_tx_eof,        
		phy_tx_valid_o  				=> phy_tx_valid,     
		phy_tx_ready_i  				=> phy_tx_ready,

		fifo_debug_o 					=> open
		
	);
	
	
	
	
aes50rx: entity work.aes50_rx(rtl)
		port map(
			clk100_core_i				=> clk100,
			clk50_ethernet_i 			=> clk50,
			rst_i 						=> rst,

			fs_mode_i   				=> fs_mode,
			
			fs_mode_detect_o 			=> open,
			fs_mode_detect_valid_o 		=> open,
			assm_detect_o  				=> open,
		
			audio_o						=> audio_out,
			audio_ch0_marker_o			=> audio_out_ch0_marker,
			
            aux0_o						=> aux0_out,
			aux0_start_marker_o			=> aux0_start_marker_o,
			
			aux1_o						=> aux1_out,
			aux1_start_marker_o			=> aux1_start_marker_o,
						
			audio_out_rd_en_i			=> audio_out_rd_en,
			aux0_out_rd_en_i			=> aux0_out_rd_en,
			aux1_out_rd_en_i			=> aux1_out_rd_en,
				
				
			fifo_fill_count_audio_o 	=> fill_count_audio_out,
			fifo_fill_count_aux0_o 		=> fill_count_aux0_out,
			fifo_fill_count_aux1_o 		=> fill_count_aux1_out,	
			
			eth_rx_data_i    			=> phy_rx_data,
			eth_rx_sof_i     			=> phy_rx_sof,   
			eth_rx_eof_i      			=> phy_rx_eof,  
			eth_rx_valid_i    			=> phy_rx_valid, 
			
			eth_rx_dv_i					=> rmii_en,
			
			fifo_debug_o 				=> open
		
		);
		
	
rmii_1 : entity work.aes50_rmii_transceiver(rtl)
    port map(
    
		clk50_i  						=> clk50,             
		rst_i  							=> rst,            

		--we just loop back the rmii signals here....
		rmii_crs_dv_i 					=> rmii_en,        
		rmii_rxd_i  					=> rmii_data,         
		rmii_tx_en_o 					=> rmii_en,         
		rmii_txd_o   					=> rmii_data,        

		
		eth_rx_data_o   				=> phy_rx_data ,    
		eth_rx_sof_o    				=> phy_rx_sof ,    
		eth_rx_eof_o    				=> phy_rx_eof ,    
		eth_rx_valid_o   				=> phy_rx_valid ,    
		
		eth_tx_data_i    				=> phy_tx_data ,    
		eth_tx_eof_i     				=> phy_tx_eof ,    
		eth_tx_valid_i  				=> phy_tx_valid,     
		eth_tx_ready_o   				=> phy_tx_ready      
    
    );
	


-- that is the stimulus which writes dummy-samples to the FIFO interface of the aes50-tx module
stimulus_aex50_send:  process begin
    -- Wait for the Reset to be released before 
    wait until (rst = '0');
    wait for 1us;
    wait until (clk100 = '0');

	--48k mode
	--we write 48 samples every ~20.83µs in the fifo
	--every 6th sample-period (i==0) we also write 44-aux words
	--6*48 samples and 44-aux words will form one ethernet-frame
	if (fs_mode = "01") then
		for j in 0 to 10 loop	
			for i in 0 to 5 loop
				for y in 1 to 48 loop
					wait until rising_edge(clk100); 
					aud_wr <= '1';
					audio_in <= std_logic_vector ( to_signed (y+i*1000000,24));					
					--send only 0-samples - might be useful to check the internal CRC/parity calculation mechanism
					--audio_in <= std_logic_vector ( to_signed (0,24));
					--audio_in <= x"A5A5A5";	
					
					if (j/=5) then
						--set ch0-marker with ch0-sample
						if (y=1) then
							audio_in_ch0_marker <= '1';
						else
							audio_in_ch0_marker <= '0';
						end if;
					else
						--let's provoke FIFO misalign panic after a while...
						if (y=22) then
							audio_in_ch0_marker <= '1';
						else
							audio_in_ch0_marker <= '0';
						end if;
					end if;
					
					if (i=0 and y<=44) then
						aux_in <= std_logic_vector ( to_signed (y*1000,16));
						--aux_in <= x"AAAA";
						--send only 0-samples - might be useful to check the internal CRC/parity calculation mechanism
						--aux_in <= std_logic_vector ( to_signed (0,16));
						
						aux_wr <= '1';
					else
						aux_wr <= '0';
					end if;
				end loop;
				wait until rising_edge(clk100); 
				aud_wr <= '0';
				
				--we need to wait a bit less time than 20.83µs as the fifo-writes also take time....
				wait for 19400ns;
			end loop;
						
		
		end loop;
	
	
	--44k1 mode
	--we write 48 samples every ~22.68µs in the fifo
	--every 11th sample-period (i==0 and i==1) we write in sum 88-aux words
	--11*48 samples and 8-aux words will form two related ethernet-frame
	elsif (fs_mode = "00") then
	
		for j in 0 to 10 loop	
		
			for i in 0 to 10 loop
			
				for y in 1 to 48 loop
					wait until rising_edge(clk100); 
					aud_wr <= '1';
					audio_in <= std_logic_vector ( to_signed (y+i*500000,24));
					--send only 0-samples - might be useful to check the internal CRC/parity calculation mechanism
					--audio_in <= std_logic_vector ( to_signed (0,24));
										
					
					if (j/=5) then
						--set ch0-marker with ch0-sample
						if (y=1) then
							audio_in_ch0_marker <= '1';
						else
							audio_in_ch0_marker <= '0';
						end if;
					else
						--let's provoke FIFO misalign panic after a while...
						if (y=22) then
							audio_in_ch0_marker <= '1';
						else
							audio_in_ch0_marker <= '0';
						end if;
					end if;
					
					if ( (i=0 or i=1) and y<=44) then
						aux_in <= std_logic_vector ( to_signed (y*1000+i*100,16));
						--aux_in <= std_logic_vector ( to_signed (0,16));
						aux_wr <= '1';
						
					else
						aux_wr <= '0';
						
					end if;
				end loop;
				wait until rising_edge(clk100); 
				aud_wr <= '0';
				
				wait for 22100ns;
			end loop;
			
			
		
		end loop;
	
	
	end if;
  end process stimulus_aex50_send;



-- this stimulus reads back received audio-samples and aux data from the aes50-rx module... This must be verified to match what was sent in the stimulus above...
stimulus_aex50_receive:  process begin
      

    for j in 0 to 10  loop	
		
		--48k mode
		if (fs_mode = "01") then			
			--we just need to wait until the fifo has 288 (6*48) samples and 44 aux-words
			wait until (fill_count_audio_out>=288 and fill_count_aux0_out >= 44 and fill_count_aux1_out >= 44);
						
						
			--let's read back the data
			
				for i in 0 to 5 loop
					for y in 1 to 48 loop
						wait until rising_edge(clk100); 
			
						audio_out_rd_en <= '1';
						
						if (i=0 and y<=44) then
					
							aux0_out_rd_en <= '1';
							aux1_out_rd_en <= '1';
						else
							aux0_out_rd_en <= '0';
							aux1_out_rd_en <= '0';
						end if;
						
					end loop;
					wait until rising_edge(clk100); 
					audio_out_rd_en <= '0';			
			
				end loop;
		
		--44k1 mode
		elsif (fs_mode="00") then
			--here we need to wait for 528 (11*48) samples and 88 aux words
			wait until (fill_count_audio_out>=528 and fill_count_aux0_out >= 88 and fill_count_aux1_out >= 88);
			
			
			--let's read back the data
			
				for i in 0 to 10 loop
					for y in 1 to 48 loop
						wait until rising_edge(clk100); 
			
						audio_out_rd_en <= '1';
						
						if ( (i=0 or i=1) and y<=44 )  then
					
							aux0_out_rd_en <= '1';
							aux1_out_rd_en <= '1';
						else
							aux0_out_rd_en <= '0';
							aux1_out_rd_en <= '0';
						end if;
					end loop;
					wait until rising_edge(clk100); 
					audio_out_rd_en <= '0';			
			
				end loop;
		
		end if;
		
	end loop;
	
  end process stimulus_aex50_receive;   

  
end Behavioral;
