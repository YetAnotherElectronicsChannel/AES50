-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_top.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Top-Module for the AES50 IP Core
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


--sys-mode description
-- 00 			-> aes-slave, tdm-master
-- 01 			-> aes-master, tdm-master
-- 10 or 11 	-> aes-master, tdm-slave

--fs-mode description:
-- 00 -> 44.1k 
-- 01 -> 48k
-- 10 -> 88.2k (not implemented yet)
-- 11 -> 96k (not implemented yet)


--Note: rst_i signal in sync with clk100_i

entity aes50_top is
port (

		--clk and reset
		clk50_i								: in  std_logic; 
		clk100_i 							: in  std_logic; 
		rst_i								: in  std_logic; 
		
		--samplerate and operation mode
		fs_mode_i							: in std_logic_vector(1 downto 0);
		sys_mode_i							: in std_logic_vector(1 downto 0);
		tdm8_i2s_mode_i						: in std_logic;
		
		--connection to phy
		rmii_crs_dv_i 						: in  std_logic;        
		rmii_rxd_i  						: in std_logic_vector(1 downto 0);        
		rmii_tx_en_o 						: out std_logic;       
		rmii_txd_o   						: out std_logic_vector(1 downto 0);   
		phy_rst_n_o							: out std_logic;

		--connection to clk transceivers
		aes50_clk_a_rx_i					: in  std_logic; 
		aes50_clk_a_tx_o					: out std_logic;
		aes50_clk_a_tx_en_o					: out std_logic;

		aes50_clk_b_rx_i					: in  std_logic; 
		aes50_clk_b_tx_o					: out std_logic;
		aes50_clk_b_tx_en_o					: out std_logic;
		
		--interface to external PLL
		clk_1024xfs_from_pll_i				: in  std_logic; 
		pll_lock_n_i						: in  std_logic; 
		clk_to_pll_o						: out std_logic;
		pll_mult_value_o					: out integer;
		pll_init_busy_i						: in  std_logic; 
		
		--tdm/i2s clk interface
		mclk_o								: out std_logic;
		wclk_o 								: out std_logic;
		bclk_o 								: out std_logic;
		wclk_readback_i 					: in  std_logic; 
		bclk_readback_i 					: in  std_logic; 
		wclk_out_en_o						: out std_logic;
		bclk_out_en_o						: out std_logic;
		
		tdm_i								: in std_logic_vector(6 downto 0);
		tdm_o								: out std_logic_vector(6 downto 0);
		
		i2s_i								: in std_logic;
		i2s_o								: out std_logic;
		
		--aes health signal
		aes_ok_o							: out std_logic;
		
		--debug signals
		dbg_o								: out std_logic_vector(7 downto 0);
		
		--uart Signals
		uart_o								: out std_logic;
		
		
		--variables
		debug_out_signal_pulse_len_i		: in integer range 1000000 downto 0;		-- 1000000@100MHz
		first_transmit_start_counter_48k_i	: in integer range 5000000 downto 0;		-- 4249500@100MHz
		first_transmit_start_counter_44k1_i	: in integer range 5000000 downto 0;		-- 4610800@100MHz	
		
		wd_aes_clk_timeout_i				: in integer range 50 downto 0; 			-- 50@100MHz
		wd_aes_rx_dv_timeout_i			    : in integer range 20000 downto 0;			-- 15000@100MHz	
		mdix_timer_1ms_reference_i			: in integer range 100000 downto 0;			-- 100000@100MHz
		aes_clk_ok_counter_reference_i		: in integer range 1000000 downto 0;		-- 1000000@100MHz
		--Those are the multiplicators needed if we are tdm-master as well as aes-master -> we feed the PLL with a 6.25 MHz clock generated through our 100 MHz clock-domain and multiply to get 49.152 or 45.1584...
		mult_clk625_48k_i					: in integer;								-- 8246337@100MHz
		mult_clk625_44k1_i					: in integer								-- 7576322@100MHz
		);
end aes50_top;




