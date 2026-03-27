--------------------------------------------------------------------------------
--
--   FileName:         i2c_master.vhd
--   Dependencies:     none
--   Design Software:  Quartus II 64-bit Version 13.1 Build 162 SJ Full Version
--
--   HDL CODE is PROVIDED "AS is."  DIGI-KEY EXPRESSLY DISCLAIMS ANY
--   WARRANTY of ANY KIND, WHETHER EXPRESS or IMPLIED, INCLUDING BUT NOT
--   LIMITED to, THE IMPLIED WARRANTIES of MERCHANTABILITY, FITNESS FOR A
--   PARTICULAR PURPOSE, or NON-INFRINGEMENT. in NO EVENT SHALL DIGI-KEY
--   BE LIABLE FOR ANY INCIDENTAL, SPECIAL, INDIRECT or CONSEQUENTIAL
--   DAMAGES, LOST PROFITS or LOST DATA, HARM to YOUR EQUIPMENT, COST of
--   PROCUREMENT of SUBSTITUTE GOODS, TECHNOLOGY or SERVICES, ANY CLAIMS
--   BY THIRD PARTIES (INCLUDING BUT NOT LIMITED to ANY DEFENSE THEREOF),
--   ANY CLAIMS FOR INDEMNITY or CONTRIBUTION, or OTHER SIMILAR COSTS.
--
--   Version History
--   Version 1.0 11/1/2012 Scott Larson
--     Initial Public Release
--   Version 2.0 06/20/2014 Scott Larson
--     Added ability to interface with different slaves in the same transaction
--     Corrected ack_error_bfr bug where ack_error_bfr went 'Z' instead of '1' on error
--     Corrected timing of when ack_error_bfr signal clears
--   Version 2.1 10/21/2014 Scott Larson
--     Replaced gated clock with clock enable
--     Adjusted timing of SCL during start and stop conditions
-- 	
--	 Version 3.0 1/2/2025 Markus Noll
--		Modified for separate output of sda/clk_i enable as well as sda/clk_i in & outs to support FPGA platforms which cannot handle "inout" (Efinix Trion)
--------------------------------------------------------------------------------

LIBRARY ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes50_i2c_master is
  generic(
    input_clk 		: natural := 100_000_000; 				--input clock speed from user logic in Hz
    bus_clk   		: natural := 100_000);   				--speed the i2c bus (scl) will run at in Hz
  port(
    clk_i       	: in     std_logic;                    	--system clock
    rst_n_i   		: in     std_logic;                    	--active low reset
    en_i       		: in     std_logic;                    	--latch in command
    addr_i      	: in     std_logic_vector(6 downto 0); 	--address of target slave
    rw_i        	: in     std_logic;                    	--'0' is write, '1' is read
    data_wr_i   	: in     std_logic_vector(7 downto 0); 	--data to write to slave
    busy_o      	: out    std_logic;                    	--indicates transaction in progress
    data_rd_o   	: out    std_logic_vector(7 downto 0); 	--data read from slave
    ack_error_bfr 	: buffer std_logic;                    	--flag if improper acknowledge from slave
    
	sda_i      		: in  std_logic;                    
    scl_i      		: in  std_logic;
	sda_en_o		: out std_logic;
	scl_en_o  		: out std_logic;
	scl_o			: out std_logic;
	sda_o			: out std_logic
	);                   
end aes50_i2c_master;

architecture rtl of aes50_i2c_master is
  CONSTANT divider  :  natural := (input_clk/bus_clk)/4; --number of clocks in 1/4 cycle of scl
  TYPE machine is(ready, start, command, slv_ack1, wr, rd, slv_ack2, mstr_ack, stop); --needed states
  signal state         : machine;                        --state machine
  signal data_clk      : std_logic;                      --data clock for sda
  signal data_clk_prev : std_logic;                      --data clock during previous system clock
  signal scl_clk       : std_logic;                      --constantly running internal scl
  signal scl_ena       : std_logic := '0';               --enables internal scl to output
  signal sda_int       : std_logic := '1';               --internal sda
  signal sda_ena_n     : std_logic;                      --enables internal sda to output
  signal addr_rw       : std_logic_vector(7 downto 0);   --latched in address and read/write
  signal data_tx       : std_logic_vector(7 downto 0);   --latched in data to write to slave
  signal data_rx       : std_logic_vector(7 downto 0);   --data received from slave
  signal bit_cnt       : natural range 0 to 7 := 7;      --tracks bit number in transaction
  signal stretch       : std_logic := '0';               --identifies if slave is stretching scl
  signal data_clk_m : std_logic;
  
  
