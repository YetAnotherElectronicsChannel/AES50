-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_clockmanager.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Manages all clocking related stuff of the aes50
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
-- ===========================================================================-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_clockmanager.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Manages all clocking related stuff of the aes50
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


--tdm8_i2s_mode_i
-- 0 => TDM8
-- 1 => i2s

--Note: rst_i signal in sync with clk100_i



entity aes50_clockmanager is

port (
	--system clock inputs
	clk100_i									: in std_logic;
	rst_i										: in std_logic;

	--samplerate and operation mode
	sys_mode_i									: in std_logic_vector(1 downto 0);	
	fs_mode_i									: in std_logic_vector(1 downto 0);
	tdm8_i2s_mode_i								: in std_logic;
	
	--interface to external PLL
	clk_1024xfs_from_pll_i						: in std_logic;
	pll_lock_n_i								: in std_logic;
	clk_to_pll_o								: out std_logic;
	pll_mult_value_o							: out integer;
		
	--tdm/i2s clk interface
	mclk_o										: out std_logic;
	wclk_o										: out std_logic;
	bclk_o										: out std_logic;
	wclk_readback_i								: in std_logic;
	bclk_readback_i								: in std_logic;
	
	
	--connection to clk transceivers
	aes50_clk_a_rx_i							: in std_logic;
	aes50_clk_a_tx_o							: out std_logic;
	aes50_clk_a_tx_en_o							: out std_logic;
	
	aes50_clk_b_rx_i							: in std_logic;
	aes50_clk_b_tx_o							: out std_logic;
	aes50_clk_b_tx_en_o							: out std_logic;
	
	
	--aes frame-sync-marker	
	assm_self_generated_o						: out std_logic; --outputs assm from our self-generated clock
	assm_remote_o								: out std_logic; --outputs assm from remote-clock
	
	--clk state output
	clock_health_good_o							: out std_logic;
		
	--aes-input-stream monitoring
	eth_rx_dv_watchdog_i						: in std_logic;
	eth_rx_consider_good_o						: out std_logic;
	
	
	wd_aes_clk_timeout_i						: in integer range 50 downto 0; 			-- 50@100MHz
	wd_aes_rx_dv_timeout_i					    : in integer range 20000 downto 0;			-- 15000@100MHz	
	mdix_timer_1ms_reference_i					: in integer range 100000 downto 0;		    -- 100000@100MHz
	aes_clk_ok_counter_reference_i				: in integer range 1000000 downto 0;		-- 1000000@100MHz
	--Those are the multiplicators needed if we are tdm-master as well as aes-master -> we feed the PLL with a 6.25 MHz clock generated through our 100 MHz clock-domain and multiply to get 49.152 or 45.1584...
	mult_clk625_48k_i							: in integer;								-- 8246337@100MHz
	mult_clk625_44k1_i							: in integer								-- 7576322@100MHz
	
	);
end aes50_clockmanager;

architecture rtl of aes50_clockmanager is

	--multiplication values which will be programmed to CS2100PLL - the target is, that we'll always have a 1024xfs clock (49.152 MHz for 48k, or 45.1584 MHz for 44k1)
	
	--Multiply by x4 if we get a 12.288 or 11.2896 MHz clock driven into our TDM interface (sys-mode: tdm-slave & aes-master)
	signal mult_clk_x4								: integer := 4194304;	
	
	--Multiply by x16 if we get a 3.072 MHz or 2.8224 MHz signal remotely over the AES-Interface (sys-mode: tdm-master & aes-slave)
	--the multiply by x16 is also used, when our IP just operates in I2S mode and expects an external BCLK of also 3.072/2.8224 MHz
	signal mult_clk_x16 							: integer := 16777216;	
	
	

	signal aes_clk_in								: std_logic;
	signal aes_clk_out         				 		: std_logic;

	
	--Variables and counters for 100 MHz process
	
	--6.25MHz generator
	signal clk_625MHz_cnt							: integer range 15 downto 0;
	signal clk_625MHz								: std_logic;
	
	--Watchdogs 
	signal wd_aes_rx_dv_edge						: std_logic_vector(2 downto 0);
	signal aes_clk_a_edge_100M						: std_logic_vector (2 downto 0);
	signal aes_clk_b_edge_100M						: std_logic_vector (2 downto 0);
	signal wd_aes_clk_a								: integer range 50 downto 0;
	signal wd_aes_clk_b								: integer range 50 downto 0;
	signal wd_aes_rx_dv_in							: integer range 20000 downto 0;
	signal aes_clock_ok								: std_logic;
	
	--lfsr state machine
	signal lfsr_chain								: std_logic_vector (10 downto 0);
	signal lfsr_feedback							: std_logic;
	signal lfsr_out									: std_logic;
	signal mdix										: std_logic; --0 is MDI and 1 is MDI-X
	signal mdix_timer								: integer range 100000 downto 0; --approx 1ms
	
	--initial sync start counter
	signal aes_clk_ok_counter						: integer range 1000000 downto 0;
	
	
	
	--Variables and counters for PLL-clock process
	
	--aes-clk generator counter
	signal clk_counter								: std_logic_vector (3 downto 0) := "0000";
	signal aes_clk_out_gen							: std_logic;
	
	--self assm generator
	signal aes_sync_counter							: integer range (131072-1) downto 0 := 2;
	signal assm_self_out_signal_counter 			: integer range 10 downto 0;
	signal assm_self_latch							: std_logic;
	signal assm_self_do								: integer range 2 downto 0;

	--remote ass, detect
	signal assm_remote_detect_counter				: integer range 100 downto 0;
	signal assm_remote_detect_counter_run 			: std_logic;
	signal assm_remote_out_signal_counter 			: integer range 10 downto 0;
	signal aes_clk_in_edge_PLL						: std_logic_vector (2 downto 0);	
	
	--TDM8 / I2S clock generator
	signal tdm8_bclk_mclk_counter					: integer range 3 downto 0 := 0;
	signal tdm8_wclk_counter						: integer range 1023 downto 0 := 2;
	signal i2s_bclk_counter							: integer range 15 downto 0 := 0;
	signal i2s_wclk_counter							: integer range 1023 downto 0 := 8;
	

	-- for sys_mode_i "10" -> wclk-input to aes-clock-sync
	signal wclk_in_edge 							: std_logic_vector (2 downto 0);
	signal wclk_to_aes_count_sync					: integer range 1023 downto 0 := 1023;

