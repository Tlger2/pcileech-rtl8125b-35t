################################################################################
# vivado_build.tcl
# Project: pcileech-rtl8125b-35t
# Target:  xc7a35tfgg484-2  (CaptainDMA 35T)
# Run:     vivado -mode batch -source vivado_build.tcl
#
# What this script does:
#   1. Creates (or re-opens) the Vivado project
#   2. Adds all RTL sources and XDC constraints
#   3. Configures the pcie_7x_0 IP with RTL8125B identity and cfg_ext enabled
#   4. Runs synthesis, implementation, and bitstream generation
#   5. Reports timing + utilization to reports/
################################################################################

set project_name "rtl8125b_dma"
set project_dir  [file normalize "[file dirname [info script]]/vivado_project"]
set part         "xc7a35tfgg484-2"
set rtl_dir      [file normalize "[file dirname [info script]]/rtl"]
set xdc_dir      [file normalize "[file dirname [info script]]/xdc"]
set rpt_dir      [file normalize "[file dirname [info script]]/reports"]

file mkdir $rpt_dir

# ---------------------------------------------------------------------------
# 1. Create / re-open project
# ---------------------------------------------------------------------------
if {[file exists "$project_dir/$project_name.xpr"]} {
    open_project "$project_dir/$project_name.xpr"
} else {
    create_project $project_name $project_dir -part $part -force
    set_property target_language Verilog [current_project]
    set_property default_lib      work         [current_project]
}

# ---------------------------------------------------------------------------
# 2. Add RTL sources
# ---------------------------------------------------------------------------
# Top-level
add_files -norecurse [glob $rtl_dir/*.sv] -fileset [get_filesets sources_1]
# ECAP sub-modules
if {[file isdirectory "$rtl_dir/ecap"]} {
    add_files -norecurse [glob $rtl_dir/ecap/*.sv] -fileset [get_filesets sources_1]
}
# Package files (must come first for elaboration)
set pkg_files [glob -nocomplain $rtl_dir/*_pkg.sv]
if {[llength $pkg_files] > 0} {
    set_property file_type {SystemVerilog} [get_files {*_pkg.sv}]
}
# Set top
set_property top pcie_top_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------------------
# 3. Add XDC constraints
# ---------------------------------------------------------------------------
if {[file isdirectory $xdc_dir]} {
    set xdc_files [glob -nocomplain $xdc_dir/*.xdc]
    if {[llength $xdc_files] > 0} {
        add_files -fileset [get_filesets constrs_1] $xdc_files
    } else {
        puts "WARN: No .xdc files found in $xdc_dir — add CaptainDMA 35T pin constraints"
    }
} else {
    puts "WARN: xdc/ directory not found — synthesis will likely fail on pin assignment"
}

# ---------------------------------------------------------------------------
# 4. Configure pcie_7x_0 IP
#    RTL8125B 2.5GbE NIC identity, x1 Gen2, BAR0=64KB 64-bit, cfg_ext ON
# ---------------------------------------------------------------------------
# Check if IP already exists
set ip_exists [get_ips -quiet pcie_7x_0]
if {[llength $ip_exists] == 0} {
    # Find pcie_7x_0 — try glob first (works across versions), then filter
    # IP name is "pcie_7x"; module_name "pcie_7x_0" is the instance name RTL references
    set avail [get_ipdefs "xilinx.com:ip:pcie_7x:*" -quiet]
    if {[llength $avail] == 0} {
        error "pcie_7x IP not found in catalog — check Vivado installation"
    }
    set ip_ver [lindex [split [lindex $avail 0] {:}] end]
    puts "INFO: using pcie_7x version $ip_ver"
    create_ip -name pcie_7x -vendor xilinx.com -library ip \
              -version $ip_ver -module_name pcie_7x_0

    # ---------------------------------------------------------------------------
    # DIAGNOSTIC: dump all CONFIG properties to find correct names in Vivado 2026.1
    # Remove this block and restore set_property once names are confirmed
    # ---------------------------------------------------------------------------
    puts "INFO: Dumping all pcie_7x_0 CONFIG properties..."
    set ip_obj [get_ips pcie_7x_0]
    foreach p [lsort [list_property $ip_obj]] {
        if {[string match CONFIG.* $p]} {
            if {[catch {set val [get_property $p $ip_obj]} err]} {
                puts "PROP: $p = <unreadable: $err>"
            } else {
                puts "PROP: $p = $val"
            }
        }
    }
    error "DIAGNOSTIC STOP — grep output for 'PROP:' to find correct property names for 2026.1"
    # ---------------------------------------------------------------------------

    generate_target all [get_ips pcie_7x_0]
    puts "INFO: pcie_7x_0 IP created and targets generated"
} else {
    puts "INFO: pcie_7x_0 IP already exists, skipping creation"
}

# ---------------------------------------------------------------------------
# 5. Synthesis
# ---------------------------------------------------------------------------
puts "INFO: Starting synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "INFO: Synthesis status: $synth_status"
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis did not complete 100%"
    open_run synth_1
    report_timing_summary -file $rpt_dir/synth_timing.rpt
    exit 1
}

# ---------------------------------------------------------------------------
# 6. Implementation
# ---------------------------------------------------------------------------
puts "INFO: Starting implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "INFO: Implementation status: $impl_status"
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation did not complete 100%"
    open_run impl_1
    report_timing_summary -file $rpt_dir/impl_timing.rpt
    exit 1
}

# ---------------------------------------------------------------------------
# 7. Timing + utilisation reports
# ---------------------------------------------------------------------------
open_run impl_1
report_timing_summary  -max_paths 20 -file $rpt_dir/timing_summary.rpt
report_utilization               -file $rpt_dir/utilization.rpt
report_clock_interaction         -file $rpt_dir/clock_interaction.rpt
report_drc                       -file $rpt_dir/drc.rpt
puts "INFO: Reports written to $rpt_dir/"

# ---------------------------------------------------------------------------
# 8. Check timing
# ---------------------------------------------------------------------------
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts "INFO: WNS = $wns ns   WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
    puts "WARN: Timing violations present — do NOT flash this bitstream"
    puts "WARN: Check $rpt_dir/timing_summary.rpt for details"
}

# ---------------------------------------------------------------------------
# 9. Bitstream
# ---------------------------------------------------------------------------
puts "INFO: Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set bit_file [file normalize \
    "$project_dir/$project_name.runs/impl_1/pcie_top_wrapper.bit"]
if {[file exists $bit_file]} {
    file copy -force $bit_file [file normalize "[file dirname [info script]]/pcie_top_wrapper.bit"]
    puts "INFO: Bitstream copied to [file dirname [info script]]/pcie_top_wrapper.bit"
} else {
    puts "ERROR: Bitstream not found at expected path: $bit_file"
    exit 1
}

puts ""
puts "========================================"
puts "  BUILD COMPLETE"
puts "  Bitstream: [file dirname [info script]]/pcie_top_wrapper.bit"
puts "  Next step: Hardware Manager -> Program Device"
puts "========================================"
