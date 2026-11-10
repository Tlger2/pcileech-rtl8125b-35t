################################################################################
# vivado_flash.tcl
# JTAG-program the CaptainDMA 35T with the bitstream from vivado_build.tcl.
# Run on the machine with Vivado + the card on JTAG (USB-JTAG or platform cable):
#   vivado -mode batch -source vivado_flash.tcl
#
# Persistent SPI programming needs the board's flash part name; this script
# loads the FPGA SRAM so enumeration and FT601 can be tested tonight. Re-run
# after every power cycle, or program SPI from Hardware Manager once the
# flash part is selected.
################################################################################

set project_dir [file normalize "[file dirname [info script]]/vivado_project"]
set bitfile [file join $project_dir rtl8125b_dma.runs impl_1 pcie_top_wrapper.bit]
if {![file exists $bitfile]} {
    set alt [glob -nocomplain [file join $project_dir rtl8125b_dma.runs impl_1 *.bit]]
    if {[llength $alt]} {
        set bitfile [lindex $alt 0]
    }
}
if {![file exists $bitfile]} {
    error "No bitstream. Run: vivado -mode batch -source vivado_build.tcl"
}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} {
    error "No JTAG device. Connect the 35T USB-JTAG and check hw_server."
}
current_hw_device $dev
set_property PROGRAM.FILE $bitfile $dev
program_hw_devices $dev
puts "INFO: programmed $bitfile onto $dev"
close_hw_target
disconnect_hw_server
close_hw_manager
