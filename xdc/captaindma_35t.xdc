##############################################################################
# CaptainDMA 35T (XC7A35T FGG484-2) — Pin + Timing Constraints
#
# Derived from pcileech-fpga PCIeScreamer R04 reference layout.
#
# PCIe refclk and diff pairs are well-confirmed for the FGG484 screamer
# family.  FT601 pins match the screamer R04 reference but MUST be verified
# against your board's schematic or the OEM firmware XDC before programming.
# Wrong FT601 pin assignments will cause DRC errors in Vivado (not hardware
# damage) because IOSTANDARD conflicts are caught at implementation time.
##############################################################################

#------------------------------------------------------------------------------
# Timing
#------------------------------------------------------------------------------

# 100 MHz PCIe refclk (differential — fed to IBUFDS_GTE2 in top module)
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports sys_clk_p]

# 100 MHz FT601 synchronous slave-FIFO clock
create_clock -period 10.000 -name ft601_clk -waveform {0.000 5.000} [get_ports ft601_clk]

# PERST# and FT601 reset are asynchronous inputs — no timing required
set_false_path -from [get_ports sys_rst_n]
set_false_path -from [get_ports ft601_rst_n]

# PCIe-domain and FT601-domain clocks are unrelated (async crossing handled
# in the endpoint's FT601 ↔ user_clk CDC FIFOs)
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk] \
    -group [get_clocks -include_generated_clocks ft601_clk]

#------------------------------------------------------------------------------
# PCIe GT refclk — MGTREFCLK0P/N of bank 116 (GTP_X0Y0)
# Differential — no IOSTANDARD property needed (GT pad).
#------------------------------------------------------------------------------
set_property PACKAGE_PIN F6 [get_ports sys_clk_p]
set_property PACKAGE_PIN E6 [get_ports sys_clk_n]

#------------------------------------------------------------------------------
# PCIe 1-lane diff pairs — GTP channel 0, bank 116
# Differential — no IOSTANDARD property needed (GTP pad).
#------------------------------------------------------------------------------
set_property PACKAGE_PIN B2 [get_ports {pci_exp_txp[0]}]
set_property PACKAGE_PIN A2 [get_ports {pci_exp_txn[0]}]
set_property PACKAGE_PIN B6 [get_ports {pci_exp_rxp[0]}]
set_property PACKAGE_PIN A6 [get_ports {pci_exp_rxn[0]}]

#------------------------------------------------------------------------------
# PERST# (active-low PCIe reset) — through IBUF in pcie_top_wrapper
#------------------------------------------------------------------------------
set_property PACKAGE_PIN G4        [get_ports sys_rst_n]
set_property IOSTANDARD  LVCMOS33  [get_ports sys_rst_n]
set_property PULLUP      true      [get_ports sys_rst_n]

#------------------------------------------------------------------------------
# FT601 USB3 synchronous slave FIFO — bank 15/16, LVCMOS33 3.3 V
# !! VERIFY all FT601 pins against board schematic before programming !!
# Matches pcileech-fpga PCIeScreamer R04 reference layout.
#------------------------------------------------------------------------------

# Clock (input from FT601 CLK pin)
set_property PACKAGE_PIN B16       [get_ports ft601_clk]

# Control inputs (from FT601)
set_property PACKAGE_PIN N15       [get_ports ft601_rxf_n]
set_property PACKAGE_PIN M15       [get_ports ft601_txe_n]

# Control outputs (to FT601)
set_property PACKAGE_PIN L16       [get_ports ft601_oe_n]
set_property PACKAGE_PIN N16       [get_ports ft601_rd_n]
set_property PACKAGE_PIN P15       [get_ports ft601_wr_n]

# FT601 RESET_N — FT601 GPIO/RESET output → FPGA input.
# If your board does not route this pin, tie ft601_rst_n high in the wrapper
# and remove this constraint line.
set_property PACKAGE_PIN R15       [get_ports ft601_rst_n]

