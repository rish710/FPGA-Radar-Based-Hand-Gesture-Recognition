set_property PACKAGE_PIN AH12 [get_ports clk_p]
set_property PACKAGE_PIN AJ12 [get_ports clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports clk_p]
set_property IOSTANDARD DIFF_SSTL12 [get_ports clk_n]

## Tell Vivado this is a 300 MHz clock
create_clock -period 10.5 -name sys_clk [get_ports clk_p]

########################################################
## Reset, Start, and Done signals mapped to PMOD J7
## (3.3V LVCMOS I/O standard)
########################################################

## rst_n ? J7 pin 1 (bank 65, G8)
set_property PACKAGE_PIN G8 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

## start ? J7 pin 2 (bank 65, H8)
set_property PACKAGE_PIN H8 [get_ports start]
set_property IOSTANDARD LVCMOS33 [get_ports start]

## done ? J7 pin 3 (bank 65, G6)
set_property PACKAGE_PIN G6 [get_ports done]
set_property IOSTANDARD LVCMOS33 [get_ports done]

########################################################
## Optional: Set internal pull-ups for rst_n and start
########################################################
set_property PULLUP true [get_ports rst_n]
set_property PULLUP true [get_ports start]




set_property DONT_TOUCH true [get_cells -hier *u_depthwise*]
set_property DONT_TOUCH true [get_cells -hier *u_depthwise2*]
set_property DONT_TOUCH true [get_cells -hier *u_depthwise2*]
set_property DONT_TOUCH true [get_cells -hier *u_depthwise3*]
set_property DONT_TOUCH true [get_cells -hier *u_pointwise*]
set_property DONT_TOUCH true [get_cells -hier *u_pointwise2*]
set_property DONT_TOUCH true [get_cells -hier *u_pointwise3*]
set_property DONT_TOUCH true [get_cells -hier *u_batchnorm*]
set_property DONT_TOUCH true [get_cells -hier *u_batchnorm2*]
set_property DONT_TOUCH true [get_cells -hier *u_batchnorm3*]
set_property DONT_TOUCH true [get_cells -hier *u_batchnorm4*]
set_property DONT_TOUCH true [get_cells -hier *u_gconv*]
set_property DONT_TOUCH true [get_cells -hier *u_relu_pool*]
set_property DONT_TOUCH true [get_cells -hier *u_relu_pool2*]
set_property DONT_TOUCH true [get_cells -hier *u_relu_pool3*]
set_property DONT_TOUCH true [get_cells -hier *u_relu_pool4*]
set_property DONT_TOUCH true [get_cells -hier *u_fc1*]
set_property DONT_TOUCH true [get_cells -hier *u_fc2*]

set_property DONT_TOUCH true [get_cells -hier -filter {REF_NAME =~ LUT*}]
set_property DONT_TOUCH true [get_cells -hier -filter {REF_NAME =~ LUT*}]
set_property DONT_TOUCH true [get_cells -hier -filter {REF_NAME =~ FD*}]
