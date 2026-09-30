# Reference 25 MSPS external timing model. Apply instead of the 50 MSPS
# virtual clock section in awg_v2.xdc for an individual 25 MSPS review.
create_clock -name dac_wrt_virtual25 -period 40.000 -waveform {20.000 40.000}
set_output_delay -clock dac_wrt_virtual25 -max 2.0 [get_ports {dac_a_data[*] dac_b_data[*]}]
set_output_delay -clock dac_wrt_virtual25 -min -1.5 [get_ports {dac_a_data[*] dac_b_data[*]}]
