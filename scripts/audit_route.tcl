set root [file normalize [file join [file dirname [info script]] ..]]
open_checkpoint [file join $root build post_route.dcp]
report_cdc -details -file [file join $root reports cdc.rpt]
report_bus_skew -file [file join $root reports bus_skew.rpt]
report_methodology -file [file join $root reports methodology.rpt]
puts AWG_V2_ROUTE_AUDIT_COMPLETE