architecture rtl of aes50_top is

	
	--Counter for Phy Reset Signal
	signal phy_rst_cnt										: integer range 100000 downto 0;

	--Health Signals
	signal audio_clock_ok     								: std_logic;
	signal aes_rx_ok										: std_logic;
	
	--internal tdm/i2s signals
	signal mclk_internal									: std_logic;
	signal tdm_internal_i									: std_logic_vector(6 downto 0);
	signal tdm_internal_o									: std_logic_vector(6 downto 0);
	
	--Reset Signals		
	signal audio_logic_reset								: std_logic;
	signal aes_rx_rst                 						: std_logic;
	signal aes_tx_rst										: std_logic;
	signal clk_mgr_rst										: std_logic;
	signal eth_rst											: std_logic;
	
	--eth 50M reset
	signal eth_rst_50M_z, eth_rst_50M_zz					: std_logic;
	
	--Signals for scheduling start of operation
	signal first_transmit_start_counter 					: integer range 5000000 downto 0;
	signal first_transmit_start_counter_active 				: std_logic;
	signal enable_tx_assm_start								: std_logic;
	
	
	--internal rmii signals
	signal txd_data_int										: std_logic_vector(1 downto 0);
	signal txd_en_int 										: std_logic;	
    signal rxd_data_int										: std_logic_vector(1 downto 0);
	signal rxd_en_int 										: std_logic;
	
	--stream interface to/from rmii controller to aes-rx / aes-tx
	signal	phy_tx_data     								: std_logic_vector(7 downto 0);
	signal	phy_tx_eof      								: std_logic;
	signal	phy_tx_valid    								: std_logic;
	signal	phy_tx_ready    								: std_logic;
	
	signal 	phy_rx_data    									: std_logic_vector(7 downto 0);   
	signal	phy_rx_sof    									: std_logic;    
	signal	phy_rx_eof    									: std_logic;    
	signal	phy_rx_valid   									: std_logic; 
	
	
	--fifo-signals from aes-rx to tdm
	signal 	fifo_aes_to_tdm_audio_data						: std_logic_vector (23 downto 0);
	signal  fifo_aes_to_tdm_audio_ch0_marker				: std_logic := '0';
	signal	fifo_aes_to_tdm_aux_data						: std_logic_vector (15 downto 0);
	signal	fifo_aes_to_tdm_audio_rd_en						: std_logic := '0';
	signal	fifo_aes_to_tdm_aux_rd_en						: std_logic := '0';
	signal	fifo_aes_to_tdm_audio_fifo_count 				: integer range 1056 - 1 downto 0;
	signal	fifo_aes_to_tdm_aux_fifo_count 					: integer range 176 - 1 downto 0;	
	signal  fifo_aes_to_tdm_misalign_panic					: std_logic := '0';
	
	--fifo signals from aes-rx to UART
	signal fifo_aes_to_uart_aux_data						: std_logic_vector (15 downto 0);
	signal fifo_aes_to_uart_aux_start_marker				: std_logic;
	signal fifo_aes_to_uart_aux_rd_en						: std_logic;
	signal fifo_aes_to_uart_aux_fifo_count					: integer range 176 - 1 downto 0;
	
	--fifo signals from tdm to aes-tx
	signal 	fifo_tdm_to_aes_audio_data						: std_logic_vector (23 downto 0) := (others=>'0');
	signal  fifo_tdm_to_aes_audio_ch0_marker				: std_logic := '0';
	signal 	fifo_tdm_to_aes_aux_data						: std_logic_vector (15 downto 0) := (others=>'0');
	signal 	fifo_tdm_to_aes_audio_wr_en						: std_logic := '0';
	signal 	fifo_tdm_to_aes_aux_wr_en						: std_logic := '0';
	signal  fifo_tdm_to_aes_misalign_panic					: std_logic := '0';
	
	--signals for assm handling
	signal 	assm_remote										: std_logic;
	signal 	assm_self_gemerated								: std_logic;		
	signal 	assm_active_edge								: std_logic_vector(1 downto 0);	
	signal 	assm_debug_out									: std_logic;	
	signal 	assm_debug_out_signal_counter					: integer range 1000000 downto 0;

	signal 	assm_tx_is_active 								: std_logic;
	signal 	assm_tx_is_active_edge							: std_logic_vector(1 downto 0);
	signal 	assm_tx_is_active_debug_out						: std_logic;	
	signal 	assm_tx_is_active_debug_out_signal_counter		: integer range 1000000 downto 0;
	
	signal 	assm_rx_is_active 								: std_logic;
	signal 	assm_rx_is_active_edge							: std_logic_vector(1 downto 0);	
	signal 	assm_rx_is_active_debug_out						: std_logic;	
	signal 	assm_rx_is_active_debug_out_signal_counter		: integer range 1000000 downto 0;


	--UART Signals
	signal uart_tx_byte										: std_logic_vector(7 downto 0);
	signal uart_tx_enable									: std_logic;
	signal uart_tx_busy										: std_logic;
	signal uart_tx_done										: std_logic;
	signal aux_decoder_to_fifo_data							: std_logic_vector(7 downto 0);
	signal aux_decoder_to_fifo_wr_en						: std_logic;
	
	signal fifo_to_uart_data								: std_logic_vector(7 downto 0);
	signal fifo_to_uart_rd_en								: std_logic;
	signal fifo_to_uart_count								: integer range 4095 downto 0;
	signal fifo_uart_tx_state								: integer range 15 downto 0;

	
