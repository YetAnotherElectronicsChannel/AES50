-- ###########################################################################
-- # Project      : AES50 VHDL IP-CORE
-- # File         : <aes50_ring_buffer.vhd>
-- # Author       : Markus Noll (YetAnotherElectronicsChannel) / vhdlwhiz.com
-- # Created      : <2025-02-26>
-- #
-- # Description  :
-- #    Standard Ring Buffer Template - should usually work with all FPGAs...
-- #	Originally sourced from vhdlwhiz.com 
-- #	Modified a bit port-naming...
-- #
-- # License      : No license information provided from original source
-- #
-- #
-- ###########################################################################

library ieee;
use ieee.std_logic_1164.all;

entity aes50_ring_buffer is
  generic (
    RAM_WIDTH : natural;
    RAM_DEPTH : natural
  );
  port (
    clk_i 				: in std_logic;
    rst_i 				: in std_logic;

    -- Write port
    wr_en_i 			: in std_logic;
    wr_data_i 			: in std_logic_vector(RAM_WIDTH - 1 downto 0);

    -- Read port
    rd_en_i 			: in std_logic;
    rd_valid_o 			: out std_logic;
    rd_data_o 			: out std_logic_vector(RAM_WIDTH - 1 downto 0);

    -- Flags
    empty_o 			: out std_logic;
    empty_next_o 		: out std_logic;
    full_o 				: out std_logic;
    full_next_o 		: out std_logic;

    -- The number of elements in the FIFO
    fill_count_o 		: out natural range 0 to RAM_DEPTH - 1
  );
end aes50_ring_buffer;

architecture rtl of aes50_ring_buffer is

  type ram_type is array (0 to RAM_DEPTH - 1) of std_logic_vector(wr_data_i'range);
  signal ram : ram_type;

  subtype index_type is natural range ram_type'range;
  signal head : index_type;
  signal tail : index_type;

  signal empty_i : std_logic;
  signal full_i : std_logic;
  signal fill_count_i : natural range 0 to RAM_DEPTH - 1;

  -- Increment and wrap
  procedure incr(signal index : inout index_type) is
  begin
    if index = index_type'high then
      index <= index_type'low;
    else
      index <= index + 1;
    end if;
  end procedure;

begin

  -- Copy internal signals to output
  empty_o <= empty_i;
  full_o <= full_i;
  fill_count_o <= fill_count_i;

  -- Set the flags
  empty_i <= '1' when fill_count_i = 0 else '0';
  empty_next_o <= '1' when fill_count_i <= 1 else '0';
  full_i <= '1' when fill_count_i >= RAM_DEPTH - 1 else '0';
  full_next_o <= '1' when fill_count_i >= RAM_DEPTH - 2 else '0';

  -- Update the head pointer in write
  PROC_HEAD : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        head <= 0;
      else

        if wr_en_i = '1' and full_i = '0' then
          incr(head);
        end if;

      end if;
    end if;
  end process;

  -- Update the tail pointer on read and pulse valid
  PROC_TAIL : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        tail <= 0;
        rd_valid_o <= '0';
      else
        rd_valid_o <= '0';

        if rd_en_i = '1' and empty_i = '0' then
          incr(tail);
          rd_valid_o <= '1';
        end if;

      end if;
    end if;
  end process;

  -- Write to and read from the RAM
  PROC_RAM : process(clk_i)
  begin
    if rising_edge(clk_i) then
      ram(head) <= wr_data_i;
      rd_data_o <= ram(tail);
    end if;
  end process;

  -- Update the fill count
  PROC_COUNT : process(head, tail)
  begin
    if head < tail then
      fill_count_i <= head - tail + RAM_DEPTH;
    else
      fill_count_i <= head - tail;
    end if;
  end process;

end architecture;