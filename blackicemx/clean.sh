#!/bin/bash

PROG=atom

# Remove BlackIce files
rm -f $PROG.json $PROG.txt $PROG.bin $PROG.log

# Remove Simulation files
rm -f a.out dump.vcd