begin
	
		
	--WCLK/BCLK inout depending on sysmode
	wclk_out_en_o <= '1' when (sys_mode_i="00" or sys_mode_i="01") else '0';
	bclk_out_en_o <= '1' when (sys_mode_i="00" or sys_mode_i="01") else '0';
	
	aes_ok_o		<= audio_clock_ok;
	
	--some debug signals to outside world to see what's happening
	dbg_o 		<= assm_tx_is_active_debug_out & assm_rx_is_active_debug_out & assm_debug_out & rmii_crs_dv_i  & txd_en_int & enable_tx_assm_start & aes_rx_ok & mclk_internal;

	--assign tdm/i2s signals
	tdm_o		<= tdm_internal_o when (tdm8_i2s_mode_i='0') else (others=>'0');
	tdm_internal_i <= tdm_i when (tdm8_i2s_mode_i='0') else ("000000"&i2s_i);
	i2s_o		<= tdm_internal_o(0) when (tdm8_i2s_mode_i='1') else '0';
	
	mclk_o <= mclk_internal;


    rxd_data_int 	<= 	rmii_rxd_i;
	rxd_en_int 		<= 	rmii_crs_dv_i;
    rmii_txd_o 		<= 	txd_data_int; 
	rmii_tx_en_o 	<= 	txd_en_int;	
            


	--second stage reset controller
	process(clk100_i)
	begin
		if (rising_edge(clk100_i)) then
		
			if (rst_i = '1' or fifo_tdm_to_aes_misalign_panic = '1' or fifo_aes_to_tdm_misalign_panic = '1') then
				
				--phy reset
				phy_rst_cnt <= 100000;
				phy_rst_n_o <= '0';	
				
				--other reset
				audio_logic_reset <= '1';
				eth_rst <= '1';
				aes_rx_rst <= '1';
				clk_mgr_rst <= '1';
				aes_tx_rst <= '1';
			else
				
				--timer for phy-reset
				if (phy_rst_cnt > 0) then
					phy_rst_cnt <= phy_rst_cnt - 1;
				else
					phy_rst_n_o <= '1';
				end if;
				
				if (pll_init_busy_i = '1' or phy_rst_cnt>0) then
					audio_logic_reset <= '1';
					eth_rst <= '1';
					aes_rx_rst <= '1';
					clk_mgr_rst <= '1';
					aes_tx_rst <= '1';
			
				else
					clk_mgr_rst 		<= '0';				
					audio_logic_reset 	<= '0';
					eth_rst 			<= '0';
					--audio_logic_reset 	<= not audio_clock_ok;
					aes_tx_rst 			<= not enable_tx_assm_start;
					aes_rx_rst 			<= not aes_rx_ok;
					
				end if;
				
				
			end if;
					
				
		end if;     
		
	end process;

	process (clk50_i)
	begin
		if (rising_edge(clk50_i)) then
			--sync eth-reset to 50M clock domain
			eth_rst_50M_z <= eth_rst;
			eth_rst_50M_zz <= eth_rst_50M_z;
		end if;
		
	end process;



	process (clk100_i)
	begin
		if (rising_edge(clk100_i)) then 
		

			if (rst_i = '1') then	
			
				assm_debug_out <= '0';			
				enable_tx_assm_start <= '0';
				 
			else
				--latch edges of all assm-signals (from clk, tx and rx module)
				
				--depending on system-mode, we either monitor the remote-assm-signal or our own generated signal
				if (sys_mode_i = "00") then					
						assm_active_edge <= assm_active_edge(0)&assm_remote;			
				else			
						assm_active_edge <= assm_active_edge(0)&assm_self_gemerated;			
				end if;
				
				assm_tx_is_active_edge <= assm_tx_is_active_edge(0)&assm_tx_is_active;
				assm_rx_is_active_edge <= assm_rx_is_active_edge(0)&assm_rx_is_active;
			
			
				--debug pulse generator for assm from clk
				if (assm_active_edge = "01") then
					assm_debug_out <= '1';
					assm_debug_out_signal_counter <= debug_out_signal_pulse_len_i;
				else
					if (assm_debug_out_signal_counter > 0) then
						assm_debug_out_signal_counter <= assm_debug_out_signal_counter - 1;
					else
						assm_debug_out <= '0';
					end if;
				end if;
				
				
				
				--some pulse extension counters so that we can see those signals with a scope if we route it to some output pins...
				
				--debug pulse generator for assm (tx-module)
				if (assm_tx_is_active_edge = "01") then
					assm_tx_is_active_debug_out <= '1';
					assm_tx_is_active_debug_out_signal_counter <= debug_out_signal_pulse_len_i;
				else
					if (assm_tx_is_active_debug_out_signal_counter > 0) then
						assm_tx_is_active_debug_out_signal_counter <= assm_tx_is_active_debug_out_signal_counter - 1;
					else
						assm_tx_is_active_debug_out <= '0';
					end if;
				end if;
				
				--debug pulse generator for assm (rx-module)
				if (assm_rx_is_active_edge = "01") then
					assm_rx_is_active_debug_out <= '1';
					assm_rx_is_active_debug_out_signal_counter <= debug_out_signal_pulse_len_i;
				else
					if (assm_rx_is_active_debug_out_signal_counter > 0) then
						assm_rx_is_active_debug_out_signal_counter <= assm_rx_is_active_debug_out_signal_counter - 1;
					else
						assm_rx_is_active_debug_out <= '0';
					end if;
				end if;
				
				
				
				
				--now let's schedule the start of tx (from tdm-in to aes-tx)
				
				--if clock is not fine, we'll wait and preload the tim register
				if (audio_clock_ok = '0') then
				
					--funny magic numbers with no explanation :-)... definitely need to document this mechanism more in detail
					if (fs_mode_i = "01") then					
						first_transmit_start_counter <= first_transmit_start_counter_48k_i;
						
					elsif (fs_mode_i = "00") then					
						first_transmit_start_counter <= first_transmit_start_counter_44k1_i;
					end if;
					
					first_transmit_start_counter_active <= '0';
					enable_tx_assm_start <= '0';
				else
				
					--this is the wait counter to schedule start of transmission of aes-tx frames after audio-clock has signaled good
					if (first_transmit_start_counter_active = '1') then
						if (first_transmit_start_counter>0) then
							first_transmit_start_counter <= first_transmit_start_counter - 1;
						else
							--this will enable the tdm-module to send samples from tdm-in to aes-tx module 
							--the first package from aes-tx module will have assm marker
							enable_tx_assm_start <= '1';
						end if;
					end if;
					
					--if audio-clock is ok, we'll wait until the assm was signaled
					if (assm_active_edge = "01") then
					
						--then we start the wait counter
						first_transmit_start_counter_active <= '1';		
					end if;
				end if;
				

				
			end if;
	end if;
	end process;





	clkmanager: entity work.aes50_clockmanager(rtl)
		port map (
			--system clock inputs
			clk100_i							=> clk100_i,
			rst_i								=> clk_mgr_rst,
			
			sys_mode_i 							=> sys_mode_i,
			fs_mode_i 							=> fs_mode_i,
			tdm8_i2s_mode_i						=> tdm8_i2s_mode_i,
			
			--pll interface
			clk_1024xfs_from_pll_i				=> clk_1024xfs_from_pll_i,
			pll_lock_n_i						=> pll_lock_n_i,
			clk_to_pll_o						=> clk_to_pll_o,
			pll_mult_value_o					=> pll_mult_value_o,
			
			--tdm/i2s clk interface
			mclk_o								=> mclk_internal,
			wclk_o 								=> wclk_o,
			bclk_o 								=> bclk_o,
			wclk_readback_i 					=> wclk_readback_i,
			bclk_readback_i 					=> bclk_readback_i,
			
			--aes50 clocking interface
			aes50_clk_a_rx_i					=> aes50_clk_a_rx_i,
			aes50_clk_a_tx_o					=> aes50_clk_a_tx_o,
			aes50_clk_a_tx_en_o					=> aes50_clk_a_tx_en_o,
			
			aes50_clk_b_rx_i					=> aes50_clk_b_rx_i,
			aes50_clk_b_tx_o					=> aes50_clk_b_tx_o,
			aes50_clk_b_tx_en_o					=> aes50_clk_b_tx_en_o,
			
			--aes frame-sync-marker	
			assm_self_generated_o				=> assm_self_gemerated,
			assm_remote_o						=> assm_remote,
			
			--clk state output
			clock_health_good_o					=> audio_clock_ok,
			
			
			eth_rx_dv_watchdog_i				=> rxd_en_int,
			eth_rx_consider_good_o				=> aes_rx_ok,

			wd_aes_clk_timeout_i				=> wd_aes_clk_timeout_i,			-- 50@100MHz
			wd_aes_rx_dv_timeout_i				=> wd_aes_rx_dv_timeout_i,			-- 15000@100MHz	
			mdix_timer_1ms_reference_i			=> mdix_timer_1ms_reference_i,		-- 100000@100MHz
			aes_clk_ok_counter_reference_i		=> aes_clk_ok_counter_reference_i,	-- 1000000@100MHz
			--Those are the multiplicators needed if we are tdm-master as well as aes-master -> we feed the PLL with a 6.25 MHz clock generated through our 100 MHz clock-domain and multiply to get 49.152 or 45.1584...
			mult_clk625_48k_i					=> mult_clk625_48k_i,				-- 8246337@100MHz
			mult_clk625_44k1_i					=> mult_clk625_44k1_i				-- 7576322@100MHz
		);



	tdm : entity work.aes50_tdm_if(rtl)

		port map (
		
			clk100_i							=> clk100_i,
			rst_i								=> audio_logic_reset,
			fs_mode_i 							=> fs_mode_i,
			tdm8_i2s_mode_i						=> tdm8_i2s_mode_i,
			
			--tdm if
			tdm_bclk_i							=> bclk_readback_i,
			tdm_wclk_i							=> wclk_readback_i,
			
			tdm_audio_i							=> tdm_internal_i(5 downto 0),
			tdm_audio_o							=> tdm_internal_o(5 downto 0),
			
			tdm_aux_i 							=> tdm_internal_i(6),
			tdm_aux_o							=> tdm_internal_o(6),
			
			aes_rx_ok_i 						=> aes_rx_ok,
			enable_tx_i 						=> enable_tx_assm_start,
			
			--FIFO interface to aes50-tx	
			audio_o								=> fifo_tdm_to_aes_audio_data,
			audio_ch0_marker_o					=> fifo_tdm_to_aes_audio_ch0_marker,
			aux_o								=> fifo_tdm_to_aes_aux_data,
			audio_out_wr_en_o					=> fifo_tdm_to_aes_audio_wr_en,
			aux_out_wr_en_o						=> fifo_tdm_to_aes_aux_wr_en,
			
			
			--FIFO interface to aes50-rx
			audio_i								=> fifo_aes_to_tdm_audio_data,
			audio_ch0_marker_i					=> fifo_aes_to_tdm_audio_ch0_marker,
			aux_i								=> fifo_aes_to_tdm_aux_data,
			audio_in_rd_en_o					=> fifo_aes_to_tdm_audio_rd_en,
			aux_in_rd_en_o						=> fifo_aes_to_tdm_aux_rd_en,
			fifo_fill_count_audio_i 			=> fifo_aes_to_tdm_audio_fifo_count,
			fifo_fill_count_aux_i				=> fifo_aes_to_tdm_aux_fifo_count,
			
			audio_fifo_misalign_panic_o			=> fifo_aes_to_tdm_misalign_panic,
			
			tdm_debug_o 						=> open
		
		);
	
	rmii_1 : entity work.aes50_rmii_transceiver(rtl)
		port map(
		
			clk50_i 							=> clk50_i,            
			rst_i  								=> eth_rst_50M_zz,            


			rmii_crs_dv_i 						=> 	rxd_en_int,        
			rmii_rxd_i  						=> 	rxd_data_int,         
			rmii_tx_en_o 						=> 	txd_en_int,         
			rmii_txd_o   						=> 	txd_data_int,        

			-- stream bus alike interface to MAC
			eth_rx_data_o   					=>  phy_rx_data ,    
			eth_rx_sof_o    					=>  phy_rx_sof ,    
			eth_rx_eof_o    					=>  phy_rx_eof ,    
			eth_rx_valid_o   					=>  phy_rx_valid ,    
			
			eth_tx_data_i    					=>  phy_tx_data ,    
			eth_tx_eof_i     					=>  phy_tx_eof ,    
			eth_tx_valid_i  					=>  phy_tx_valid,     
			eth_tx_ready_o   					=>  phy_tx_ready     
		
		);	



	aes50tx : entity work.aes50_tx(rtl)
		port map(
		
			clk100_core_i 						=> clk100_i,
			clk50_ethernet_i 					=> clk50_i,
			rst_i 								=> aes_tx_rst,

			fs_mode_i 							=> fs_mode_i,
			assm_is_active_o 					=> assm_tx_is_active,
			
			audio_i 							=> fifo_tdm_to_aes_audio_data,
			audio_ch0_marker_i					=> fifo_tdm_to_aes_audio_ch0_marker,
			aux_i								=> fifo_tdm_to_aes_aux_data,
			audio_in_wr_en_i 					=> fifo_tdm_to_aes_audio_wr_en,
			aux_in_wr_en_i 						=> fifo_tdm_to_aes_aux_wr_en,
			
			audio_fifo_misalign_panic_o			=> fifo_tdm_to_aes_misalign_panic,
			
			phy_tx_data_o 						=> phy_tx_data,        
			phy_tx_eof_o  						=> phy_tx_eof,        
			phy_tx_valid_o  					=> phy_tx_valid,     
			phy_tx_ready_i  					=> phy_tx_ready,

			fifo_debug_o 						=> open
			
		);
		
    aes50rx: entity work.aes50_rx(rtl)
		port map(
			clk100_core_i 						=> clk100_i,
			clk50_ethernet_i 					=> clk50_i,
			rst_i 								=> aes_rx_rst,
			
			fs_mode_i   						=> fs_mode_i,
			
			fs_mode_detect_o					=> open,
			fs_mode_detect_valid_o				=> open,		
			assm_detect_o						=> assm_rx_is_active,		
		
			audio_o								=> fifo_aes_to_tdm_audio_data,
			audio_ch0_marker_o					=> fifo_aes_to_tdm_audio_ch0_marker,
			
			aux0_o								=> fifo_aes_to_tdm_aux_data,
			aux0_start_marker_o					=> open,
			
			aux1_o								=> fifo_aes_to_uart_aux_data,
			aux1_start_marker_o					=> fifo_aes_to_uart_aux_start_marker,
			
			audio_out_rd_en_i	 				=> fifo_aes_to_tdm_audio_rd_en,
			aux0_out_rd_en_i					=> fifo_aes_to_tdm_aux_rd_en,
			aux1_out_rd_en_i					=> fifo_aes_to_uart_aux_rd_en,
			
			fifo_fill_count_audio_o 			=> fifo_aes_to_tdm_audio_fifo_count,
			fifo_fill_count_aux0_o 				=> fifo_aes_to_tdm_aux_fifo_count,
			fifo_fill_count_aux1_o				=> fifo_aes_to_uart_aux_fifo_count,
			
			eth_rx_data_i    					=> phy_rx_data,
			eth_rx_sof_i     					=> phy_rx_sof,   
			eth_rx_eof_i      					=> phy_rx_eof,  
			eth_rx_valid_i    					=> phy_rx_valid, 
			
			eth_rx_dv_i							=> rxd_en_int,
			
			fifo_debug_o 						=> open
			
			);	
			
			
			
	aes50_uart_tx: entity work.aes50_uart_tx(rtl)
		generic map (
			g_CLKS_PER_BIT => 868     -- Needs to be set correctly
		)
		port map (
			i_Clk       => clk100_i,
			i_TX_DV     => uart_tx_enable,
			i_TX_Byte   => uart_tx_byte,
			o_TX_Active => uart_tx_busy,
			o_TX_Serial => uart_o,
			o_TX_Done   => uart_tx_done
		);
		
	
	
	aes50_aux_decoder : entity work.aes50_aux_decoder(rtl)
	
	port map (
		clk100_core_i    => clk100_i,
        rst_i            => aes_rx_rst,              
    
        
        aux_i                   	=> fifo_aes_to_uart_aux_data,
		aux_data_start_marker_i 	=> fifo_aes_to_uart_aux_start_marker,
        aux_in_rd_en_o          	=> fifo_aes_to_uart_aux_rd_en,
        fifo_fill_count_aux_i   	=> fifo_aes_to_uart_aux_fifo_count,
        
        
        
        data_out_8bit           => aux_decoder_to_fifo_data,
        data_out_valid          => aux_decoder_to_fifo_wr_en
		
	);
		
	aux_rx_uart_data_buffer : entity work.aes50_ring_buffer(rtl)
	generic map (
		RAM_WIDTH 		=> 8, 	
		RAM_DEPTH 		=> 4096 		
	)
	port map (
		clk_i 			=> clk100_i,
		rst_i 			=> aes_rx_rst,
		wr_en_i 		=> aux_decoder_to_fifo_wr_en,
		wr_data_i 		=> aux_decoder_to_fifo_data,
		rd_en_i 		=> fifo_to_uart_rd_en,
		rd_valid_o 		=> open,
		rd_data_o 		=> fifo_to_uart_data,
		empty_o 		=> open,
		empty_next_o 	=> open,
		full_o 			=> open,
		full_next_o 	=> open,
		fill_count_o 	=> fifo_to_uart_count
	);
		
	--controller for uart-tx control from aux-rx-decoder
	process (clk100_i)
	begin
		if (rising_edge(clk100_i)) then 
			if (aes_rx_rst = '1') then
				uart_tx_enable <= '0';
				uart_tx_byte <= (others=>'0');
				
				fifo_to_uart_rd_en <= '0';	
				
				fifo_uart_tx_state <= 0;
				
			else
			
				if (fifo_to_uart_count > 0 and uart_tx_busy = '0' and fifo_uart_tx_state=0) then
					fifo_to_uart_rd_en <= '1';
					fifo_uart_tx_state <= 1;		
					
				elsif (fifo_uart_tx_state = 1) then
					fifo_to_uart_rd_en <= '0';
					fifo_uart_tx_state <= 2;
					
				elsif (fifo_uart_tx_state = 2) then
					uart_tx_byte <= fifo_to_uart_data;
					uart_tx_enable <= '1';
					fifo_uart_tx_state <= 3;
					
				elsif (fifo_uart_tx_state = 3) then
					uart_tx_enable <= '0';
					fifo_uart_tx_state <= 4;
					
				elsif (fifo_uart_tx_state = 4 and uart_tx_busy = '1') then
				
					fifo_uart_tx_state <= 5;					
					
				elsif (fifo_uart_tx_state = 5 and uart_tx_done='1') then
					
					fifo_uart_tx_state <= 0;
				end if;
				
			end if;
		end if;
		
	end process;
		
		
end architecture;
