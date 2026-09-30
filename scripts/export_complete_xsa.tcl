# Project-run flow is required by Vivado 2026.1 to embed the bitstream in XSA.
set root [file normalize [file join [file dirname [info script]] ..]]
set build [file join $root build]
open_project [file join $build vivado awg_v2.xpr]
set_property synth_checkpoint_mode None [get_files *awg_system.bd]
generate_target all [get_files *awg_system.bd]
update_compile_order -fileset sources_1
# A previous interrupted project run can leave stale launch markers. Rebuild
# generated runs from the current RTL and constraints before exporting.
reset_run impl_1
reset_run synth_1
launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Project synthesis run did not complete"
}
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Project implementation run did not complete"
}
open_run impl_1
report_timing_summary -file [file join $root reports timing_summary.rpt]
report_drc -file [file join $root reports drc.rpt]
report_cdc -details -file [file join $root reports cdc.rpt]
check_timing -verbose -file [file join $root reports check_timing.rpt]
write_hw_platform -fixed -include_bit -force -file [file join $build awg_v2_complete.xsa]
set run_bit [file join $build vivado awg_v2.runs impl_1 awg_system_wrapper.bit]
if {![file exists $run_bit]} { error "Implementation bitstream missing: $run_bit" }
file copy -force $run_bit [file join $build awg_v2.bit]
puts AWG_V2_COMPLETE_XSA_EXPORTED