begin

	--LFSR chain for the clocking MDI-X change
	lfsr_feedback <= lfsr_chain(8) xor lfsr_chain(10);
	lfsr_out <= lfsr_chain(10);


	--by default in MDI (mdix=0), A is TX and B is RX
	--in MDI-X (mdix=1), A is RX and B is TX
	aes_clk_in <= aes50_clk_b_rx_i when mdix = '0' else aes50_clk_a_rx_i;

	aes_clk_out <= aes_clk_in when (sys_mode_i = "00") else aes_clk_out_gen;
	--aes_clk_out <= aes_clk_out_gen;
	aes50_clk_a_tx_o <= aes_clk_out when (mdix = '0' and rst_i='0') else '0';
	aes50_clk_b_tx_o <= aes_clk_out when (mdix = '1' and rst_i='0') else '0';


	aes50_clk_a_tx_en_o <= '1' when (mdix = '0' and rst_i='0') else '0';
	aes50_clk_b_tx_en_o <= '1' when (mdix = '1' and rst_i='0') else '0';


	--pll clk interface

		   
	clk_to_pll_o 		<= 		aes_clk_in 		when (sys_mode_i="00" and rst_i='0') else
								clk_625MHz 		when (sys_mode_i="01" and rst_i='0') else 
								bclk_readback_i   when (sys_mode_i="10" and rst_i='0') else
								'0';
					

	pll_mult_value_o 	<= 		mult_clk_x16		when (sys_mode_i="00" or (sys_mode_i="10" and tdm8_i2s_mode_i='1')) else
								mult_clk625_44k1_i 	when (sys_mode_i="01" and fs_mode_i="00") else
								mult_clk625_48k_i		when (sys_mode_i="01" and fs_mode_i="01") else
								mult_clk_x4;		--sys_mode=10 and tdm8-mode



process (clk100_i)
begin

