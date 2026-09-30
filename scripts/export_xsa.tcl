set root [file normalize [file join [file dirname [info script]] ..]]
set build [file join $root build]
open_project [file join $build vivado awg_v2.xpr]
open_checkpoint [file join $build post_route.dcp]
write_hw_platform -fixed -force -file [file join $build awg_v2.xsa]
puts AWG_V2_XSA_EXPORTED
