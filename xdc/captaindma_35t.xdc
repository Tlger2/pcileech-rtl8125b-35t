##############################################################################
# CaptainDMA 35T (XC7A35T FGG484-2) — Pin + Timing Constraints
# CyberAmmo Captain DMA 3rd GEN / PCIe Squirrel profile
# Validated pin map — verify against board schematic before programming.
##############################################################################

#------------------------------------------------------------------------------
# Pin assignments — FT601 byte-enable
#------------------------------------------------------------------------------
set_property PACKAGE_PIN Y18  [get_ports {ft601_be[0]}]
set_property PACKAGE_PIN AA18 [get_ports {ft601_be[1]}]
set_property PACKAGE_PIN AB18 [get_ports {ft601_be[2]}]
set_property PACKAGE_PIN W17  [get_ports {ft601_be[3]}]

#------------------------------------------------------------------------------
# Pin assignments — FT601 data bus D[31:0]
#------------------------------------------------------------------------------
set_property PACKAGE_PIN N13  [get_ports {ft601_data[0]}]
set_property PACKAGE_PIN N14  [get_ports {ft601_data[1]}]
set_property PACKAGE_PIN N15  [get_ports {ft601_data[2]}]
set_property PACKAGE_PIN P15  [get_ports {ft601_data[3]}]
set_property PACKAGE_PIN P16  [get_ports {ft601_data[4]}]
set_property PACKAGE_PIN N17  [get_ports {ft601_data[5]}]
set_property PACKAGE_PIN P17  [get_ports {ft601_data[6]}]
set_property PACKAGE_PIN R17  [get_ports {ft601_data[7]}]
set_property PACKAGE_PIN P19  [get_ports {ft601_data[8]}]
set_property PACKAGE_PIN R18  [get_ports {ft601_data[9]}]
set_property PACKAGE_PIN R19  [get_ports {ft601_data[10]}]
set_property PACKAGE_PIN T18  [get_ports {ft601_data[11]}]
set_property PACKAGE_PIN U18  [get_ports {ft601_data[12]}]
set_property PACKAGE_PIN V18  [get_ports {ft601_data[13]}]
set_property PACKAGE_PIN V19  [get_ports {ft601_data[14]}]
set_property PACKAGE_PIN V17  [get_ports {ft601_data[15]}]
set_property PACKAGE_PIN W20  [get_ports {ft601_data[16]}]
set_property PACKAGE_PIN Y19  [get_ports {ft601_data[17]}]
set_property PACKAGE_PIN T21  [get_ports {ft601_data[18]}]
set_property PACKAGE_PIN T20  [get_ports {ft601_data[19]}]
set_property PACKAGE_PIN U21  [get_ports {ft601_data[20]}]
set_property PACKAGE_PIN V20  [get_ports {ft601_data[21]}]
set_property PACKAGE_PIN W22  [get_ports {ft601_data[22]}]
set_property PACKAGE_PIN W21  [get_ports {ft601_data[23]}]
set_property PACKAGE_PIN Y22  [get_ports {ft601_data[24]}]
set_property PACKAGE_PIN Y21  [get_ports {ft601_data[25]}]
set_property PACKAGE_PIN AA21 [get_ports {ft601_data[26]}]
set_property PACKAGE_PIN AB22 [get_ports {ft601_data[27]}]
set_property PACKAGE_PIN AA20 [get_ports {ft601_data[28]}]
set_property PACKAGE_PIN AB21 [get_ports {ft601_data[29]}]
set_property PACKAGE_PIN AA19 [get_ports {ft601_data[30]}]
set_property PACKAGE_PIN AB20 [get_ports {ft601_data[31]}]

#------------------------------------------------------------------------------
# Pin assignments — FT601 control signals
#------------------------------------------------------------------------------
set_property PACKAGE_PIN AB6  [get_ports {ft601_oe_n}]
set_property PACKAGE_PIN AA6  [get_ports {ft601_rd_n}]
set_property PACKAGE_PIN AB8  [get_ports {ft601_rxf_n}]
set_property PACKAGE_PIN Y8   [get_ports {ft601_siwu_n}]
set_property PACKAGE_PIN AA8  [get_ports {ft601_txe_n}]
set_property PACKAGE_PIN AB7  [get_ports {ft601_wr_n}]
set_property PACKAGE_PIN Y9   [get_ports {ft601_rst_n}]

#------------------------------------------------------------------------------
# Pin assignments — clocks, reset, link LED
#------------------------------------------------------------------------------
set_property PACKAGE_PIN H4   [get_ports {board_clk}]
set_property PACKAGE_PIN W19  [get_ports {ft601_clk}]
set_property PACKAGE_PIN B13  [get_ports {sys_rst_n}]
set_property PACKAGE_PIN Y6   [get_ports {user_lnk_up_pin}]

#------------------------------------------------------------------------------
# Pin assignments — PCIe GT differential pairs (no IOSTANDARD on GT pads)
#------------------------------------------------------------------------------
set_property PACKAGE_PIN A10  [get_ports {pci_exp_rxn[0]}]
set_property PACKAGE_PIN B10  [get_ports {pci_exp_rxp[0]}]
set_property PACKAGE_PIN A6   [get_ports {pci_exp_txn[0]}]
set_property PACKAGE_PIN B6   [get_ports {pci_exp_txp[0]}]
set_property PACKAGE_PIN E6   [get_ports {sys_clk_n}]
set_property PACKAGE_PIN F6   [get_ports {sys_clk_p}]

