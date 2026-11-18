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
    if {![ip_has_cfg $ip $name]} {
        puts "WARN: CONFIG.$name not in this pcie_7x; skipped"
        return 0
    }
    if {[catch {set_property CONFIG.$name $value $ip} err]} {
        set allowed {}
        catch {set allowed [list_property_value CONFIG.$name $ip]}
        puts "WARN: CONFIG.$name = $value failed ($err); allowed={$allowed}"
        return 0
    }
    puts "INFO: CONFIG.$name = $value"
    return 1
}
proc pcie7x_create {} {
    set avail [get_ipdefs "xilinx.com:ip:pcie_7x:*" -quiet]
    if {[llength $avail] == 0} {
        error "pcie_7x IP not found in catalog — check Vivado installation"
    }
    set ip_ver [lindex [split [lindex $avail 0] {:}] end]
    puts "INFO: using pcie_7x version $ip_ver"
    create_ip -name pcie_7x -vendor xilinx.com -library ip \
              -version $ip_ver -module_name pcie_7x_0
}
proc pcie7x_recreate {} {
    puts "INFO: recreating pcie_7x_0 so BAR0 Type enum can include I/O"
    set xci [get_files -quiet pcie_7x_0.xci]
    catch {export_ip_user_files -of_objects [get_ips pcie_7x_0] -no_script -reset -force}
    if {[llength $xci]} {
        remove_files -fileset sources_1 $xci
    }
    catch {file delete -force [file normalize "[file dirname [info script]]/vivado_project/rtl8125b_dma.srcs/sources_1/ip/pcie_7x_0"]}
    pcie7x_create
}

