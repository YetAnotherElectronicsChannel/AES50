-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <eval_aes50_top.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : AES50 top-file for eval-board
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


entity eval_aes50_top is
port 	(

	--logic clocking, lock, reset
	CLK_25M 					: in  std_logic; 
	CLK_50M 					: in  std_logic; 
	CLK_80M						: in  std_logic;
	CLK_100M 					: in  std_logic; 
	LOGIC_PLL_LOCK 				: in  std_logic; 
	LOGIC_RESET 				: in  std_logic; 
	
	--audio pll interface
	APLL_REF 					: out  std_logic;
	APLL_MCLK 					: in  std_logic; 
	APLL_LOCK_N 				: in  std_logic; 
	   
	--i2c interface for APLL
	I2C_SCL_IN 					: in  std_logic; 
	I2C_SCL_OUT 				: out  std_logic; 
	I2C_SCL_OE 					: out  std_logic; 
	I2C_SDA_IN 					: in  std_logic; 
	I2C_SDA_OUT 				: out  std_logic; 
	I2C_SDA_OE 					: out  std_logic; 
   
	--MCU interface
	FPGA_SPARE_GPIO_UART_IN 	: in  std_logic; 
	UART_OUT 					: out  std_logic;
	SAMPLERATE_SELECT 			: in  std_logic; 
	SYSTEM_CFG 					: in  std_logic_vector(1 downto 0);	
	AES50_GOOD	 				: out  std_logic; 
	
	--AES50 Clock-interface
	AES_CLK_A_RX 				: in  std_logic; 
	AES_CLK_A_TX 				: out  std_logic; 
	AES_CLK_A_TX_EN 			: out  std_logic; 
	AES_CLK_B_RX 				: in  std_logic; 
    AES_CLK_B_TX 				: out  std_logic; 
	AES_CLK_B_TX_EN 			: out  std_logic;   
   
    --AES50 Phy interface
	AES_PHY_RST_N 				: out  std_logic; 
	CLK_50M_OUT_HI 				: out std_logic;
	CLK_50M_OUT_LO 				: out std_logic;	
	AES_RXD 					: in  std_logic_vector(1 downto 0);
	AES_RX_DV 					: in  std_logic; 
	AES_TXD 					: out  std_logic_vector(1 downto 0);
	AES_TXD_EN 					: out  std_logic; 

	--TDM interface
	TDM_BCLK_IN 				: in  std_logic; 
	TDM_WCLK_IN 				: in  std_logic; 
	TDM_BCLK_OUT 				: out  std_logic; 
	TDM_BCLK_OE 				: out  std_logic; 
	TDM_WCLK_OUT 				: out  std_logic; 
	TDM_WCLK_OE 				: out  std_logic;
	TDM_IN 						: in  std_logic_vector(6 downto 0);
	TDM_OUT 					: out  std_logic_vector(6 downto 0);
		
	--DEBUG signals
	LED 						: out  std_logic; 
	FPGA_DEBUG 					: out  std_logic_vector(7 downto 0)
	
	);
end eval_aes50_top;


architecture rtl of eval_aes50_top is

	--variables for clean reset generation
	signal reset 		: std_logic;
	signal reset_cnt 	: integer range 1023 downto 0;
	
	--signals for internal samplerate-mode and system-mode
	signal fs_mode		: std_logic_vector (1 downto 0);
	signal sys_mode		: std_logic_vector (1 downto 0);
	
	--other internal signals
	signal aes_ok			: std_logic;
	signal pll_mult_value 	: integer;
	signal pll_init_busy 	: std_logic;
	
	--tdm internal signals
	signal tdm8_i2s_mode    : std_logic;
	signal tdm_int_o		: std_logic_vector(6 downto 0);
	signal i2s_int_o		: std_logic;
