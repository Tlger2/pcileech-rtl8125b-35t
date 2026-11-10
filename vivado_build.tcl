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
    create_project $project_name $project_dir -part $part
    set_property target_language Verilog [current_project]
    set_property default_lib      work         [current_project]
}

set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
set srcset [get_filesets sources_1]
set_property source_mgmt_mode DisplayOnly [current_project]
set rtl_files [glob -nocomplain -directory $rtl_dir *.sv caps/*.sv ecap/*.sv]
foreach path $rtl_files {
    set src [get_files -quiet -of_objects $srcset $path]
    if {![llength $src]} {
        add_files -norecurse -fileset $srcset $path
        set src [get_files -quiet -of_objects $srcset $path]
    }
    set_property file_type SystemVerilog $src
}
set_property top pcie_top_wrapper $srcset
update_compile_order -fileset sources_1
set_property top pcie_top_wrapper $srcset

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
    puts "WARN: xdc/ directory not found — board pinout is required for bitstream generation"
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

    # Property names verified against Vivado 2026.1 pcie_7x 3.3 property dump
    # Key renames from older Vivado:
    #   AER_CAP_ON   → AER_Enabled
    #   DSN_CAP_ON   → DSN_Enabled
    #   MSI_CAP_ON   → MSI_Enabled
    #   MSIX_CAP_ON  → MSIx_Enabled
    #   VC_CAP_ON    → VC_Cap_Enabled
    #   cfg_ext_en   → EXT_PCI_CFG_Space  (enables ECAP forwarding to user logic)
    #   Class_Code   → removed (derived from Base_Class_Menu + Sub_Class_Interface_Menu)
    #   Max_Link_Width → removed (use Maximum_Link_Width only)
    set_property -dict [list \
        CONFIG.Bar0_Scale               {Kilobytes} \
        CONFIG.Bar0_Size                {64} \
        CONFIG.Bar0_64bit               {true} \
        CONFIG.Bar0_Prefetchable        {true} \
        CONFIG.Bar1_Enabled             {false} \
        CONFIG.Bar2_Enabled             {false} \
        CONFIG.Bar3_Enabled             {false} \
        CONFIG.Bar4_Enabled             {false} \
        CONFIG.Bar5_Enabled             {false} \
        CONFIG.Vendor_ID                {10EC} \
        CONFIG.Device_ID                {8125} \
        CONFIG.Revision_ID              {36} \
        CONFIG.Subsystem_Vendor_ID      {10EC} \
        CONFIG.Subsystem_ID             {0123} \
        CONFIG.Base_Class_Menu          {Network_controller} \
        CONFIG.Sub_Class_Interface_Menu {Ethernet_controller} \
        CONFIG.Link_Speed               {5.0_GT/s} \
        CONFIG.Maximum_Link_Width       {X1} \
        CONFIG.Max_Payload_Size         {256_bytes} \
        CONFIG.Extended_Tag_Field       {false} \
        CONFIG.AER_Enabled              {true} \
        CONFIG.VC_Cap_Enabled           {false} \
        CONFIG.DSN_Enabled              {true} \
        CONFIG.MSIx_Enabled             {false} \
        CONFIG.MSI_Enabled              {true} \
        CONFIG.PCIe_Blk_Locn            {X0Y0} \
        CONFIG.EXT_PCI_CFG_Space        {true} \
    ] [get_ips pcie_7x_0]

    generate_target all [get_ips pcie_7x_0]
    puts "INFO: pcie_7x_0 IP created and targets generated"
} else {
    puts "INFO: pcie_7x_0 IP already exists, skipping creation"
}

# ---------------------------------------------------------------------------
# 5. Use the IP's internal PIPE clock generator; the wrapper has no external
# PIPE clock module. Leave the rest of an existing IP customization intact.
set core [get_ips pcie_7x_0]
if {[get_property CONFIG.en_ext_clk $core]} {
    set_property CONFIG.en_ext_clk false $core
    generate_target all $core
}
report_ip_status -file $rpt_dir/ip_status.rpt

# Synthesis and implementation
# Save the previous run's diagnostics before reset_run clears its directory.
set archive_dir [file join $rpt_dir [clock format [clock seconds] -format %Y%m%d-%H%M%S]-[pid]]
file mkdir $archive_dir
foreach name {synth_1 impl_1} {
    set run [get_runs $name]
    set status [get_property STATUS $run]
    puts "INFO: Previous $name status: $status"
    if {[string match -nocase "*running*" $status] || [string match -nocase "*queued*" $status]} {
        error "Run $name is active; wait for it to finish before rebuilding."
    }
    foreach log [glob -nocomplain -directory [get_property DIRECTORY $run] *.log *.jou *.rpt] {
        file copy $log [file join $archive_dir ${name}_[file tail $log]]
    }
}
proc run_step {name step} {
    launch_runs $name -to_step $step -jobs 4
    catch {wait_on_run -timeout 20 $name} wait_message
    set status [get_property STATUS [get_runs $name]]
    puts "INFO: $name status: $status"
    if {![string match "${step} Complete*" $status]} {
        error "$name failed or timed out at $step: $status ($wait_message). See [get_property DIRECTORY [get_runs $name]]/runme.log"
    }
}
reset_run synth_1
run_step synth_1 synth_design
open_run synth_1
report_utilization -file $archive_dir/synth_utilization.rpt
report_timing_summary -report_unconstrained -file $archive_dir/synth_timing.rpt
report_drc -file $archive_dir/synth_drc.rpt
report_cdc -file $archive_dir/synth_cdc.rpt
close_design
run_step impl_1 route_design
open_run impl_1
report_timing_summary -report_unconstrained -max_paths 20 -file $archive_dir/timing_summary.rpt
report_utilization -file $archive_dir/utilization.rpt
report_clock_interaction -file $archive_dir/clock_interaction.rpt
report_drc -file $archive_dir/drc.rpt
report_cdc -file $archive_dir/cdc.rpt
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} {
    error "Bitstream withheld: routed timing did not pass (WNS=$wns, WHS=$whs)."
}
if {[llength [get_files -quiet -of_objects [get_filesets constrs_1] -filter {FILE_TYPE == XDC}]] == 0} {
    error "Bitstream withheld: constrs_1 has no board XDC."
}
close_design
run_step impl_1 write_bitstream
puts "INFO: Bitstream: [get_property DIRECTORY [get_runs impl_1]]/pcie_top_wrapper.bit"
