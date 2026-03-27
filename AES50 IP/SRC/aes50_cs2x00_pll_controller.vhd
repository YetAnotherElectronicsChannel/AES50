-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_cs2x00_pll_controller.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
--
-- Description  : Handles the init of the CS2x00 PLL chip over I2C and re-updates if a new multiplier-value is needed...
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

entity aes50_cs2x00_pll_controller is
    Port ( 	clk_i 					: in  std_logic;
			rst_i 					: in  std_logic;
			pll_mult_value_i		: in  natural;
			cs2x00_init_busy_o		: out std_logic;
			sda_i      				: in  std_logic;                    
			scl_i      				: in  std_logic;
			sda_en_o				: out std_logic;
			scl_en_o  				: out std_logic;
			scl_o					: out std_logic;
			sda_o					: out std_logic);
end aes50_cs2x00_pll_controller;

architecture rtl of aes50_cs2x00_pll_controller is


	signal sigBusy,reset,enable,readwrite,nack : std_logic;

	signal dataOut : std_logic_vector(7 downto 0);
	signal address : std_logic_vector(6 downto 0);

	signal ResetWaitCounter : natural range 0 to 16383:= 16383;

	signal i2c_state : natural range 0 to 7 := 0;
	signal cs2000counter: natural range 0 to 15 := 0;

	signal pll_mult : std_logic_vector (31 downto 0) := (others=>'0');
	signal pll_mult_old : natural := 0;
	



	--i2c for cs2000: 7-Bit address: 0x4e (100 1110 + rw) -> write per sequence reg-addr + reg-value
	--cs2000 init sequence:
	--addr : value
	--0x03 : 0x07 --> aux-pin as pll-lock + device-config enable1
	--0x05 : 0x09 --> freeze-bit to 1 + device-config enable 2
	--0x17 : 0x18 --> clock-output if pll unlocked + high-accuracy mode
	--0x16 : 0x08 --> clock-skip disable + ref-clock div to "01" -> 16 MHz to 28 MHz range
	--0x1e : 0x00 --> Loop-Bandwidth to 1 Hz
	--0x04 : 0x01 --> Hybrid-PLL mode and lock-clock-ratio->0

	--0x06: mult-value(31 downto 24)
	--0x07 : mult-value (23 downto 16)
	--0x08 : mult-value (15 downto 8)
	--0x09 : mult-value (7 downto 0)

	--0x02 : 0x00 -> enable clk_i & aux output
	--0x05 : 0x01 --> set freeze to 0 -> changes take effect immediately


	type cs2000_cfg_lut_t is array (0 to 11, 0 to 1) of std_logic_vector(7 downto 0);
	constant par_lut: cs2000_cfg_lut_t:=(
		( x"03", x"07"),
		( x"05", x"09"),
		( x"17", x"18"),
		( x"16", x"08"),
		( x"1e", x"00"),
		( x"04", x"01"),
		( x"06", x"FF"),
		( x"07", x"FF"),
		( x"08", x"FF"),
		( x"09", x"FF"),
		( x"02", x"00"),
		( x"05", x"01")
		);




begin

i2c_comm: entity work.aes50_i2c_master(rtl)
port map (
    clk_i			=> clk_i,
    rst_n_i			=> reset,
    en_i			=> enable,
    addr_i			=> address,
    rw_i			=> readwrite,
    data_wr_i		=> dataOut,
    busy_o			=> sigBusy,
    data_rd_o		=> OPEN,
    ack_error_bfr	=> nack,
	sda_i 			=> sda_i,                    
	scl_i 			=> scl_i,
	sda_en_o 		=> sda_en_o,
	scl_en_o 		=> scl_en_o,
	scl_o			=> scl_o,
	sda_o			=> sda_o
	);
	

process (clk_i)
begin

	if rising_edge(clk_i) then
		
	
		if rst_i = '1' or pll_mult_old /= pll_mult_value_i then
			ResetWaitCounter 	<= 16383;
			i2c_state 			<= 0;
			cs2000counter 		<= 0;
			
			pll_mult_old 		<= pll_mult_value_i;					
			pll_mult 			<= std_logic_vector(to_unsigned(pll_mult_value_i,32));
                 		
			cs2x00_init_busy_o 	<= '1';
			
		else
			
			--reset the i2c-master controller	
			
			case i2c_state is	
				when 0 =>
				
					if ResetWaitCounter > 0 then
						ResetWaitCounter<=ResetWaitCounter-1;
						reset<='0';
						enable<='0';
					else
						reset<='1';					
						readwrite<='0';
						i2c_state <= 1;
					end if;
					
				--process the pll controller

				--set enable and write i2c-address and first byte (basically cs2000 internal adress defined in par_lut table)
				when 1 =>			
					enable<='1';
					address<= "1001110";
					dataOut <= par_lut(cs2000counter,0);
					
					i2c_state <= 2;	
					
				--wait for sigBusy=1
				when 2 =>			
					if (sigBusy = '1') then
						i2c_state <= 3;
					end if;
					
				--wait for sigBusy=0 to write next data -> (basically cs2000 internal data matching the internal address defined previously)
				when 3 =>

					if (sigBusy = '0') then
					
						case par_lut(cs2000counter, 0) is
							when x"06"  => dataOut <= pll_mult(31 downto 24);
							when x"07"  => dataOut <= pll_mult(23 downto 16);
							when x"08"  => dataOut <= pll_mult(15 downto 8);
							when x"09"  => dataOut <= pll_mult(7 downto 0);
							when others => dataOut <= par_lut(cs2000counter, 1);
						end case;
												
						i2c_state <= 4;	
					end if;
					--if we need to send the multiplier-value which is dynamic
						
					
				--wait for sigBusy=1
				when 4 =>
					if (sigBusy = '1') then
						i2c_state <= 5;
					end if;
					
				--wait for sigBusy=0 and disable and set timeout to wait for next transaction	
				when 5 =>
					if (sigBusy = '0') then
						enable <= '0';
						ResetWaitCounter <= 16383;
						i2c_state <= 6;
					end if;
				
							
					
					
				--check if timeout has passed -> if yes check if we need to send next byte to cs2000 controller or if we continue with mux-controller
				when 6 =>
				
					if ResetWaitCounter > 0 then
						ResetWaitCounter <= ResetWaitCounter - 1;
					else
					
						if (cs2000counter < 11) then
							cs2000counter <= cs2000counter +1;
							i2c_state <= 1;
						else
						
							i2c_state <= 7;
							cs2x00_init_busy_o <= '0';
						end if;
					end if;				

				
				when others => null;
			end case;
		end if;
	end if;
end process;


end architecture;