begin

  --generate the timing for the bus clock (scl_clk) and the data clock (data_clk)
  process(clk_i, rst_n_i)
    variable count  :  natural range 0 to divider*4;  --timing for clock generation
  begin
    if(rst_n_i = '0') then                --reset asserted
      stretch <= '0';
      count := 0;
    elsif(rising_edge(clk_i)) then
      data_clk_prev <= data_clk;          --store previous value of data clock
      if(count = divider*4-1) then        --end of timing cycle
        count := 0;                       --reset timer
      elsif(stretch = '0') then           --clock stretching from slave not detected
        count := count + 1;               --continue clock generation timing
      end if;
      CASE count is
        when 0 to divider-1 =>            --first 1/4 cycle of clocking
          scl_clk <= '0';
          data_clk <= '0';
        when divider to divider*2-1 =>    --second 1/4 cycle of clocking
          scl_clk <= '0';
          data_clk <= '1';
        when divider*2 to divider*3-1 =>  --third 1/4 cycle of clocking
          scl_clk <= '1';                 --release scl
          if(scl_i = '0') then              --detect if slave is stretching clock
            stretch <= '1';
          else
            stretch <= '0';
          end if;
          data_clk <= '1';
        when OTHERS =>                    --last 1/4 cycle of clocking
          scl_clk <= '1';
          data_clk <= '0';
      end CASE;
    end if;
  end process;

  --state machine and writing to sda during scl low (data_clk rising edge)
  process(clk_i, rst_n_i)
  begin
    if(rst_n_i = '0') then                 --reset asserted
      state <= ready;                      --return to initial state
      busy_o <= '1';                         --indicate not available
      scl_ena <= '0';                      --sets scl high impedance
      sda_int <= '1';                      --sets sda high impedance
      ack_error_bfr <= '0';                    --clear acknowledge error flag
      bit_cnt <= 7;                        --restarts data bit counter
      data_rd_o <= "00000000";               --clear data read port
    elsif(rising_edge(clk_i)) then
      if(data_clk = '1' and data_clk_prev = '0') then  --data clock rising edge
        CASE state is
          when ready =>                      --idle state
            if(en_i = '1') then               --transaction requested
              busy_o <= '1';                   --flag busy_o
              addr_rw <= addr_i & rw_i;          --collect requested slave address and command
              data_tx <= data_wr_i;            --collect requested data to write
              state <= start;                --go to start bit
            else                             --remain idle
              busy_o <= '0';                   --unflag busy_o
              state <= ready;                --remain idle
            end if;
          when start =>                      --start bit of transaction
            busy_o <= '1';                     --resume busy_o if continuous mode
            sda_int <= addr_rw(bit_cnt);     --set first address bit to bus
            state <= command;                --go to command
          when command =>                    --address and command byte of transaction
            if(bit_cnt = 0) then             --command transmit finished
              sda_int <= '1';                --release sda for slave acknowledge
              bit_cnt <= 7;                  --reset bit counter for "byte" states
              state <= slv_ack1;             --go to slave acknowledge (command)
            else                             --next clock cycle of command state
              bit_cnt <= bit_cnt - 1;        --keep track of transaction bits
              sda_int <= addr_rw(bit_cnt-1); --write address/command bit to bus
              state <= command;              --continue with command
            end if;
          when slv_ack1 =>                   --slave acknowledge bit (command)
            if(addr_rw(0) = '0') then        --write command
              sda_int <= data_tx(bit_cnt);   --write first bit of data
              state <= wr;                   --go to write byte
            else                             --read command
              sda_int <= '1';                --release sda from incoming data
              state <= rd;                   --go to read byte
            end if;
          when wr =>                         --write byte of transaction
            busy_o <= '1';                     --resume busy_o if continuous mode
            if(bit_cnt = 0) then             --write byte transmit finished
              sda_int <= '1';                --release sda for slave acknowledge
              bit_cnt <= 7;                  --reset bit counter for "byte" states
			  busy_o<='0'; 						--modified
              state <= slv_ack2;             --go to slave acknowledge (write)
            else                             --next clock cycle of write state
              bit_cnt <= bit_cnt - 1;        --keep track of transaction bits
              sda_int <= data_tx(bit_cnt-1); --write next bit to bus
              state <= wr;                   --continue writing
            end if;
          when rd =>                         --read byte of transaction
            busy_o <= '1';                     --resume busy_o if continuous mode
            if(bit_cnt = 0) then             --read byte receive finished
              if(en_i = '1' and addr_rw = addr_i & rw_i) then  --continuing with another read at same address
                sda_int <= '0';              --acknowledge the byte has been received
              else                           --stopping or continuing with a write
                sda_int <= '1';              --send a no-acknowledge (before stop or repeated start)
              end if;
              bit_cnt <= 7;                  --reset bit counter for "byte" states
              data_rd_o <= data_rx;            --output received data
              state <= mstr_ack;             --go to master acknowledge
            else                             --next clock cycle of read state
              bit_cnt <= bit_cnt - 1;        --keep track of transaction bits
              state <= rd;                   --continue reading
            end if;
          when slv_ack2 =>                   --slave acknowledge bit (write)
            if(en_i = '1') then               --continue transaction
             -- busy_o <= '0';                   --continue is accepted
              addr_rw <= addr_i & rw_i;          --collect requested slave address and command
              data_tx <= data_wr_i;            --collect requested data to write
              if(addr_rw = addr_i & rw_i) then   --continue transaction with another write
			  busy_o <= '1';
                sda_int <= data_wr_i(bit_cnt); --write first bit of data
                state <= wr;                 --go to write byte
              else                           --continue transaction with a read or new slave
                state <= start;              --go to repeated start
              end if;
            else                             --complete transaction
              state <= stop;                 --go to stop bit
            end if;
          when mstr_ack =>                   --master acknowledge bit after a read
            if(en_i = '1') then               --continue transaction
              busy_o <= '0';                   --continue is accepted and data received is available on bus
              addr_rw <= addr_i & rw_i;          --collect requested slave address and command
              data_tx <= data_wr_i;            --collect requested data to write
              if(addr_rw = addr_i & rw_i) then   --continue transaction with another read
                sda_int <= '1';              --release sda from incoming data
                state <= rd;                 --go to read byte
              else                           --continue transaction with a write or new slave
                state <= start;              --repeated start
              end if;    
            else                             --complete transaction
              state <= stop;                 --go to stop bit
            end if;
          when stop =>                       --stop bit of transaction
            busy_o <= '0';                     --unflag busy_o
            state <= ready;                  --go to idle state
        end CASE;    
      elsif(data_clk = '0' and data_clk_prev = '1') then  --data clock falling edge
        CASE state is
          when start =>                  
            if(scl_ena = '0') then                  --starting new transaction
              scl_ena <= '1';                       --enable scl output
              ack_error_bfr <= '0';                     --reset acknowledge error output
            end if;
          when slv_ack1 =>                          --receiving slave acknowledge (command)
            if(sda_i /= '0' or ack_error_bfr = '1') then  --no-acknowledge or previous no-acknowledge
              ack_error_bfr <= '1';                     --set error output if no-acknowledge
            end if;
          when rd =>                                --receiving slave data
            data_rx(bit_cnt) <= sda_i;                --receive current slave data bit
          when slv_ack2 =>                          --receiving slave acknowledge (write)
            if(sda_i /= '0' or ack_error_bfr = '1') then  --no-acknowledge or previous no-acknowledge
              ack_error_bfr <= '1';                     --set error output if no-acknowledge
            end if;
          when stop =>
            scl_ena <= '0';                         --disable scl
          when OTHERS =>
            NULL;
        end CASE;
      end if;
    end if;
  end process;  

  --set sda output
  data_clk_m<=data_clk_prev and data_clk;
  with state select
    sda_ena_n <= data_clk when start,     --generate start condition
                 NOT data_clk_m when stop,  --generate stop condition
                 sda_int when OTHERS;     --set to internal sda signal    
      
  --set scl and sda outputs
  scl_o <= '0';
  sda_o <= '0';  
  scl_en_o <= '1' when (scl_ena = '1' and scl_clk = '0') else '0';
  sda_en_o <= '1' when (sda_ena_n = '0') else '0';
  
  --scl <= '0' when (scl_ena = '1' and scl_clk = '0') else 'Z';
  --sda <= '0' when sda_ena_n = '0' else 'Z';
  
end rtl;