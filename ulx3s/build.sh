#!/bin/bash
DEVICE=85k
PIN_DEF=ulx3s_v20.lpf
IDCODE=0x41113043 # 85f
PACKAGE=CABGA381
TOP=atom
NAME=atom
SRCS="../src/atom.v ../src/cpu.v ../src/ALU.v ../src/rom_c000_f000.v ../src/mc6847.v ../src/charrom.v ../src/vid_ram.v ../src/keyboard.v ../src/ps2_intf.v ../src/flashmem.v ../src/spi.v ../src/m6522.v ../src/sid/sid_6581.v ../src/sid/sid_coeffs.v ../src/sid/sid_components.v ../src/sid/sid_filters.v ../src/sid/sid_voice.v pll.v ../src/sdram.v"

yosys -q -f "verilog -Dulx3s" -l ${NAME}.log -p "synth_ecp5 -top ${TOP} -abc9 -json ${NAME}.json" ${SRCS}
nextpnr-ecp5 --${DEVICE} --package ${PACKAGE} --lpf ${PIN_DEF} --json ${NAME}.json --textcfg ${NAME}.config
ecppack --compress --idcode ${IDCODE} ${NAME}.config ${NAME}.bit

