# Standalone diagnostic flow; no writes to the project runs or bitstream.
# Usage: vivado -mode batch -source vivado_validate.tcl -tclargs /path/to/report-dir ?squirrel?
if {$argc < 1 || $argc > 2 || ($argc == 2 && [lindex $argv 1] ne "squirrel")} {
    error "Provide a report directory and optionally the squirrel candidate profile."
}
set rpt [file normalize [lindex $argv 0]]
file mkdir $rpt
set repo [file dirname [file normalize [info script]]]
set xci [file join $repo vivado_project rtl8125b_dma.srcs sources_1 ip pcie_7x_0 pcie_7x_0.xci]
create_project -in_memory -part xc7a35tfgg484-2
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
read_verilog -sv [file join $repo rtl opcode_scramble_pkg.sv]
foreach f [glob -directory [file join $repo rtl] *.sv caps/*.sv ecap/*.sv] {
    if {[file tail $f] ne "opcode_scramble_pkg.sv"} { read_verilog -sv $f }
}
read_ip $xci
if {[get_property CONFIG.en_ext_clk [get_ips pcie_7x_0]]} {
    error "Regenerate pcie_7x_0 with CONFIG.en_ext_clk=false before direct validation."
}
set_property GENERATE_SYNTH_CHECKPOINT false [get_files $xci]
set xdc [glob -nocomplain -directory [file join $repo xdc] *.xdc]
if {$argc == 2} { set xdc [file join $repo board pcie_squirrel_candidate.xdc] }
if {[llength $xdc]} { read_xdc $xdc }
synth_design -top pcie_top_wrapper -part xc7a35tfgg484-2
if {$argc == 2} {
    set lane [get_cells -hier -filter {REF_NAME == GTPE2_CHANNEL}]
    if {[llength $lane] != 1} { error "Expected exactly one Squirrel PCIe GT channel." }
    set_property LOC GTPE2_CHANNEL_X0Y2 $lane
}
set blackboxes [get_cells -hier -quiet -filter {IS_BLACKBOX}]
if {[llength $blackboxes]} { error "Unresolved cells: $blackboxes" }
report_utilization -file $rpt/synth_utilization.rpt
report_timing_summary -report_unconstrained -file $rpt/synth_timing.rpt
report_drc -file $rpt/synth_drc.rpt
report_cdc -file $rpt/synth_cdc.rpt
write_checkpoint -force $rpt/synth.dcp
opt_design
place_design
route_design
report_route_status -file $rpt/route_status.rpt
report_utilization -file $rpt/utilization.rpt
report_timing_summary -report_unconstrained -file $rpt/timing_summary.rpt
report_drc -file $rpt/drc.rpt
report_cdc -file $rpt/cdc.rpt
report_bus_skew -file $rpt/bus_skew.rpt
check_timing -verbose -file $rpt/check_timing.rpt
report_io -file $rpt/io.rpt
if {$argc == 2} {
    # Successful routing is not sufficient to pass the candidate checks.
    set failures {}
    foreach clock {board_clk ft601_clk pcie_refclk} {
        if {![llength [get_clocks -quiet $clock]]} {
            lappend failures "missing clock $clock"
        }
    }
    foreach {check delay_type} {setup max hold min} {
        set path [get_timing_paths -quiet -no_report_unconstrained \
            -delay_type $delay_type -max_paths 1 -sort_by slack]
        if {![llength $path]} {
            lappend failures "no constrained $check path"
        } elseif {[get_property SLACK $path] < 0} {
            lappend failures [format "%s slack %.3f ns" $check [get_property SLACK $path]]
        }
    }
    set violations [get_drc_violations -quiet \
        -filter {SEVERITY == "Error" || SEVERITY == "Critical Warning"}]
    if {[llength $violations]} { lappend failures "blocking DRCs: $violations" }
    if {[llength $failures]} {
        error "Squirrel candidate checks failed: [join $failures {, }]. Reports: $rpt"
    }
    puts "INFO: Squirrel candidate passed routed setup, hold, and blocking DRC checks."
}
if {![llength $xdc]} { puts "WARNING: No board XDC; routing is diagnostic only." }
