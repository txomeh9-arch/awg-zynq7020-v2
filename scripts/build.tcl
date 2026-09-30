set root [file normalize [file join [file dirname [info script]] ..]]
set build [file join $root build]
file mkdir [file join $root reports]
open_project [file join $build vivado awg_v2.xpr]
set_property synth_checkpoint_mode None [get_files *awg_system.bd]
generate_target all [get_files *awg_system.bd]
update_compile_order -fileset sources_1
synth_design -top awg_system_wrapper -part xc7z020clg484-1
report_utilization -file [file join $root reports synth_utilization.rpt]
report_timing_summary -file [file join $root reports synth_timing.rpt]
write_checkpoint -force [file join $build post_synth.dcp]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file [file join $root reports timing_summary.rpt]
report_utilization -file [file join $root reports utilization.rpt]
report_clock_interaction -file [file join $root reports clock_interaction.rpt]
report_cdc -details -file [file join $root reports cdc.rpt]
report_drc -file [file join $root reports drc.rpt]
check_timing -verbose -file [file join $root reports check_timing.rpt]
write_checkpoint -force [file join $build post_route.dcp]
set worst [get_timing_paths -setup -max_paths 1]
if {[llength $worst] && [get_property SLACK [lindex $worst 0]] < 0} {
    error "Negative setup slack after route"
}
write_bitstream -force [file join $build awg_v2.bit]
write_hw_platform -fixed -force -file [file join $build awg_v2.xsa]
puts AWG_V2_BUILD_COMPLETE
