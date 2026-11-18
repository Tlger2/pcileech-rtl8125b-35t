# Rebuild with BAR0 omitted and MSI-X table/PBA in BAR4.
# Polls run status instead of wait_on_run (that call hung after synth).
open_project C:/Users/jaxso/pcileech-rtl8125b-35t/vivado_project/rtl8125b_dma.xpr
update_compile_order -fileset sources_1

proc ip_try_set {ip name value} {
    if {[lsearch -exact [list_property $ip] CONFIG.$name] < 0} {
        puts "WARN: CONFIG.$name not present"
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

proc poll_run {name timeout_s} {
    set t0 [clock seconds]
    while {1} {
        set st [get_property STATUS [get_runs $name]]
        set pr [get_property PROGRESS [get_runs $name]]
        puts "POLL $name progress=$pr status=$st"
        if {[string match "*Complete*" $st]} {
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

set core [get_ips pcie_7x_0]
if {![llength $core]} {
    puts "NO_PCIE_IP"
    exit 1
}

puts "INFO: Bar0_Enabled=[get_property CONFIG.Bar0_Enabled $core]"
puts "INFO: Bar2_Enabled=[get_property CONFIG.Bar2_Enabled $core] size=[get_property CONFIG.Bar2_Size $core]"
puts "INFO: Bar4_Enabled=[get_property CONFIG.Bar4_Enabled $core] size=[get_property CONFIG.Bar4_Size $core]"
puts "INFO: MSIx_Enabled=[get_property CONFIG.MSIx_Enabled $core]"
puts "INFO: MSIx_Table_BIR=[get_property CONFIG.MSIx_Table_BIR $core]"
puts "INFO: MSIx_PBA_BIR=[get_property CONFIG.MSIx_PBA_BIR $core]"
catch {puts "INFO: MSIx_Table_BIR allowed={[list_property_value CONFIG.MSIx_Table_BIR $core]}"}

set ip_dirty 0
if {[get_property CONFIG.Bar0_Enabled $core] == true} {
    ip_try_set $core Bar0_Enabled false
    set ip_dirty 1
}
if {[get_property CONFIG.Bar2_Enabled $core] != true} {
    ip_try_set $core Bar2_Enabled true
    ip_try_set $core Bar2_Type Memory
    ip_try_set $core Bar2_64bit true
    ip_try_set $core Bar2_Prefetchable false
    ip_try_set $core Bar2_Scale Kilobytes
    ip_try_set $core Bar2_Size 64
    set ip_dirty 1
}
if {[get_property CONFIG.Bar4_Enabled $core] != true} {
    ip_try_set $core Bar4_Enabled true
    ip_try_set $core Bar4_Type Memory
    ip_try_set $core Bar4_64bit true
    ip_try_set $core Bar4_Prefetchable false
    ip_try_set $core Bar4_Scale Kilobytes
    ip_try_set $core Bar4_Size 16
    set ip_dirty 1
}

set table_bir [get_property CONFIG.MSIx_Table_BIR $core]
set pba_bir   [get_property CONFIG.MSIx_PBA_BIR $core]
set table_ok  [expr {$table_bir in {BAR_5:4 BAR_4:5 BAR_4 4}}]
set pba_ok    [expr {$pba_bir in {BAR_5:4 BAR_4:5 BAR_4 4}}]
if {!$table_ok} {
    set msix_bir_ok 0
    foreach bir {BAR_5:4 BAR_4:5 BAR_4 4} {
        if {[ip_try_set $core MSIx_Table_BIR $bir]} {
            set msix_bir_ok 1
            break
        }
    }
    if {!$msix_bir_ok} {
        puts "MSIX_BIR_FAILED table"
        exit 1
    }
    set ip_dirty 1
}
if {!$pba_ok} {
    set msix_pba_ok 0
    foreach bir {BAR_5:4 BAR_4:5 BAR_4 4} {
        if {[ip_try_set $core MSIx_PBA_BIR $bir]} {
            set msix_pba_ok 1
            break
        }
    }
    if {!$msix_pba_ok} {
        puts "MSIX_BIR_FAILED pba"
        exit 1
    }
    set ip_dirty 1
}

puts "INFO: MSIx_Table_BIR now=[get_property CONFIG.MSIx_Table_BIR $core]"
puts "INFO: MSIx_PBA_BIR now=[get_property CONFIG.MSIx_PBA_BIR $core]"

if {$ip_dirty} {
    generate_target all $core
    puts "INFO: pcie_7x_0 targets regenerated"
}

foreach name {synth_1 impl_1} {
    set st [get_property STATUS [get_runs $name]]
    if {[string match -nocase "*running*" $st] || [string match -nocase "*queued*" $st]} {
        puts "INFO: resetting stuck $name ($st)"
        reset_run $name
    }
}

reset_run synth_1
launch_runs synth_1 -jobs 4
if {![poll_run synth_1 900]} {
    exit 1
}
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
if {![poll_run impl_1 1800]} {
    exit 1
}

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts "INFO: timing WNS=$wns WHS=$whs"
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} {
    puts "TIMING_FAILED WNS=$wns WHS=$whs"
    exit 1
}

set rundir [get_property DIRECTORY [get_runs impl_1]]
set bit $rundir/pcie_top_wrapper.bit
set bin $rundir/pcie_top_wrapper.bin
if {[file exists $bit]} {
    puts "BITSTREAM OK: $bit"
} else {
    puts "BITSTREAM_MISSING $bit"
    exit 1
}
# IS25LP032 is 32 Mbit; XC7A35T bitstream is 16.85 Mbit so size 16 overflows.
if {[catch {
    write_cfgmem -format bin -interface SPIx4 -size 32 \
        -loadbit "up 0x0 $bit" -force $bin
} cfgmem_err]} {
    puts "WARN: write_cfgmem failed ($cfgmem_err)"
} else {
    puts "BIN OK: $bin"
}
exit 0