# Data bus D[31:0] (bidirectional)
set_property PACKAGE_PIN P13       [get_ports {ft601_data[0]}]
set_property PACKAGE_PIN P14       [get_ports {ft601_data[1]}]
set_property PACKAGE_PIN N13       [get_ports {ft601_data[2]}]
set_property PACKAGE_PIN N14       [get_ports {ft601_data[3]}]
set_property PACKAGE_PIN M13       [get_ports {ft601_data[4]}]
set_property PACKAGE_PIN M14       [get_ports {ft601_data[5]}]
set_property PACKAGE_PIN L14       [get_ports {ft601_data[6]}]
set_property PACKAGE_PIN L15       [get_ports {ft601_data[7]}]
set_property PACKAGE_PIN K13       [get_ports {ft601_data[8]}]
set_property PACKAGE_PIN K14       [get_ports {ft601_data[9]}]
set_property PACKAGE_PIN J13       [get_ports {ft601_data[10]}]
set_property PACKAGE_PIN J14       [get_ports {ft601_data[11]}]
set_property PACKAGE_PIN H13       [get_ports {ft601_data[12]}]
set_property PACKAGE_PIN H14       [get_ports {ft601_data[13]}]
set_property PACKAGE_PIN G13       [get_ports {ft601_data[14]}]
set_property PACKAGE_PIN G14       [get_ports {ft601_data[15]}]
set_property PACKAGE_PIN F13       [get_ports {ft601_data[16]}]
set_property PACKAGE_PIN F14       [get_ports {ft601_data[17]}]
set_property PACKAGE_PIN E13       [get_ports {ft601_data[18]}]
set_property PACKAGE_PIN E14       [get_ports {ft601_data[19]}]
set_property PACKAGE_PIN D13       [get_ports {ft601_data[20]}]
set_property PACKAGE_PIN D14       [get_ports {ft601_data[21]}]
set_property PACKAGE_PIN C13       [get_ports {ft601_data[22]}]
set_property PACKAGE_PIN C14       [get_ports {ft601_data[23]}]
set_property PACKAGE_PIN B13       [get_ports {ft601_data[24]}]
set_property PACKAGE_PIN B14       [get_ports {ft601_data[25]}]
set_property PACKAGE_PIN A13       [get_ports {ft601_data[26]}]
set_property PACKAGE_PIN A14       [get_ports {ft601_data[27]}]
set_property PACKAGE_PIN A15       [get_ports {ft601_data[28]}]
set_property PACKAGE_PIN A16       [get_ports {ft601_data[29]}]
set_property PACKAGE_PIN D16       [get_ports {ft601_data[30]}]
set_property PACKAGE_PIN E16       [get_ports {ft601_data[31]}]

# Byte enable BE[3:0]
set_property PACKAGE_PIN H16       [get_ports {ft601_be[0]}]
set_property PACKAGE_PIN G15       [get_ports {ft601_be[1]}]
set_property PACKAGE_PIN F15       [get_ports {ft601_be[2]}]
set_property PACKAGE_PIN F16       [get_ports {ft601_be[3]}]

# IOSTANDARD — all FT601 signals at 3.3 V LVCMOS
set_property IOSTANDARD LVCMOS33   [get_ports ft601_clk]
set_property IOSTANDARD LVCMOS33   [get_ports ft601_rxf_n]
set_property IOSTANDARD LVCMOS33   [get_ports ft601_txe_n]
set_property IOSTANDARD LVCMOS33   [get_ports ft601_oe_n]
set_property IOSTANDARD LVCMOS33   [get_ports ft601_rd_n]
set_property IOSTANDARD LVCMOS33   [get_ports ft601_wr_n]
set_property IOSTANDARD LVCMOS33   [get_ports ft601_rst_n]
set_property IOSTANDARD LVCMOS33   [get_ports {ft601_data[*]}]
set_property IOSTANDARD LVCMOS33   [get_ports {ft601_be[*]}]

# Drive strength — 8 mA for control strobes, 4 mA for data/BE
set_property DRIVE 8               [get_ports ft601_oe_n]
set_property DRIVE 8               [get_ports ft601_rd_n]
set_property DRIVE 8               [get_ports ft601_wr_n]
set_property DRIVE 4               [get_ports {ft601_data[*]}]
set_property DRIVE 4               [get_ports {ft601_be[*]}]

# Slew — FAST on all driven signals to meet FT601 setup/hold at 100 MHz
set_property SLEW FAST             [get_ports ft601_oe_n]
set_property SLEW FAST             [get_ports ft601_rd_n]
set_property SLEW FAST             [get_ports ft601_wr_n]
set_property SLEW FAST             [get_ports {ft601_data[*]}]
set_property SLEW FAST             [get_ports {ft601_be[*]}]

#------------------------------------------------------------------------------
# user_lnk_up_pin — PCIe link-up status LED
# Replace C9 with the actual LED pin on your CaptainDMA board.
# If no LED exists, remove this port from pcie_top_wrapper.sv or tie it
# to a spare GPIO.  Screamer R04 uses LED_D1 at C9.
#------------------------------------------------------------------------------
set_property PACKAGE_PIN C9        [get_ports user_lnk_up_pin]
set_property IOSTANDARD  LVCMOS33  [get_ports user_lnk_up_pin]
set_property DRIVE       8         [get_ports user_lnk_up_pin]
set_property SLEW        SLOW      [get_ports user_lnk_up_pin]

#------------------------------------------------------------------------------
# Bitstream / configuration
#------------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS      TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH   4    [current_design]
set_property CONFIG_MODE                     SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE     33   [current_design]

# CFGBVS / CONFIG_VOLTAGE — required to pass Artix-7 DRC (CFGBVS_B1)
# CaptainDMA 35T uses 3.3V VCCO on the config bank
set_property CFGBVS         VCCO [current_design]
set_property CONFIG_VOLTAGE  3.3  [current_design]
