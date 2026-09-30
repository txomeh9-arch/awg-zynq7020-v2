set root [file normalize [file join [file dirname [info script]] ..]]
set build [file join $root build]
file mkdir $build
create_project awg_v2 [file join $build vivado] -part xc7z020clg484-1 -force
set_property target_language Verilog [current_project]
add_files [glob [file join $root rtl *.sv]]
add_files [file join $root rtl sine1024.mem]
set_property file_type {Memory Initialization Files} [get_files sine1024.mem]
add_files -fileset constrs_1 [file join $root constraints awg_v2.xdc]

create_bd_design awg_system
set_property synth_checkpoint_mode None [get_files *awg_system.bd]
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict [list \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {16 Bit} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ {400} \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_ENET0_ENET0_IO {EMIO} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO {EMIO} \
    CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART0_UART0_IO {EMIO} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP1 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ {25} \
    CONFIG.PCW_FPGA3_PERIPHERAL_FREQMHZ {2.5} \
    CONFIG.PCW_EN_CLK1_PORT {1} \
    CONFIG.PCW_EN_CLK2_PORT {1} \
    CONFIG.PCW_EN_CLK3_PORT {1} \
    CONFIG.PCW_FPGA_FCLK1_ENABLE {1} \
    CONFIG.PCW_FPGA_FCLK2_ENABLE {1} \
    CONFIG.PCW_FPGA_FCLK3_ENABLE {1}] $ps
make_bd_intf_pins_external [get_bd_intf_pins ps7/DDR]
make_bd_intf_pins_external [get_bd_intf_pins ps7/FIXED_IO]

set phy [create_bd_cell -type ip -vlnv xilinx.com:ip:gmii_to_rgmii:4.1 eth_bridge]
connect_bd_intf_net [get_bd_intf_pins ps7/GMII_ETHERNET_0] [get_bd_intf_pins eth_bridge/GMII]
connect_bd_intf_net [get_bd_intf_pins ps7/MDIO_ETHERNET_0] [get_bd_intf_pins eth_bridge/MDIO_GEM]
make_bd_intf_pins_external [get_bd_intf_pins eth_bridge/RGMII]
make_bd_intf_pins_external [get_bd_intf_pins eth_bridge/MDIO_PHY]
make_bd_intf_pins_external [get_bd_intf_pins ps7/UART_0]
connect_bd_net [get_bd_pins ps7/FCLK_CLK1] [get_bd_pins eth_bridge/ref_clk_in]
connect_bd_net [get_bd_pins ps7/FCLK_CLK2] [get_bd_pins eth_bridge/gmii_clk_25m_in]
connect_bd_net [get_bd_pins ps7/FCLK_CLK3] [get_bd_pins eth_bridge/gmii_clk_2_5m_in]
set eth125 [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:* eth_clk125]
set_property -dict [list CONFIG.PRIM_IN_FREQ {200.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {125.000} CONFIG.NUM_OUT_CLKS {1} \
    CONFIG.USE_RESET {false}] $eth125
connect_bd_net [get_bd_pins ps7/FCLK_CLK1] [get_bd_pins eth_clk125/clk_in1]
connect_bd_net [get_bd_pins eth_clk125/clk_out1] [get_bd_pins eth_bridge/gmii_clk_125m_in]
connect_bd_net [get_bd_pins eth_clk125/locked] [get_bd_pins eth_bridge/mmcm_locked_in]

set reset [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst100]
set invert [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:* inv_ps_rst]
set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] $invert
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins inv_ps_rst/Op1]
connect_bd_net [get_bd_pins inv_ps_rst/Res] [get_bd_pins rst100/ext_reset_in]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst100/slowest_sync_clk]
connect_bd_net [get_bd_pins rst100/peripheral_reset] [get_bd_pins eth_bridge/rx_reset] [get_bd_pins eth_bridge/tx_reset]

set ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:* gpio_command]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {1} CONFIG.C_ALL_OUTPUTS_2 {1}] $ctrl
set status [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:* gpio_status]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1}] $status