#------------------------------------------------------------------------------
# IOSTANDARD — all single-ended FT601 and board signals at 3.3V LVCMOS
#------------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS33 [get_ports {board_clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {sys_rst_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_lnk_up_pin}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_oe_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_rd_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_rxf_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_rst_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_siwu_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_txe_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_wr_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_data[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ft601_be[*]}]

#------------------------------------------------------------------------------
# Config voltage — required to clear Artix-7 DRC CFGBVS_B1
#------------------------------------------------------------------------------
set_property CFGBVS         Vcco [current_design]
set_property CONFIG_VOLTAGE  3.3  [current_design]

#------------------------------------------------------------------------------
# Clock definitions
#------------------------------------------------------------------------------
create_clock -name board_clk   -period 10.000 [get_ports board_clk]
create_clock -name ft601_clk   -period 10.000 [get_ports ft601_clk]
# Create pcie_refclk on the IBUFDS_GTE2 O pin, NOT on the top-level port.
# Vivado cannot propagate a port-level create_clock through IBUFDS_GTE2 into
# the GT transceiver and downstream MMCM.  Anchoring on the O pin lets
# -include_generated_clocks traverse the full GT→MMCM→user_clk_out chain.
create_clock -name pcie_refclk -period 10.000 [get_pins u_refclk_ibuf/O]

# All three oscillator domains are independent — declare async across the board.
# -include_generated_clocks on pcie_refclk now captures pcie_user_clk and pipe_clk
# because create_clock is on the IBUFDS_GTE2 O pin.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks board_clk] \
    -group [get_clocks -include_generated_clocks ft601_clk] \
    -group [get_clocks -include_generated_clocks pcie_refclk]

# Belt-and-suspenders: if any PCIe-generated clock is still not captured by the
# -include_generated_clocks traversal above (GT clock propagation can be opaque),
# false-path hold analysis to/from ft601_clk for every non-board/non-ft601 clock.
# xpm_fifo_async handles synchronization on those crossings; hold violations there
# are not physically meaningful.
set_false_path -hold \
    -from [get_clocks ft601_clk] \
    -to   [get_clocks -filter {NAME !~ ft601_clk && NAME !~ board_clk}]
set_false_path -hold \
    -from [get_clocks -filter {NAME !~ ft601_clk && NAME !~ board_clk}] \
    -to   [get_clocks ft601_clk]

# Cell-based hold false-paths for xpm_fifo_async CDC gray-counter chains.
# When FIFO_MEMORY_TYPE=distributed (depth=16 on Artix-7), Vivado maps the gray
# counter to RAM32M outputs rather than FFs.  xpm_cdc_gray.tcl's
# "set_max_delay -datapath_only -from src_gray_ff_reg" then fails with
# "not a valid startpoint" (RAM output is not a sequential cell Q pin).
# Without that constraint the router still checks hold on the async crossing.
# The clock-domain false-paths above depend on pcie_user_clk being a named clock,
# which requires GT→MMCM propagation that Vivado may not complete.
# Targeting the destination synchronizer FFs directly is clock-name-agnostic and
# always applies — the ASYNC_REG chain is designed to tolerate metastability,
# so suppressing hold on its input stage is architecturally correct.
set_false_path -hold \
    -to [get_cells -hierarchical -filter {NAME =~ *dest_graysync_ff_reg* && IS_SEQUENTIAL == 1}]

# Reset synchronizer within xpm_fifo_rst (xpm_cdc_sync_rst) — same rationale.
set_false_path -hold \
    -to [get_cells -hierarchical -filter {NAME =~ *arststages_ff_reg*     && IS_SEQUENTIAL == 1}]

#------------------------------------------------------------------------------
# FT601 input/output delays — FTDI DS_FT600Q-FT601Q v1.06 table 4.2
# 100 MHz, zero PCB skew assumed.
#------------------------------------------------------------------------------
set_input_delay  -clock ft601_clk -min  3.5 [get_ports {ft601_rxf_n ft601_txe_n ft601_data[*]}]
set_input_delay  -clock ft601_clk -max  7.0 [get_ports {ft601_rxf_n ft601_txe_n ft601_data[*]}]
set_output_delay -clock ft601_clk -min -4.8 [get_ports {ft601_wr_n ft601_rd_n ft601_oe_n ft601_data[*] ft601_be[*]}]
set_output_delay -clock ft601_clk -max  1.0 [get_ports {ft601_wr_n ft601_rd_n ft601_oe_n ft601_data[*] ft601_be[*]}]

#------------------------------------------------------------------------------
# False paths — async board signals with no synchronous external timing
#------------------------------------------------------------------------------
set_false_path -from [get_ports sys_rst_n]
set_false_path -to   [get_ports {ft601_rst_n ft601_siwu_n user_lnk_up_pin}]

#------------------------------------------------------------------------------
# Bitstream / configuration
#------------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS           TRUE  [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH        4     [current_design]
set_property CONFIG_MODE                          SPIx4  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE          66    [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE       YES   [current_design]
