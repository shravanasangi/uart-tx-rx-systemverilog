# 100 MHz clock constraint used for the Vivado implementation results in the README
create_clock -period 10.000 -name clk [get_ports clk]
