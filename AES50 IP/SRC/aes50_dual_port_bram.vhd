-- ###########################################################################
-- # Project      : AES50 VHDL IP-CORE
-- # File         : <aes50_dual_port_bram.vhd>
-- # Author       : Markus Noll (YetAnotherElectronicsChannel) / Xilinx
-- # Created      : <2025-02-26>
-- #
-- # Description  :
-- #    Standard Block-Ram Template - should usually work with all FPGAs...
-- #	Originally sourced from Xilinx documentation  (https://docs.amd.com/r/en-US/ug901-vivado-synthesis/Dual-Port-Block-RAM-with-Two-Write-Ports-in-Read-First-Mode-VHDL)
-- #	Modified a bit port-naming...
-- #
-- # License      : No license information provided from original source
-- #
-- #
-- ###########################################################################

library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_dual_port_bram is
  generic (
		RAM_WIDTH : natural;
		RAM_DEPTH : natural
  );
	port(
		clka_i 				: in std_logic;
		clkb_i 				: in std_logic;
		ena_i 				: in std_logic;
		enb_i 				: in std_logic;
		wea_i 				: in std_logic;
		web_i 				: in std_logic;
		addra_i 			: in natural range 0 to RAM_DEPTH - 1;
		addrb_i 			: in natural range 0 to RAM_DEPTH - 1;
		da_i 				: in std_logic_vector(RAM_WIDTH - 1 downto 0);
		db_i 				: in std_logic_vector(RAM_WIDTH - 1 downto 0);
		da_o 				: out std_logic_vector(RAM_WIDTH - 1 downto 0);
		db_o 				: out std_logic_vector(RAM_WIDTH - 1 downto 0)
	);
end aes50_dual_port_bram;

architecture rtl of aes50_dual_port_bram is
	type ram_type is array (RAM_DEPTH - 1 downto 0) of std_logic_vector(RAM_WIDTH - 1 downto 0);
	shared variable RAM : ram_type;
	
	begin
		process(clka_i)
			begin
				if rising_edge(clka_i) then
					if ena_i = '1' then
						da_o <= RAM(addra_i);
						if wea_i = '1' then
							RAM(addra_i) := da_i;
						end if;
					end if;
			end if;
		end process;

		process(clkb_i)
			begin
				if rising_edge(clkb_i) then
					if enb_i = '1' then
						db_o <= RAM(addrb_i);
						if web_i = '1' then
							RAM(addrb_i) := db_i;
						end if;
					end if;
				end if;
	end process;

end rtl;

