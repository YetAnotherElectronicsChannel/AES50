-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <i2c_controller_tb.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Testbench to check the CS2x00 PLL I2C driver module.
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


entity i2c_controller_tb is
--  Port ( );
end i2c_controller_tb;

architecture Behavioral of i2c_controller_tb is
    signal clk100 				: std_logic := '0';
    signal rst				: std_logic := '1';


	signal sda, scl         : std_logic := '0';
	signal muxdata          : std_logic_vector (3 downto 0) := x"8";
	signal pll_mult			: integer := 0;
	
	signal clk3072 	: integer := 16777216;
	signal clk625 	: integer := 8246337;
	signal clk12288 : integer := 4194304;
	
	signal sda_in, scl_in, sda_enable, scl_enable, scl_out, sda_out : std_logic := '0';
	
	signal cs2000_init_busy	: std_logic;

begin
    clk100 <= not clk100 after 5ns;
    rst <= '1', '0' after 100ns;

	sda <= sda_out when (sda_enable='1') else 'Z';
	scl <= scl_out when (scl_enable='1') else 'Z';
	sda_in <= sda;
	scl_in <= scl;

i2c : entity work.i2c_controller(rtl)
port map(
			clk => clk100,
			rst => rst,
			pll_mult_in => pll_mult,
			mux_in => muxdata,
			cs2000_init_busy => cs2000_init_busy,
			sda_in => sda_in,                    
			scl_in => scl_in,
			sda_enable => sda_enable,
			scl_enable => scl_enable,
			scl_out	=> scl_out,
			sda_out	=> sda_out
           );

	
	
stimulus: process begin

	wait for 6ms;
	muxdata <= x"5";
	wait for 1ms;
	muxdata <= x"1";
	wait for 1ms;
	pll_mult <= clk3072;
	wait for 5ms;
	pll_mult <= clk12288;
	wait for 5ms;
	muxdata <= x"3";
	wait for 1sec;

end process stimulus;



end Behavioral;