foreach channel {a b} {
    set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma_$channel]
    set_property -dict [list CONFIG.c_include_sg {1} CONFIG.c_include_mm2s {1} \
        CONFIG.c_include_s2mm {0} CONFIG.c_m_axis_mm2s_tdata_width {16} \
        CONFIG.c_mm2s_burst_size {256}] $dma
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
        [get_bd_pins dma_$channel/s_axi_lite_aclk] \
        [get_bd_pins dma_$channel/m_axi_mm2s_aclk] \
        [get_bd_pins dma_$channel/m_axi_sg_aclk]
    connect_bd_net [get_bd_pins rst100/peripheral_aresetn] [get_bd_pins dma_$channel/axi_resetn]
}

set ctrl_bus [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* ctrl_bus]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {4}] $ctrl_bus
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins ctrl_bus/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_bus/M00_AXI] [get_bd_intf_pins gpio_command/S_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_bus/M01_AXI] [get_bd_intf_pins gpio_status/S_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_bus/M02_AXI] [get_bd_intf_pins dma_a/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_bus/M03_AXI] [get_bd_intf_pins dma_b/S_AXI_LITE]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins ctrl_bus/aclk] [get_bd_pins gpio_command/s_axi_aclk] \
    [get_bd_pins gpio_status/s_axi_aclk]
connect_bd_net [get_bd_pins rst100/peripheral_aresetn] [get_bd_pins ctrl_bus/aresetn] \
    [get_bd_pins gpio_command/s_axi_aresetn] [get_bd_pins gpio_status/s_axi_aresetn]

foreach {channel hp} {a 0 b 1} {
    set fabric [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* hp_$channel]
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $fabric
    connect_bd_intf_net [get_bd_intf_pins dma_$channel/M_AXI_MM2S] [get_bd_intf_pins hp_$channel/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_$channel/M_AXI_SG] [get_bd_intf_pins hp_$channel/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins hp_$channel/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP$hp]
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins hp_$channel/aclk] \
        [get_bd_pins ps7/S_AXI_HP${hp}_ACLK]
    connect_bd_net [get_bd_pins rst100/peripheral_aresetn] [get_bd_pins hp_$channel/aresetn]
}

set engine [create_bd_cell -type module -reference awg_pl pl_engine]
connect_bd_intf_net [get_bd_intf_pins dma_a/M_AXIS_MM2S] [get_bd_intf_pins pl_engine/S_AXIS_A]
connect_bd_intf_net [get_bd_intf_pins dma_b/M_AXIS_MM2S] [get_bd_intf_pins pl_engine/S_AXIS_B]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins pl_engine/s_axis_aclk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK1] [get_bd_pins pl_engine/idelay_refclk_200]
connect_bd_net [get_bd_pins rst100/peripheral_reset] [get_bd_pins pl_engine/idelay_reset]
connect_bd_net [get_bd_pins gpio_command/gpio_io_o] [get_bd_pins pl_engine/ctrl_word]
connect_bd_net [get_bd_pins gpio_command/gpio2_io_o] [get_bd_pins pl_engine/ctrl_toggle]
connect_bd_net [get_bd_pins pl_engine/status_word] [get_bd_pins gpio_status/gpio_io_i]
foreach {pin direction width} {
    clk_50m I 1 key1_n I 1 trigger_in I 1 marker_out O 1
    dac_a_data O 14 dac_b_data O 14
    dac_a_clk O 1 dac_b_clk O 1 dac_a_wrt O 1 dac_b_wrt O 1
} {
    if {$width == 1} {
        set port [create_bd_port -dir $direction $pin]
    } else {
        set port [create_bd_port -dir $direction -from [expr {$width-1}] -to 0 $pin]
    }
    connect_bd_net $port [get_bd_pins pl_engine/$pin]
}
assign_bd_address
validate_bd_design
save_bd_design
generate_target all [get_files *awg_system.bd]
make_wrapper -files [get_files *awg_system.bd] -top
add_files -norecurse [glob [file join $build vivado awg_v2.gen sources_1 bd awg_system hdl *_wrapper.v]]
set_property top awg_system_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts AWG_V2_PROJECT_CREATED
