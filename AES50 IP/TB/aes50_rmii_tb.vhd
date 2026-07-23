-- ===========================================================================
-- Project      : AES50 VHDL IP-CORE
-- File         : <aes50_rmii_tb.vhd>
-- Author       : Markus Noll (YetAnotherElectronicsChannel)
-- Created      : <2025-02-26>
-- 
-- Description  : Testbench to check RMII module
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


entity aes50_rmii_tb is
--  Port ( );
end aes50_rmii_tb;

architecture Behavioral of aes50_rmii_tb is


    signal clk50 																			: std_logic := '0';
    signal reset																			: std_logic := '1';
    
    signal rmii_txd 																		: std_logic_vector (1 downto 0) := (others=>'0');
    signal rmii_rxd 																		: std_logic_vector (1 downto 0) := (others=>'0');
	
	
    signal rmii_rxd_dv, rmii_rxd_err, rmii_txd_en 											: std_logic := '0';    
    signal eth_rx_data, eth_tx_data 														: std_logic_vector (7 downto 0) := (others=>'0');
    signal eth_rx_sof, eth_rx_eof, eth_rx_valid, eth_tx_eof, eth_tx_valid, eth_tx_ready 	: std_logic := '0';     
             

    
begin

    clk50 <= not clk50 after 10ns;
    reset <= '1', '0' after 100ns;
    
    rmii_1 : entity work.aes50_rmii_transceiver(rtl)
    port map(
    
		clk50_i  			=> clk50,             
		rst_i  				=> reset,             
  
		rmii_crs_dv_i 		=> rmii_txd_en,        
		rmii_rxd_i  		=> rmii_txd,         
		rmii_tx_en_o 		=> rmii_txd_en,         
		rmii_txd_o   		=> rmii_txd,        

		-- stream bus alike interface to MAC
		eth_rx_data_o   	=> eth_rx_data ,    
		eth_rx_sof_o    	=> eth_rx_sof ,    
		eth_rx_eof_o    	=> eth_rx_eof ,    
		eth_rx_valid_o   	=> eth_rx_valid ,    
		
		eth_tx_data_i    	=> eth_tx_data ,    
		eth_tx_eof_i     	=> eth_tx_eof ,    
		eth_tx_valid_i  	=> eth_tx_valid,     
		eth_tx_ready_o   	=> eth_tx_ready      
    
    );
    
    
    
  stimulus:
  process begin
    -- Wait for the Reset to be released before 
    wait until (reset = '0');
    wait for 50ns;
    wait until (clk50 = '0');
	
    eth_tx_data <= x"55";
    eth_tx_valid <= '1';
    
    for i in 0 to 10 loop
	
        wait until rising_edge(clk50) and eth_tx_ready='1';
		      
		if (i = 10) then
			eth_tx_eof <= '1';
		end if;
	
		eth_tx_data <= std_logic_vector( to_unsigned( i*i, 8));
		
		
    end loop;
	
    wait until rising_edge(clk50) and eth_tx_ready='1';
    eth_tx_valid <= '0';
    eth_tx_eof <= '0';
 
    
    wait;
  end process stimulus;

end Behavioral;