if {[llength [get_ips -quiet pcie_7x_0]] == 0} {
    pcie7x_create
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
    CONFIG.Link_Speed               {2.5_GT/s} \
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
# Wrapper wires cfg_ext_* — do not turn EXT_PCI_CFG_Space off.

# BAR0: donor I/O 256 B. Vivado 2026.1 pcie_7x may only allow Memory on an
# already-customized core (Bar0_Type IO aborts the whole script without catch).
# Try IO spellings first; if the enum is Memory-only, recreate the IP once.
# 2026.1 pcie_7x 3.3: Bar0_Type valid values are Memory only. Do not poke IO
# (it restores the whole IP customization). Donor I/O 256 B is Memory 256 B here.
# 7-series 2026.1 has no I/O BAR. A 256 B *Memory* BAR0 is worse than omitting
# it: rtcx21 maps the first memory resource as the 64 KB MAC window, sees 256 B,
# and returns Code 10 / D3. The onboard RTL8125B on this machine also has no I/O
# resource — only 64 KB BAR2 + 16 KB BAR4. Match that.
puts "WARN: pcie_7x 2026.1 has no I/O BAR0; disabling BAR0 (MAC lives in BAR2)"
ip_try_set $core Bar0_Enabled      false
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

# Cap pointers: PM 0x40, MSI 0x50, PCIe 0x70, MSI-X 0xB0.
# ECAP: AER 0x100 → VC 0x148 → DSN 0x168 → TPH 0x178 → LTR 0x204 → L1PM 0x20C → VSEC 0x21C
foreach {n v} {
    PM_BASE_PTR            40
    MSI_BASE_PTR           50
    PCIE_BASE_PTR          70
    MSIX_BASE_PTR          B0
    PM_Cap_Nextptr         50
    MSI_Cap_Nextptr        70
    PCIE_Cap_Nextptr       B0
    AER_Base_Ptr           100
    VC_BASE_PTR            148
    VC_Cap_Nextptr         168
    DSN_BASE_PTR           168
    DSN_Cap_Nextptr        178
    TPH_BASE_PTR           178
    LTR_BASE_PTR           204
    L1_PM_SUBSTATES_BASE_PTR 20C
    VSEC_BASE_PTR          21C
    VC_Cap_Enabled         true
    TPH_Enabled            true
    LTR_CTL_ON             true
    LTR_Enabled            true
    L1_PM_Substates        true
    VSEC_Enabled           true
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

# MSI-X: 32 vectors in BAR4 (16 KB), table byte 0, PBA byte 0x800.
# Table Size is a count on some cores and N-1 (0x1F) on others.
# BIR must be the BAR4 pair. BAR_3:2 puts the table on top of the MAC
# window and rtcx21 Code-10s after it clobbers TxConfig.
if {![ip_try_set $core MSIx_Table_Size 32]} {
    ip_try_set $core MSIx_Table_Size 1F
}
set msix_bir_ok 0
foreach bir {BAR_5:4 BAR_4:5 BAR_4 4} {
    if {[ip_try_set $core MSIx_Table_BIR $bir]} {
        set msix_bir_ok 1
        break
    }
}
if {!$msix_bir_ok} {
    error "MSIx_Table_BIR could not be placed in BAR4; refusing BAR2 overlay"
}
ip_try_set $core MSIx_Table_Offset 00000000
set msix_pba_ok 0
foreach bir {BAR_5:4 BAR_4:5 BAR_4 4} {
    if {[ip_try_set $core MSIx_PBA_BIR $bir]} {
        set msix_pba_ok 1
        break
    }
}
if {!$msix_pba_ok} {
    error "MSIx_PBA_BIR could not be placed in BAR4; refusing BAR2 overlay"
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
foreach name {synth_1 impl_1 pcie_7x_0_synth_1} {
    set run [get_runs -quiet $name]
    if {![llength $run]} { continue }
    set status [get_property STATUS $run]
    puts "INFO: Previous $name status: $status"
    if {[string match -nocase "*running*" $status] || [string match -nocase "*queued*" $status]} {
        puts "INFO: resetting stuck $name ($status)"
        reset_run $name
    }
    foreach log [glob -nocomplain -directory [get_property DIRECTORY $run] *.log *.jou *.rpt] {
        file copy $log [file join $archive_dir ${name}_[file tail $log]]
    }
}
proc poll_run {name timeout_s {step ""}} {
    set t0 [clock seconds]
    while {1} {
        set st [get_property STATUS [get_runs $name]]
        set pr [get_property PROGRESS [get_runs $name]]
        puts "POLL $name progress=$pr status=$st"
        if {$step ne ""} {
            if {[string match "${step} Complete*" $st]} {
                return 1
            }
        } elseif {[string match "*Complete*" $st] ||
                  [string match "*cached IP*" $st]} {
            return 1
        }
        if {[string match "*Fail*" $st] || [string match "*Error*" $st]} {
            puts "RUN_FAILED $name: $st"
            return 0
        }
        if {([clock seconds] - $t0) > $timeout_s} {
            puts "RUN_TIMEOUT $name: $st"
            return 0
        }
        after 15000
    }
}
proc run_step {name step} {
    launch_runs $name -to_step $step -jobs 4
    # wait_on_run has hung after synth on this host; poll STATUS instead.
    set timeout_s 3600
    if {$name eq "synth_1"} { set timeout_s 1800 }
    if {![poll_run $name $timeout_s $step]} {
        error "$name failed at $step: [get_property STATUS [get_runs $name]]. See [get_property DIRECTORY [get_runs $name]]/runme.log"
    }
    set status [get_property STATUS [get_runs $name]]
    puts "INFO: $name status: $status"
    if {![string match "${step} Complete*" $status] &&
        !($step eq "" && [string match "*cached IP*" $status])} {
        error "$name failed at $step: $status. See [get_property DIRECTORY [get_runs $name]]/runme.log"
    }
}
# Force IP OOC re-synthesis — Vivado reuses the cached DCP unless we reset the
# IP's own synthesis run explicitly.  Without this, a manual XCI edit (e.g.
# Link_Speed Gen2→Gen1) is silently ignored and the stale DCP ends up in the
# bitstream.
set ip_synth_run_name pcie_7x_0_synth_1
set ip_synth_run [get_runs -quiet $ip_synth_run_name]
if {[llength $ip_synth_run]} {
    puts "INFO: Resetting $ip_synth_run_name to force OOC re-synthesis from XCI"
    reset_run $ip_synth_run_name
    launch_runs $ip_synth_run_name -jobs 4
    if {![poll_run $ip_synth_run_name 1800]} {
        error "$ip_synth_run_name failed: [get_property STATUS [get_runs $ip_synth_run_name]]. See [get_property DIRECTORY [get_runs $ip_synth_run_name]]/runme.log"
    }
    set ip_status [get_property STATUS [get_runs $ip_synth_run_name]]
    puts "INFO: $ip_synth_run_name status: $ip_status"
    if {![string match "*Complete*" $ip_status] &&
        ![string match "*cached IP*" $ip_status]} {
        error "$ip_synth_run_name failed: $ip_status. See [get_property DIRECTORY [get_runs $ip_synth_run_name]]/runme.log"
    }
} else {
    puts "WARN: Run $ip_synth_run_name not found — IP OOC synth may reuse stale DCP"
}

# Clear incremental checkpoint — force full re-elaboration
set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]
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
# Write the bitstream from the open routed design. launch_runs write_bitstream
# is easy to miss: poll_run can see "route_design Complete!" and return early.
set bit_path [file join [get_property DIRECTORY [get_runs impl_1]] pcie_top_wrapper.bit]
set bin_path [file join [get_property DIRECTORY [get_runs impl_1]] pcie_top_wrapper.bin]
puts "INFO: WNS=$wns WHS=$whs — writing $bit_path"
write_bitstream -force $bit_path
puts "INFO: Bitstream: $bit_path"

# Generate SPI-flashable .bin image (SPIx4). CaptainDMA 35T flash is ISSI
# IS25LP032 (32 Mbit). XC7A35T bitstream is 16.85 Mbit, so size 16 is too
# small; size 32 matches the part. OFL can also program the .bit directly.
write_cfgmem -format bin -interface SPIx4 -size 32 \
    -loadbit "up 0x0 $bit_path" \
    -force $bin_path
puts "INFO: SPI flash image: $bin_path"
puts "INFO: Flash with: openFPGALoader -c ft4232 --fpga-part xc7a35tfgg484 -f --verify --unprotect-flash $bin_path"