if (rising_edge(clk100_i)) then

	if (rst_i = '1') then
		clk_625MHz_cnt <= 0;
		
		wd_aes_clk_a <= 0;
		wd_aes_clk_b <= 0;
		wd_aes_rx_dv_in <= 0;
		
		aes_clock_ok <= '0';
		clock_health_good_o <= '0';
		eth_rx_consider_good_o <= '0';
		
		mdix <= '0';
		lfsr_chain <= "10110101011";
		mdix_timer <= mdix_timer_1ms_reference_i;
		
		
		aes_clk_ok_counter <= 0;
		
		

	else
		
		--6.25MHz clock generator	
		clk_625MHz_cnt <= clk_625MHz_cnt + 1;
		
		if (clk_625MHz_cnt < 8) then
			clk_625MHz <= '1';
		else
			clk_625MHz <= '0';
		end if;
		
		
		
		--apply edge detection for aes-clk-a, aes-clk-b and wd_aes_rx_dv_edge
		aes_clk_a_edge_100M <= aes_clk_a_edge_100M(1 downto 0)&aes50_clk_a_rx_i;
		aes_clk_b_edge_100M <= aes_clk_b_edge_100M(1 downto 0)&aes50_clk_b_rx_i;
		
		wd_aes_rx_dv_edge <= wd_aes_rx_dv_edge(1 downto 0)&eth_rx_dv_watchdog_i;
		
		
		if (aes_clk_a_edge_100M(2 downto 1) = "01") then
			wd_aes_clk_a <= wd_aes_clk_timeout_i;
		else
			if (wd_aes_clk_a > 0) then
				wd_aes_clk_a <= wd_aes_clk_a - 1;
			end if;
		end if;
		
		
		if (aes_clk_b_edge_100M(2 downto 1) = "01") then
			wd_aes_clk_b <= wd_aes_clk_timeout_i;
		else
			if (wd_aes_clk_b > 0) then
				wd_aes_clk_b <= wd_aes_clk_b - 1;
			end if;
		end if;
		
		

	
		--clock health signaling
		if (wd_aes_clk_a > 0 and wd_aes_clk_b > 0  and pll_lock_n_i = '0') then		
			aes_clock_ok <= '1';
		else
			aes_clock_ok <= '0';
		end if;
		
		--check when to enable audio
		--if (wd_aes_clk_a > 0 and wd_aes_clk_b > 0 and wd_aes_rx_dv_in > 0) then
		if (wd_aes_clk_a > 0 and wd_aes_clk_b > 0) then
			if (aes_clk_ok_counter < aes_clk_ok_counter_reference_i) then
				aes_clk_ok_counter <= aes_clk_ok_counter + 1;
			else
				clock_health_good_o <= '1';
			end if;
		else
			aes_clk_ok_counter <= 0;
			clock_health_good_o <= '0';
		end if;
		
		
		--this is the rmii_rx_dv watchdog		
		if (wd_aes_rx_dv_edge(2 downto 1) = "01") then
			wd_aes_rx_dv_in <= wd_aes_rx_dv_timeout_i;
		else
			if (wd_aes_rx_dv_in > 0) then
				wd_aes_rx_dv_in <= wd_aes_rx_dv_in - 1;	
			end if;
		end if;
		
		if (wd_aes_rx_dv_in > 0) then
			eth_rx_consider_good_o <= '1';
		else
			eth_rx_consider_good_o <= '0';
		end if;
		
		
		--this is the mdix-state-machine implementation	
		
		if mdix_timer > 0 then
			mdix_timer <= mdix_timer - 1;
			
		--timer is 0
		else
			lfsr_chain <= lfsr_chain(9 downto 0) & lfsr_feedback; --update chain every 1ms
			mdix_timer <= mdix_timer_1ms_reference_i; --restart timer
			
			if (mdix='0' and lfsr_out = '1' and aes_clock_ok = '0') then
						
				mdix <= '1';
			
			elsif (mdix='1' and lfsr_out= '0' and aes_clock_ok = '0') then
				mdix <= '0';
				
			end if;
		end if;

		
	end if;
end if;

end process;



process (clk_1024xfs_from_pll_i, rst_i)
begin

if rst_i='1' then

	clk_counter <= "0000";
	aes_sync_counter <= 2;
	assm_self_latch <= '0';
	assm_self_do <= 0;
	assm_self_out_signal_counter <= 0;
	wclk_to_aes_count_sync <= 1023;
	
