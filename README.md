# AES50 VHDL IP
An implementation of the AES50 protocol in vanilla VHDL.

## About the IP
I started developing this IP around end of 2024 - originally with some other intention.   
However I decided to make this project public with the purpose to be used in the fabulous [OpenX32 project](https://github.com/OpenMixerProject/OpenX32).  
Therefore, this IP was developed fully independent/separated from the OpenX32 project and comes instead with a reference implementation on a custom PCB (also included in this repo) designed around an [Efinix Trion T20 FPGA](https://www.efinixinc.com/shop/t20.php).  
Integration into the OpenX32 project is still a to-do work.. But I'm sure those guys will manage :)

## AES50 Specification
Before asking any detailed questions about functionality or implementation of this IP, please make sure you read and understood the public available AES50 specification which can be downloaded [here](https://aes2.org/publications/standards-store/?id=45).    
Otherwise I might not answer to your request.

## Features of the IP
- Audio-Formats
  - 48kHz / 24-Bit
  - 44.1kHz / 24-Bit
- Audio-Interfaces
  - TDM-8 (6x In + 6x Out) for full 48x48 channel access
  - I2S (1x In + 1x Out) for a reduced 2x2 channel access (the other 46x46 channels are ignored)
- Aux-Data over TDM
  - Access the auxiliary-data-channel of AES50 (which is e.g. used for headamp-control) through TDM-Interface
- Operation Modes
  - AES50-Master + TDM/I2S Master (Timing Reference: Local Oscillator)
  - AES50-Master + TDM/I2S Slave  (Timing Reference: External I2S/TDM Device)
  - AES50-Slave  + TDM/I2S Master (Timing-Reference: External AES50 Device)
- PLL Support
  - Integrated I2C-controller and driver for Cirrus Logic CS2100CP PLL
- Compatibility / Real-Life Tested
  - Proven to work with X32, Wing, S- and DL- series stageboxes
  - Flawless handling of Cat-Cable Hot-Plugging


### IP Internal Structure    
![AES50 IP Internal Structure](Doc/aes50_internal_structure.png?raw=true "AES50 IP Internal Structure")
### Use Case A: 48x48 Channel with Multi-TDM8 Interface and access to Auxiliary Data Tunnel
![48x48 Channel Use-Case](Doc/48x48_tdm8_mode.png?raw=true "48x48 Channel Use-Case")

### Use Case B: 2x2 Channel with simple I2S Interface. No access to Auxiliary Data Tunnel
![2x2 Channel Use-Case](Doc/2x2_i2s_mode.png?raw=true "2x2 Channel Use-Case")

### Top-Module Ports Description
| Signal                     | Direction | Type                          | Description                             |
| -------------------------- | -------- | ------------------------------ | --------------------------------------- |
| **clk50_i**                | in       | `std_logic`                    | 50 MHz Clock for the Ethernet Logic     |
| **clk100_i**               | in       | `std_logic`                    | 100 MHz Clock for the Core Logic        |
| **rst_i**                  | in       | `std_logic`                    | Synchronous Reset (100 MHz clock-domain)|
| **fs_mode_i**              | in       | `std_logic_vector(1 downto 0)` | Sample-Rate Select<br><ul><li>00 → 44.1 kHz</li><li>01 → 48 kHz</li><li>10 → n.a.</li><li>11 → n.a.</li></ul>|
| **sys_mode_i**             | in       | `std_logic_vector(1 downto 0)` | System-Mode Select<br><ul><li>00 → AES50 Slave & I2S/TDM Master</li><li>01 → AES50 Master & I2S/TDM Master</li><li>10 → AES50 Master & I2S/TDM Slave</li><li>11 → n.a.</li></ul>|               |
| **tdm8_i2s_mode_i**        | in       | `std_logic`                    | Interface Select<br><ul><li>0 → 48x48 TDM8 (with Aux-Data)</li><li>1 → 2x2 I2S (no Aux-Data)</li></ul>|
| **rmii_crs_dv_i**          | in       | `std_logic`                    | RMII Data Valid Receive from PHY        |
| **rmii_rxd_i**             | in       | `std_logic_vector(1 downto 0)` | RMII Data from PHY                      |
| **rmii_tx_en_o**           | out      | `std_logic`                    | RMII Data Valid Transmit to PHY         |
| **rmii_txd_o**             | out      | `std_logic_vector(1 downto 0)` | RMII Data to PHY                        |
| **phy_rst_n_o**            | out      | `std_logic`                    | PHY Reset (active low)                  |
| **aes50_clk_a_rx_i**       | in       | `std_logic`                    | AES50 Clock A Receive                   |
| **aes50_clk_a_tx_o**       | out      | `std_logic`                    | AES50 Clock A Transmit                  |
| **aes50_clk_a_tx_en_o**    | out      | `std_logic`                    | AES50 Clock A Enable LVDS Output Driver      |
| **aes50_clk_b_rx_i**       | in       | `std_logic`                    | AES50 Clock B Receive                   |
| **aes50_clk_b_tx_o**       | out      | `std_logic`                    | AES50 Clock B Transmit                  |
| **aes50_clk_b_tx_en_o**    | out      | `std_logic`                    | AES50 Clock B Enable LVDS Output Driver      |
| **clk_1024xfs_from_pll_i** | in       | `std_logic`                    | Clock from external PLL (1024× fs)      |
| **pll_lock_n_i**           | in       | `std_logic`                    | External PLL Lock Status (active low)   |
| **clk_to_pll_o**           | out      | `std_logic`                    | Clock to external PLL                   |
| **pll_mult_value_o**       | out      | `integer`                      | External PLL multiplication-factor      |
| **pll_init_busy_i**        | in       | `std_logic`                    | PLL init busy status                    |
| **mclk_o**                 | out      | `std_logic`                    | Master Clock (256x fs) - derived (divided by x4) from PLL - independent of System-Mode Select |
| **wclk_o**                 | out      | `std_logic`                    | Word Clock Output (if our IP is I2S/TDM Master)   |
| **bclk_o**                 | out      | `std_logic`                    | Bit Clock Output  (if our IP is I2S/TDM Master)   |
| **wclk_readback_i**        | in       | `std_logic`                    | Word Clock Readback (direct from FPGA-Pin - always needed)    |
| **bclk_readback_i**        | in       | `std_logic`                    | Bit Clock Readback (direct from FPGA-Pin - always needed)     |
| **wclk_out_en_o**          | out      | `std_logic`                    | Word Clock Output Enable (high if IP is I2S/TDM Master)    |
| **bclk_out_en_o**          | out      | `std_logic`                    | Bit Clock Output Enable (high if IP is I2S/TDM Master)     |
| **tdm_i**                  | in       | `std_logic_vector(6 downto 0)` | 6x TDM8 Data Input + 1x TDM8 Aux Data Input   (only needed in 48x48 mode)               |
| **tdm_o**                  | out      | `std_logic_vector(6 downto 0)` | 6x TDM8 Data Output + 1x TDM8 Aux Data Output   (only needed in 48x48 mode)                    |
| **i2s_i**                  | in       | `std_logic`                    | I2S Input  (only needed in 2x2 mode)                            |
| **i2s_o**                  | out      | `std_logic`                    | I2S Output (only needed in 2x2 mode)                             |
| **aes_ok_o**               | out      | `std_logic`                    | AES50 Link Status  (high when connection established)         |
| **dbg_o**                  | out      | `std_logic_vector(7 downto 0)` | Various internal debug signals                          |
| **uart_o**               	| out      | `std_logic`                    | UART output (decoded bytes from the AES50 AUX-RX tunnel)     |
### Aux over TDM Feature
AES50 provides (as part of the protocol) an auxiliary data channel with a fixed bandwidth of roughly 5 Mbit/s (the exact rate depends on the selected sample rate, as the auxiliary data stream is synchronous with the audio transmission).  
According to the AES50 specification, there was a proposal (though not mandatory) to use standard Ethernet frames that could be tunneled through this auxiliary data channel - (ever wondered about the mysterious Ethernet port on the DN9630?) -> Therefore I assume that this proposed approach using virtual Ethernet frames is also used in other AES50 devices on the market.  
However, additional mechanisms are required to transmit Ethernet frames through the auxiliary channel - specifically bit-stuffing and data-scrambling. These are not implemented in this IP core yet. As a result, we currently cannot directly control head-amps or similar.  
Since the bitstream is synchronous with the audio transmission, this IP enables sending and receiving the bitstream over the TDM8 interface. Internally, the IP handles the bitstream as 16-bit words, and the TDM module distributes the auxiliary data evenly across the eight TDM slots as 24-bit “samples.” The extra 8 bits act as an overlay protocol to ensure correct interpretation of the auxiliary words when tunneling them over a 3rd party audio-transportation-medium.  If the TDM-Aux-RX/TX pins of two instances of this IP are cross-connected, it allows transparent tunneling of the auxiliary data channel as long as synchronicity and bit-consistency is ensured. A similar concept appears to be implemented in the Appsys Multiverter, which tunnels AES50 auxiliary data as eight audio channels through a Dante network to maintain head-amp remote control.

As a first reference for the datarate you can assume:
- 44× 16-bit aux words in the same time frame as 6 audio samples at 48 kHz
- 88× 16-bit aux words in the same time frame as 11 (not 12) audio samples at 44.1 kHz
- See further details in the TDM module implementation

Anyhow - the IP core is prepared to be extended in terms of aux-data functionality (and its possibilities) later on. Therefore, the internal Data-FIFOs between TDM and the AES50 RX/TX Module are separated for Audio and Auxiliary-Data. 

### Aux Data Receive (Update March 5th 2026)
The IP can now decode the receiving side of the AES50 AUX data-tunnel and will send the data via UART to the outside word.  
The actual protocol which is e.g. used for headamp control is still under investigation as the AES50 specification itself is only defining how the data-tunnel works.  
See here an example print-out of a Wing-Rack connected.  
![Example UART Printout](Doc/realterm_uart_aux_rx.png?raw=true "Aux Uart Printout")

### Audio Interface Timing

Warning: When this IP is in I2S/TDM slave-mode (sys_mode_i = "10"), make ultimately sure, that BCLK/WCLK is stable before releasing the IP's reset.  
AES50 protocol has a pulse-width modulation mechanism in the outgoing (LVDS-)clock signals which needs to be synchronized to the incoming I2S/TDM clock.  
This is only done once after reset. You must ensure externally, if WCLK/BCLK has changed or was unstable, this IP core runs again through a new reset.

#### I2S
In I2S mode, BCLK is 64*fs : 32-Bit per Slot (24-Bit Audio + 8 Bit Padding).  
3.072 MHz for 48k mode and 2.8224 MHz for 44k1. No other I2S configuration is supported besides this.  
This is valid for all system-modes.

#### TDM-8
BCLK is supposed to be 12.288 MHz for 48k or 11.2896 MHz for 44k1 : 32-Bit per Slot (24-Bit Audio + 8 Bit Padding).  
No other TDM configuration is supported besides this.  
This is valid for all system-modes.

#### TDM-8 Master Timing (when BCLK/WCLK is output)
When the IP is TDM master, the WCLK will be high for 8 BCLK cycles. 
![TDM8 Master Timing](Doc/tdm8_8cycles_fsync_pulse.png?raw=true "TDM8 Master Timing")

#### TDM-8 Slave Timing (when BCLK/WCLK is input)
WCLK must be only high for one BCLK pulse (but can be longer of course)
![TDM8 Slave Timing](Doc/tdm8_flexible_fsync_pulse.png?raw=true "TDM8 SlaveTiming")



### Misc
#### Deviations against the specification
- Bit-Error correction is only implemented on the transmitting side (as AES50 devices on market expects this to be implemented properly), however this IP does not correct bit-errors on receiving side. (I personally don't see this as a critical feature. Basically no other network audio protocol has this implemented)
- AES50 specifies a delay of around 3 sample times IP in- to output (in 44k1, 48k). However this IP processes the audio-samples internally in frames of 6 samples at 48k or 11 samples at 44k1. Therefore the latency is slightly higher
- Clock integrity check: AES50 by default runs the LVDS-clock-signals (through the CAT-wire) bidirectional. Even though it would be technically enough to run the clock only unidrectional from the clock-master to the clock-slave, AES50 uses this to check the integrity of the clock-recovery (PLL) on the AES50-slave-device side. As I understood, the slave-device would be supposed to regenerate the pulse-width modulated clock signal based on the recovered clock and send it back to the master. However this IP just loops the clock back to the master in case it is in slave-configuration. Also as per spec, the AES50 should verify the clock speeds for correctness. This IP has implemented only a more simple timeout-watchdog alike clock integrity checking (on both clock-transmitting and clock-receiving side).
- AES50 also supports other audio-formats and sample-rates (e.g. Bitstream-Audio, 88k2, 96k, etc..). This IP is only usable for 24-Bit PCM-Audio for 44k1 and 48k. However the IP is prepared for later integration of 88k2 and 96k sample-rate. I just didn't do this because I was lacking of suitable devices which support AES50 with 88k2/96k.

#### TODOs / next steps / not done yet
- Verification of internal clock domain crossings
- Constraining and verification of input- & output timings (RMII, TDM, etc..)
- Bit Transparency Testing
- Refactoring of TDM SerDes
- Implement Interface to enable use of Aux-Data-Tunnel over e.g. UART or SPI etc..
- Implement 88k2/96k mode
  
#### Random Info
- The core-clock of this IP can also run at a reduced clock-speed of 80 MHz (instead of 100 MHz) if I2S mode only is used. Some internal timing-reference values must be changed for this (see in the top VHDL module in the efinity project)
- In case, the IP will be used in sys_mode_i="01" (AES-master + TDM/I2S master) only, the external PLL is not necessarily needed and the IP can be tricked to run from a static oscilator with 1024xfs speed.   Connect the static 1024xfs clock to "clk_1024xfs_from_pll_i", make "pll_init_busy_i" and "pll_lock_n_i" to static '0' and just leave "clk_to_pll_o" and "pll_mult_value_o" open.
- sys_mode_i, fs_mode_i and tdm8_i2s_mode_i should not be changed on the fly. If this is changed, the IP needs a new reset.
- Spot the easter-egg in this project :-)

## Test Board Setup
### Overview
In I2S mode, only I0/O0 will be used as in+out.  
![Board Overview](Doc/board_overview.png?raw=true "Board Overview")


### Front View
![Board Front View](Doc/board_front.png?raw=true "Board Front View")

### FPGA Resource Utilization
This is the resource utilization for a full configuration (all sample-rates and operation modes supported, dual TDM/I2S support, PLL-I2C driver etc.).  
Resource utilization depends on actual used configuration.  
Especially if core is configured for e.g. I2S only operation, the utilization is reduced drastically (the TDM-Serdes is still a rather resource-inefficient implementation as of today).

Reference FPGA: Efinix Trion T20Q100F3 (Speedgrade: 4) using Efinity 2025.1.110.5.9 toolchain.  
![FPGA Resource Utilization](Doc/t20_ip_utilization.png?raw=true "Resource Utilization")  

## License

Copyright (c) 2025 Markus Noll (YetAnotherElectronicsChannel)

This IP core is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This IP core is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this IP core. If not, see <https://www.gnu.org/licenses/>.

Any other use — including use in other projects or commercial applications —
is not permitted without a separate written license agreement.

Third-party components included in this repository may be licensed under
different terms (for example, GPLv3). These components retain their
original licenses and are clearly marked in the source header.