begin

	--static assignments
	CLK_50M_OUT_HI <= '1';
	CLK_50M_OUT_LO <= '0';	
	AES50_GOOD <= aes_ok;
	
	tdm8_i2s_mode <= FPGA_SPARE_GPIO_UART_IN;
	
	TDM_OUT <= tdm_int_o when (tdm8_i2s_mode = '0') else ("000000"&i2s_int_o);
	
	 
	
	--reset generator & system-cfg / fs-mode input latching
	process (CLK_100M)
	begin
		if (rising_edge(CLK_100M)) then
			if (LOGIC_PLL_LOCK='0' or LOGIC_RESET = '1') then
			
				--if any reset condition is triggered, we'll apply the actual logic reset for 1024 cycles
				--our internal reset is active-high
				reset <= '1';
				reset_cnt <= 1023;
			else
			
				if (reset_cnt>0) then
				
					reset_cnt <= reset_cnt - 1;
				
					--in the last cycle before reset is released, we save back the fs-mode and sys-mode variables
					if (reset_cnt = 1) then
					
						--check sample-rate mode => only 44k1 and 48k currently supported
						if (SAMPLERATE_SELECT = '1') then
							fs_mode <= "00"; --44k1
							LED <= '0';
						else				
							fs_mode <= "01"; --48k
							LED <= '1';
						end if;
						
						--check system-configuration-mode
						--if "00" 			-> aes-slave; tdm-master
						--if "01" 			-> aes-master, tdm-master
						--if "10" or "11" 	-> aes-master, tdm-slave
						if SYSTEM_CFG = "11" then
							--"11" is not a valid option, therefore we set this also to "10"
							sys_mode <= "10"; 
						else
							sys_mode <= SYSTEM_CFG;
						end if;
						
					end if;
				
				else
					reset <= '0';
				end if;
			end if;
		end if;
		
	end process;
	
	
	--instance of the main AES50 module
	aes50 : entity work.aes50_top(rtl)
	port map(
			clk50_i									=> CLK_50M,
			clk100_i 								=> CLK_100M,
			rst_i									=> reset,
			
			fs_mode_i								=> fs_mode,
			sys_mode_i								=> sys_mode,
			tdm8_i2s_mode_i							=> tdm8_i2s_mode,
			
			rmii_crs_dv_i  							=> AES_RX_DV,        
			rmii_rxd_i   							=> AES_RXD,         
			rmii_tx_en_o 							=> AES_TXD_EN,         
			rmii_txd_o   							=> AES_TXD,     
			phy_rst_n_o								=> AES_PHY_RST_N,

			aes50_clk_a_rx_i 						=> AES_CLK_A_RX,
			aes50_clk_a_tx_o						=> AES_CLK_A_TX,
			aes50_clk_a_tx_en_o						=> AES_CLK_A_TX_EN,
	
			aes50_clk_b_rx_i 						=> AES_CLK_B_RX,
			aes50_clk_b_tx_o						=> AES_CLK_B_TX,
			aes50_clk_b_tx_en_o						=> AES_CLK_B_TX_EN,
			
			clk_1024xfs_from_pll_i 					=> APLL_MCLK,
			pll_lock_n_i 							=> APLL_LOCK_N,
			clk_to_pll_o							=> APLL_REF,
			pll_mult_value_o						=> pll_mult_value,
			pll_init_busy_i 						=> pll_init_busy,
			
			mclk_o									=> open,
			wclk_o 									=> TDM_WCLK_OUT,
			bclk_o 									=> TDM_BCLK_OUT,
			wclk_readback_i 						=> TDM_WCLK_IN,
			bclk_readback_i 						=> TDM_BCLK_IN,
			wclk_out_en_o							=> TDM_WCLK_OE,
			bclk_out_en_o							=> TDM_BCLK_OE,
			
			tdm_i									=> TDM_IN,
			tdm_o									=> tdm_int_o,
			i2s_i									=> TDM_IN(0),
			i2s_o									=> i2s_int_o,
			
			aes_ok_o								=> aes_ok,			
							
			dbg_o									=> FPGA_DEBUG,
			
            uart_o                                  => UART_OUT,
            
			--variables for if coreclock = 100 MHz
			debug_out_signal_pulse_len_i			=>	1000000,
			first_transmit_start_counter_48k_i		=>	4249500,
			first_transmit_start_counter_44k1_i		=>	4610800,
		
			wd_aes_clk_timeout_i					=> 	50,
			wd_aes_rx_dv_timeout_i			    	=>	15000,	
			mdix_timer_1ms_reference_i				=>	100000,
			aes_clk_ok_counter_reference_i			=>	1000000,
			--Those are the multiplicators needed if we are tdm-master as well as aes-master -> we feed the PLL with a 6.25 MHz clock generated through our 100 MHz clock-domain and multiply to get 49.152 or 45.1584...
			mult_clk625_48k_i						=>	8246337,
			mult_clk625_44k1_i						=>	7576322
			
			--variables for if coreclock = 80 MHz
			--debug_out_signal_pulse_len_i			=>	800000,
			--first_transmit_start_counter_48k_i	=>	3399600,
			--first_transmit_start_counter_44k1_i	=>	3688640,
		
			--wd_aes_clk_timeout_i					=> 	40,
			--wd_aes_rx_dv_timeout_i			    =>	12000,	
			--mdix_timer_1ms_reference_i			=>	80000,
			--aes_clk_ok_counter_reference_i		=>	800000,
			--Those are the multiplicators needed if we are tdm-master as well as aes-master -> we feed the PLL with a 6.25 MHz clock generated through our 100 MHz clock-domain and multiply to get 49.152 or 45.1584...
			--mult_clk625_48k_i						=>	10307922,
			--mult_clk625_44k1_i					=>	9470403
			
			);
			


	--cs2100 i2c driver -> programs mult-value when needed and gives information if is busy or not
	i2c : entity work.aes50_cs2x00_pll_controller(rtl)
	port map(
			clk_i 						=> CLK_100M,
			rst_i 						=> reset,
			pll_mult_value_i 			=> pll_mult_value,
			cs2x00_init_busy_o 			=> pll_init_busy,
			sda_i      					=> I2C_SDA_IN,                   
			scl_i      					=> I2C_SCL_IN,
			sda_en_o					=> I2C_SDA_OE, 
			scl_en_o  					=> I2C_SCL_OE,
			scl_o						=> I2C_SCL_OUT, 
			sda_o						=> I2C_SDA_OUT
           );
		   

	
end architecture;
	