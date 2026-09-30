# Reference 10 MSPS external timing model. Apply instead of the 50 MSPS
# virtual clock section in awg_v2.xdc for an individual 10 MSPS review.
create_clock -name dac_wrt_virtual10 -period 100.000 -waveform {50.000 100.000}
set_output_delay -clock dac_wrt_virtual10 -max 2.0 [get_ports {dac_a_data[*] dac_b_data[*]}]
set_output_delay -clock dac_wrt_virtual10 -min -1.5 [get_ports {dac_a_data[*] dac_b_data[*]}]