elsif (rising_edge(clk_1024xfs_from_pll_i)) then

	
		aes_clk_in_edge_PLL <= aes_clk_in_edge_PLL(1 downto 0)&aes_clk_in;
		
		if (aes_clk_in_edge_PLL(2 downto 1) = "01") then		
			assm_remote_detect_counter <= 0;
			assm_remote_detect_counter_run <= '1';
			
		elsif (aes_clk_in_edge_PLL(2 downto 1) = "10") then
			if (assm_remote_detect_counter>8) then		
				--detected
				assm_remote_out_signal_counter <= 10;			
			end if;
			assm_remote_detect_counter_run <= '0';
		else
			if (assm_remote_out_signal_counter > 0) then
				assm_remote_out_signal_counter <= assm_remote_out_signal_counter - 1;
				assm_remote_o <= '1';
			else
				assm_remote_o <= '0';
			end if;
			
			if (assm_remote_detect_counter_run = '1') then
				assm_remote_detect_counter <= assm_remote_detect_counter + 1;
			end if;
			
		end if;
	
	

	
	--running continously..

	clk_counter <= std_logic_vector( unsigned(clk_counter) + to_unsigned(1,4) );
	

	
	--this aes-sync counter is only needed in case of fs_mode_i 01
	if (clk_counter = "1111") then
	
		if (tdm8_i2s_mode_i = '0') then
			wclk_in_edge <= wclk_in_edge(1 downto 0)&wclk_readback_i;	
		else
			--in i2s mode, we need to negate the wclk_readback as left-sample in i2s starts with wclk=low, instead of high-pulse in tdm8
			wclk_in_edge <= wclk_in_edge(1 downto 0)&(not wclk_readback_i);	
		end if;
		
		--sync one time after reset
		if (sys_mode_i = "10" and wclk_to_aes_count_sync > 0 and wclk_in_edge(2 downto 1) = "01") then
			aes_sync_counter <= 0;
			wclk_to_aes_count_sync <= wclk_to_aes_count_sync - 1;
			
		else
			if (aes_sync_counter < 131071) then
				aes_sync_counter <= aes_sync_counter + 1;
			else
				aes_sync_counter <= 0;
			end if; 

			
		end if;
	end if;
	
	

	--aes clock output generator with assm markers	

	--this is the start condition for initiating the assm sync-marker
	if ( ( (sys_mode_i="01") or (sys_mode_i="10" and wclk_to_aes_count_sync=0)) and aes_sync_counter=0 and clk_counter="0000") then
		assm_self_out_signal_counter <= 10;
	   
    else
		if (assm_self_out_signal_counter > 0) then
			assm_self_out_signal_counter <= assm_self_out_signal_counter - 1;
			assm_self_generated_o <= '1';
			assm_self_latch <= '1';
		else
			assm_self_generated_o <= '0';
			
			if (assm_self_do = 2 and assm_self_latch = '1' and clk_counter = "1111" ) then
				assm_self_latch <= '0';
			end if;
			
		end if;
		
    end if; 	
	
	--this generates the actual clock
	if    (clk_counter="0000" and assm_self_latch = '1' and assm_self_do = 0) then
		assm_self_do <= 1;
	elsif (clk_counter="0000" and assm_self_latch = '1' and assm_self_do = 1) then
		assm_self_do <= 2;
	elsif (clk_counter = "1111" and assm_self_do=2) then
		assm_self_do <= 0;
	end if;
	
	--do short pulse
	if (assm_self_do = 1) then
		if (unsigned(clk_counter) < to_unsigned(6,4) ) then
			aes_clk_out_gen <= '1';
		else
			aes_clk_out_gen <= '0';
		end if;
	--do long pulse	
	elsif (assm_self_do = 2) then
		if (unsigned(clk_counter) < to_unsigned(10,4) ) then
			aes_clk_out_gen <= '1';
		else
			aes_clk_out_gen <= '0';
		end if;
		
	--do normal pulse
	else
		if (unsigned(clk_counter) < to_unsigned(8,4) ) then
			aes_clk_out_gen <= '1';
		else
			aes_clk_out_gen <= '0';
		end if;
	end if;
	
	
	

	--this counter always runs, because it's not only the TDM8-BCLK, but also the MCLK which is probably needed for external I2S devices.
	if (tdm8_bclk_mclk_counter <3 ) then
		tdm8_bclk_mclk_counter <= tdm8_bclk_mclk_counter + 1;
	else
		tdm8_bclk_mclk_counter <= 0;
	end if;
	if (tdm8_bclk_mclk_counter < 2) then				
		mclk_o <= '1';
	else				
		mclk_o <= '0';
	end if;
		
		
	if (tdm8_i2s_mode_i = '0') then	
	
		--Clock Generator for TDM8 Mode	
		
		if (tdm8_wclk_counter < 1023) then
			tdm8_wclk_counter <= tdm8_wclk_counter + 1;
		else
			tdm8_wclk_counter <= 0;
		end if;
		
		if (tdm8_wclk_counter < 32) then				
			wclk_o <= '1';
		else				
			wclk_o <= '0';
		end if;
		
		if (tdm8_bclk_mclk_counter < 2) then				
			bclk_o <= '1';
		else				
			bclk_o <= '0';
		end if;
	
	else
	
		--Clock Generator for I2S Mode
		
		if (i2s_bclk_counter <15 ) then
			i2s_bclk_counter <= i2s_bclk_counter + 1;
		else
			i2s_bclk_counter <= 0;
		end if;
		
		if (i2s_wclk_counter < 1023) then
			i2s_wclk_counter <= i2s_wclk_counter + 1;
		else
			i2s_wclk_counter <= 0;
		end if;
		
		if (i2s_wclk_counter < 512) then				
			wclk_o <= '0';
		else				
			wclk_o <= '1';
		end if;
		
		if (i2s_bclk_counter < 8) then				
			bclk_o <= '1';
		else				
			bclk_o <= '0';
		end if;
		
	end if;
	
	


	
end if;

end process;
end architecture;
