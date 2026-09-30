# Nominal 50 MSPS external timing model, already active in awg_v2.xdc.
create_clock -name dac_wrt_virtual50 -period 20.000 -waveform {10.000 20.000}
set_output_delay -clock dac_wrt_virtual50 -max 2.0 [get_ports {dac_a_data[*] dac_b_data[*]}]
set_output_delay -clock dac_wrt_virtual50 -min -1.5 [get_ports {dac_a_data[*] dac_b_data[*]}]
