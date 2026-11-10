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
foreach pkg_name {rtl8125b_identity_pkg.sv opcode_scramble_pkg.sv} {
    set pkg [get_files -quiet -of_objects $srcset *$pkg_name]
    if {[llength $pkg]} {
        reorder_files -fileset $srcset -front $pkg
    }
}
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
#    Donor RTL8125B rev 05: I/O 256 + MEM64 64K npref + MEM64 16K npref,
#    MSI 1-vector maskable 64-bit, MSI-X 32 vec BAR4, DSN/AER/VC.
#    Property names verified against Vivado 2026.1 pcie_7x 3.3:
#      AER_CAP_ON → AER_Enabled, DSN_CAP_ON → DSN_Enabled,
#      MSI_CAP_ON → MSI_Enabled, MSIX_CAP_ON → MSIx_Enabled,
#      VC_CAP_ON → VC_Cap_Enabled, cfg_ext_en → EXT_PCI_CFG_Space
#    Optional cap-pointer names (PM_BASE_PTR / MSI_BASE_PTR / PCIE_BASE_PTR)
#    are applied only when the core exposes them.
# ---------------------------------------------------------------------------
proc ip_has_cfg {ip name} {
    return [expr {[lsearch -exact [list_property $ip] CONFIG.$name] >= 0}]
}
proc ip_try_set {ip name value} {
    if {[ip_has_cfg $ip $name]} {
        set_property CONFIG.$name $value $ip
        puts "INFO: CONFIG.$name = $value"
        return 1
    }
    puts "WARN: CONFIG.$name not in this pcie_7x; skipped"
    return 0
}

set ip_exists [get_ips -quiet pcie_7x_0]
if {[llength $ip_exists] == 0} {
    set avail [get_ipdefs "xilinx.com:ip:pcie_7x:*" -quiet]
    if {[llength $avail] == 0} {
        error "pcie_7x IP not found in catalog — check Vivado installation"
    }
    set ip_ver [lindex [split [lindex $avail 0] {:}] end]
    puts "INFO: using pcie_7x version $ip_ver"
    create_ip -name pcie_7x -vendor xilinx.com -library ip \
              -version $ip_ver -module_name pcie_7x_0
} else {
    puts "INFO: pcie_7x_0 IP already exists; re-applying donor CONFIG"
}

set core [get_ips pcie_7x_0]
set_property -dict [list \
    CONFIG.Vendor_ID                {10EC} \
    CONFIG.Device_ID                {8125} \
    CONFIG.Revision_ID              {05} \
    CONFIG.Subsystem_Vendor_ID      {10EC} \
    CONFIG.Subsystem_ID             {0123} \
    CONFIG.Base_Class_Menu          {Network_controller} \
    CONFIG.Sub_Class_Interface_Menu {Ethernet_controller} \
    CONFIG.Link_Speed               {5.0_GT/s} \
    CONFIG.Maximum_Link_Width       {X1} \
    CONFIG.Max_Payload_Size         {256_bytes} \
    CONFIG.Extended_Tag_Field       {false} \
    CONFIG.AER_Enabled              {true} \
    CONFIG.DSN_Enabled              {true} \
    CONFIG.MSIx_Enabled             {true} \
    CONFIG.MSI_Enabled              {true} \
    CONFIG.PCIe_Blk_Locn            {X0Y0} \
    CONFIG.EXT_PCI_CFG_Space        {true} \
] $core

# BAR0: I/O 256 B. BAR2: 64-bit npref 64 KB MAC. BAR4: 64-bit npref 16 KB MSI-X.
ip_try_set $core Bar0_Enabled      true
ip_try_set $core Bar0_Type         IO
ip_try_set $core Bar0_64bit        false
ip_try_set $core Bar0_Prefetchable false
ip_try_set $core Bar0_Scale        Bytes
ip_try_set $core Bar0_Size         256
ip_try_set $core Bar1_Enabled      false
ip_try_set $core Bar2_Enabled      true
ip_try_set $core Bar2_Type         Memory
ip_try_set $core Bar2_64bit        true
ip_try_set $core Bar2_Prefetchable false
ip_try_set $core Bar2_Scale        Kilobytes
ip_try_set $core Bar2_Size         64
ip_try_set $core Bar3_Enabled      false
ip_try_set $core Bar4_Enabled      true
ip_try_set $core Bar4_Type         Memory
ip_try_set $core Bar4_64bit        true
ip_try_set $core Bar4_Prefetchable false
ip_try_set $core Bar4_Scale        Kilobytes
ip_try_set $core Bar4_Size         16
ip_try_set $core Bar5_Enabled      false
ip_try_set $core Expansion_Rom_Enabled false

# Cap pointers: PM 0x40, MSI 0x50, PCIe 0x70, MSI-X 0xB0. DSN at 0x168.
foreach {n v} {
    PM_BASE_PTR            40
    MSI_BASE_PTR           50
    PCIE_BASE_PTR          70
    MSIX_BASE_PTR          B0
    PM_Cap_Nextptr         50
    MSI_Cap_Nextptr        70
    PCIE_Cap_Nextptr       B0
    DSN_BASE_PTR           168
    DSN_Cap_Nextptr        178
    VC_Cap_Enabled         true
} {
    ip_try_set $core $n $v
}

# MSI: 1 vector, 64-bit, maskable.
foreach {n v} {
    MSI_64_bit               true
    MSI_Capable_Maskable     true
    MSI_Vector_Width         1_vector
    Multiple_Message_Capable 1_vector
} {
    ip_try_set $core $n $v
}

# MSI-X: 32 vectors, BAR4, table byte 0, PBA byte 0x800.
# Table Size is a count on some cores and N-1 (0x1F) on others; BIR is
# either BAR_4:5 or integer 4.
if {![ip_try_set $core MSIx_Table_Size 32]} {
    ip_try_set $core MSIx_Table_Size 1F
}
if {![ip_try_set $core MSIx_Table_BIR BAR_4:5]} {
    ip_try_set $core MSIx_Table_BIR 4
}
ip_try_set $core MSIx_Table_Offset 00000000
if {![ip_try_set $core MSIx_PBA_BIR BAR_4:5]} {
    ip_try_set $core MSIx_PBA_BIR 4
}
if {![ip_try_set $core MSIx_PBA_Offset 00000800]} {
    ip_try_set $core MSIx_PBA_Offset 800
}

# PM / PCIe device+link: D1+D2, Aux 375mA, ASPM L0s+L1, ClockPM, RBE, LTR.
foreach {n v} {
    D1_Support             true
    D2_Support             true
    PME_Support_D0         true
    PME_Support_D1         true
    PME_Support_D2         true
    PME_Support_D3hot      true
    PME_Support_D3cold     true
    No_Soft_Reset          true
    Aux_Current            375_mA
    ASPM_Support           L0s_L1_Supported
    Enable_Slot_Clock_Cfg  true
    Clock_PM               true
    Role_Based_Error_Reporting true
    DevCap2_LTR            true
} {
    ip_try_set $core $n $v
}

generate_target all $core
puts "INFO: pcie_7x_0 donor CONFIG applied and targets generated"

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
