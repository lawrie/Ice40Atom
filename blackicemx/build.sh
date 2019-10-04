#!/bin/bash

TOP=atom
NAME=atom
PACKAGE=tq144:4k
SRCS="../src/atom.v ../src/cpu.v ../src/ALU.v ../src/rom_c000_f000.v ../src/mc6847.v ../src/charrom.v ../src/vid_ram.v ../src/keyboard.v ../src/ps2_intf.v ../src/flashmem.v ../src/spi.v ../src/m6522.v ../src/sid/sid_6581.v ../src/sid/sid_coeffs.v ../src/sid/sid_components.v ../src/sid/sid_filters.v ../src/sid/sid_voice.v ../src/pll.v ../src/sdram.v"

yosys -q -f "verilog -Dblackicmx -Duse_sb_io" -l ${NAME}.log -p "synth_ice40 -top ${TOP} -abc2 -json ${NAME}.json" ${SRCS}
nextpnr-ice40 --hx8k --package ${PACKAGE} --pcf blackice.pcf --json ${NAME}.json --asc ${NAME}.txt --placer heap
icepack ${NAME}.txt ${NAME}.bin
icetime -d hx8k -P ${PACKAGE} ${NAME}.txt
