# Invoked by download_jtag.ps1 with ps7_init.tcl, ELF and bitstream paths.
if {[llength $argv] != 3} { error "Expected ps7_init.tcl, ELF, BIT arguments" }
lassign $argv init_file elf_file bit_file
foreach path [list $init_file $elf_file $bit_file] {
    if {![file exists $path]} { error "JTAG input missing: $path" }
}
connect
targets -set -filter {name =~ "ARM Cortex-A9*#0"}
rst -system
after 1000
source $init_file
ps7_init
ps7_post_config
fpga -file $bit_file
dow $elf_file
con
puts "AWG_V2_JTAG_DOWNLOAD_COMPLETE"
