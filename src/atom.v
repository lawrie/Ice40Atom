// =======================================================================
// Ice40Atom
//
// An Acorn Atom implementation for the Ice40
//
// Copyright (C) 2017 David Banks
// Modified by Lawrie Griffiths for Blackice Mx
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see http://www.gnu.org/licenses/.
// =======================================================================

module atom
   (
             // Main clock, 25MHz
             input         clk25,
`ifdef ulx3s
             output usb_fpga_pu_dp,
             output usb_fpga_pu_dn,
`endif	   
	     // flashmem
`ifdef ulx3s
`else
             output flash_sck,
`endif
             output flash_csn,
             output flash_mosi,
             input flash_miso,
             // SD Card SPI master
             output        ss,
             output        sclk,
             output        mosi,
             input         miso,
             // Switches
             input         button,
             inout      [15:0] sd_data,    // 16 bit bidirectional data bus
`ifdef ulx3s
             output     [12:0] sd_addr,    // 11 bit multiplexed address bus
`else
             output     [10:0] sd_addr,    // 11 bit multiplexed address bus
`endif
             output     [1:0]  sd_dqm,     // two byte masks
`ifdef ulx3s
             output     [1:0]  sd_ba,      // two banks
`else
             output     [0:0]  sd_ba,      // two banks
`endif
             output            sd_cs,      // a single chip select
             output            sd_we,      // write enable
             output            sd_ras,     // row address select
             output            sd_cas,     // columns address select
             output            sd_cke,     // clock enable
             output            sd_clk,     // sdram clock
             // Cassette / Sound
             input         cas_in,
             output        cas_out,
             output        sound,
             // Keyboard
             input         ps2_clk,
             input         ps2_data,
             // Video
             output [3:0]  red,
             output [3:0]  green,
             output [3:0]  blue,
             output        hsync,
             output        vsync,

	     output      [2:0] leds,
	     output reg [15:0] diag
             );

   // ===============================================================
   // Parameters
   // ===============================================================

   parameter CHARROM_INIT_FILE = "../mem/charrom.mem";
   parameter VID_RAM_INIT_FILE = "../mem/vid_ram.mem";

   // ===============================================================
   // Wires/Reg definitions
   // ===============================================================

   reg         hard_reset_n;
   reg [7:0]   pia_pa_r = 8'h00;
   reg         rnw;
   reg [15:0]  address;
   reg [7:0]   cpu_dout;
   reg [7:0]   vid_dout;
   reg         lock;

   wire        break_n;
   wire [7:0]  pia_pc;
   wire        pia_cs;
   wire        wemask;
   wire [7:0]  spi_dout;
   wire [7:0]  via_dout;
   wire        via_irq_n;
   wire [1:0]  turbo;

`ifdef ulx3s
   assign usb_fpga_pu_dp = 1;
   assign usb_fpga_pu_dn = 1;
`endif

   // ===============================================================
   // VGA Clock generation (25MHz/12.5MHz)
   // ===============================================================

   wire clk_vga = clk32;
   reg  clk_vga_en = 0;

`ifdef ulx3s
   wire flash_sck;
   wire tristate = 1'b0;

   USRMCLK u1 (.USRMCLKI(flash_sck), .USRMCLKTS(tristate));
`endif

   always @(posedge clk_vga)
     clk_vga_en <= !clk_vga_en;

   // ===============================================================
   // Clock Enable Generation
   // ===============================================================

   reg [5:0] clkdiv;
   reg sync, cpu_clken, via1_clken, via4_clken;
   reg sdram_access;
   reg clk32;

   always @(posedge clk64) begin
     clkdiv <= clkdiv + 1;
     cpu_clken <= (clkdiv == 0);
     sdram_access <= (clkdiv >= 8 && clkdiv < 16);
     sync <= (clkdiv[2:0] == 0);
     via1_clken <= (clkdiv == 0);
     via4_clken <= (clkdiv[1:0] == 0);
     clk32 <= clkdiv[0];
   end

   // ===============================================================
   // Reset generation
   // ===============================================================

   reg [15:0] pwr_up_reset_counter = 0; // hold reset low for ~1ms
   wire       pwr_up_reset_n = &pwr_up_reset_counter;

   always @(posedge clk64)
     begin
        if (cpu_clken)
          begin
             if (!pwr_up_reset_n)
               pwr_up_reset_counter <= pwr_up_reset_counter + 1;
             hard_reset_n <= pwr_up_reset_n;
          end
     end


   wire reset = !hard_reset_n | !break_n | !load_done;

   reg reload;
   reg btn_dly;

   always @ (posedge clk64) begin
     btn_dly <= button;
     reload <= button && !btn_dly;
   end

   // Pll for SDRAM clock
   wire clk64, locked;

`ifdef ulx3s
   pll pll_i (
     .clkin(clk25),
     .clkout0(clk64),
     .locked(locked)
   );
`else
   pll pll_i (
     .clock_in(clk25),
     .clock_out(clk64),
     .locked(locked)
   );
 `endif

   // Use SB_IO for tristate sd_data
   wire [15:0] sd_data_in;
   reg  [15:0] sd_data_out;
   reg         sd_data_dir;

`ifdef use_sb_io
   SB_IO #(
     .PIN_TYPE(6'b 1010_01),
     .PULLUP(1'b 0)
   ) ram [15:0] (
     .PACKAGE_PIN(sd_data),
     .OUTPUT_ENABLE(sd_data_dir),
     .D_OUT_0(sd_data_out),
     .D_IN_0(sd_data_in)
   );
`else 
   assign sd_data = sd_data_dir ? sd_data_out : 16'hzzzz;
   assign sd_data_in = sd_data; 
`endif

   assign sd_cke = 1;
   assign sd_clk = clk64;

   wire [15:0] sdram_address = load_done ? atom_RAMA[17:1] : (16'h6000 + load_addr[15:0]);
   wire        sdram_wren = load_done ? (sdram_access && !atom_RAMWE_b) : load_wren;
   wire [15:0] sdram_write_data = load_done ? {cpu_dout, cpu_dout} : load_write_data;
   wire [15:0] sdram_read_data;
   wire  [1:0] sdram_mask = load_done ? (2'b01 << atom_RAMA[0]) : 2'b11;

   // SDRAM
   sdram ram(
    .sd_data_in(sd_data_in),
    .sd_data_out(sd_data_out),
    .sd_data_dir(sd_data_dir),
    .sd_addr(sd_addr),
    .sd_dqm(sd_dqm),
    .sd_ba(sd_ba),
    .sd_cs(sd_cs),
    .sd_we(sd_we),
    .sd_ras(sd_ras),
    .sd_cas(sd_cas),
    .clk(clk64),
    .init(!locked || reload),
    .sync(sync),
    .ds(sdram_mask),
    .we(sdram_wren),
    .oe(load_done && sdram_access && !atom_RAMOE_b),
`ifdef ulx3s
    .addr({8'b0, sdram_address}),
`else
    .addr({4'b0, sdram_address}),
`endif
    .din(sdram_write_data),
    .dout(sdram_read_data)
   );

   reg         load_done;
   reg  [15:0] load_addr;
   reg  [1:0]  sdram_written = 0;
   wire [15:0] load_write_data;

   reg         flashmem_valid;
   wire        flashmem_ready;
   wire        load_wren =  sdram_written > 1;
   wire [23:0] flashmem_addr = 24'h70000 | {load_addr, 1'b0};
   reg         load_done_pre;
   reg [7:0]   wait_ctr;

   // Flash memory load interface
   always @(posedge clk64)
   begin
     diag <= sdram_read_data;
     if (!hard_reset_n) begin
       load_done_pre <= 1'b0;
       load_done <= 1'b0;
       load_addr <= 17'h00000;
       wait_ctr <= 8'h00;
       flashmem_valid <= 1;
     end else begin
     if (reload) begin
       load_done_pre <= 1'b0;
       load_done <= 1'b0;
       load_addr <= 17'h0000;
       wait_ctr <= 8'h00;
       flashmem_valid <= 1;
     end else if (!load_done) begin
       if (sdram_written > 0 && sdram_written < 3) begin
         if (sync) sdram_written <= sdram_written + 1;
         if (sdram_written == 2 && sync) begin
           if (load_addr == 17'h1fff) begin
             load_done_pre <= 1'b1;
           end else begin
             load_addr <= load_addr + 1'b1;
             flashmem_valid <= 1;
             sdram_written <= 0;
           end
         end
       end
       if(!load_done_pre) begin
         if (flashmem_ready == 1'b1) begin
           flashmem_valid <= 0;
           sdram_written <= 1;
           //if (load_addr == 16'h1ffe) diag <= load_write_data;
         end
       end else begin
         if (wait_ctr < 8'hFF)
           wait_ctr <= wait_ctr + 1;
         else
           load_done <= 1'b1;
         end
       end
     end
   end

   // ==============================================================
   // Flash memory
   // ==============================================================
   icosoc_flashmem flash_i (
     .clk(clk64),
     .reset(!hard_reset_n || reload),
     .valid(flashmem_valid && !load_done),
     .ready(flashmem_ready),
     .addr(flashmem_addr),
     .rdata(load_write_data),

     .spi_cs(flash_csn),
     .spi_sclk(flash_sck),
     .spi_mosi(flash_mosi),
     .spi_miso(flash_miso)
   );

   // ===============================================================
   // Keyboard
   // ===============================================================

   wire       rept_n;
   wire       shift_n;
   wire       ctrl_n;
   wire [3:0] row = pia_pa_r[3:0];
   wire [5:0] keyout;
   wire       ps2_clk_int;
   wire       ps2_data_int;

   keyboard KBD
     (
      .CLK(clk64),
      .nRESET(hard_reset_n),
      .PS2_CLK(ps2_clk_int),
      .PS2_DATA(ps2_data_int),
      .KEYOUT(keyout),
      .ROW(row),
      .SHIFT_OUT(shift_n),
      .CTRL_OUT(ctrl_n),
      .REPEAT_OUT(rept_n),
      .BREAK_OUT(break_n),
      .TURBO(turbo)
      );

`ifdef use_sb_io
    SB_IO #(
        .PIN_TYPE(6'b0000_01),
        .PULLUP(1'b1)
    ) ps2_io [1:0] (
        .PACKAGE_PIN({ps2_clk, ps2_data}),
        .D_IN_0({ps2_clk_int, ps2_data_int})
    );
`else
    assign ps2_clk_int = ps2_clk;
    assign ps2_data_int = ps2_data;
`endif

   // ===============================================================
   // LEDs
   // ===============================================================

   assign leds[0] = !load_done;
   assign leds[1] = !hard_reset_n;
   assign leds[2] = !reload;

   reg        led1;
   reg        led2;
   reg        led3;
   reg        led4;

   always @(posedge clk64)
     begin
        led1 <= pia_pc[3];  // blue    - indicates alt colour set active
        led2 <= !ss;        // green   - indicates SD card activity
        led3 <= lock;       // yellow  - indicates rept key pressed
        led4 <= reset;      // red     - indicates reset active
     end

   // ===============================================================
   // Cassette
   // ===============================================================

   // The Atom drives cas_tone from 4MHz / 16 / 13 / 8
   // 208 = 16 * 13, and start with 1MHz and toggle
   // so it's basically the same

   reg        cas_tone = 1'b0;
   reg [7:0]  cas_div = 0;

   always @(posedge clk64)
     if (cpu_clken)
       begin
          if (cas_div == 207)
            begin
               cas_div <= 0;
               cas_tone <= !cas_tone;
            end
          else
            cas_div <= cas_div + 1;
       end

   assign sound = pia_pc[2] & sid_audio;

   // this is a direct translation of the logic in the atom
   // (two NAND gates and an inverter)
   assign cas_out = !(!(!cas_tone & pia_pc[1]) & pia_pc[0]);

   // ===============================================================
   // ROM Latch at BFFF
   // ===============================================================

   reg [7:0]   rom_latch;
   wire        rom_latch_cs;
   wire        a000_cs;

   always @(posedge clk64 or posedge reset)
     if (reset)
       rom_latch <= 8'h00;
     else if (cpu_clken)
       if (rom_latch_cs & !rnw)
         rom_latch <= cpu_dout;

   // ===============================================================
   // RAM atrributes
   // ===============================================================

   wire        atom_RAMOE_b = !rnw;
   wire        atom_RAMWE_b = rnw  | wemask;
   wire [17:0] atom_RAMA    = a000_cs ? { 3'b010, rom_latch[2:0], address[11:0] } :
                                        { 2'b00, address };

   // ===============================================================
   // SID
   // ===============================================================

   wire [7:0] sid_dout;
   wire       sid_audio;
   wire       sid_cs;

   sid6581 sid
     (
      .clk_1MHz(!clkdiv[5]),
      .clk32(clk25), // TODO: should be clk32
      .clk_DAC(clk64),
      .reset(reset),
      .cs(cpu_clken),
      .we(sid_cs & !rnw),

      .addr(address[4:0]),
      .di(cpu_dout),
      .dout(sid_dout),

      .pot_x(1'b0),
      .pot_y(1'b0),
      .audio_out(sid_audio),
      .audio_data()
   );

   // ===============================================================
   // 8255 PIA at 0xB0xx
   // ===============================================================

   // This model is still very crude, specifically the directions of
   // the ports are fixed (not normally a problem on the Atom)

   wire       fs_n;
   reg [7:0]  pia_dout;
   reg [3:0]  pia_pc_r = 4'h0;
   wire [7:0] pia_pa   = { pia_pa_r };
   wire [7:0] pia_pb   = { shift_n, ctrl_n, keyout };
   assign     pia_pc   = { fs_n, rept_n, cas_in, cas_tone, pia_pc_r};

   always @(posedge clk64 or posedge reset)
     begin
        if (reset)
          begin
             pia_pa_r <= 8'h00;
             pia_pc_r <=  4'h0;
          end
        else if (cpu_clken)
          begin
             if (pia_cs && !rnw)
               case (address[1:0])
                 2'b00: pia_pa_r <= cpu_dout;
                 2'b10: pia_pc_r <= cpu_dout[3:0];
                 2'b11: if (!cpu_dout[7]) pia_pc_r[cpu_dout[2:1]] <= cpu_dout[0];
               endcase
          end
     end

   always @(*)
     begin
        case(address[1:0])
          2'b00: pia_dout <= pia_pa;
          2'b01: pia_dout <= pia_pb;
          2'b10: pia_dout <= pia_pc;
          default:
            pia_dout <= 0;
        endcase
     end


   // ===============================================================
   // 6502 CPU
   // ===============================================================

   wire  [7:0] cpu_din;
   wire [7:0]  cpu_dout_c;
   wire [15:0] address_c;
   wire        rnw_c;

   // Arlet's 6502 core is one of the smallest available
   cpu CPU
     (
      .clk(clk64),
      .reset(reset),
      .AB(address_c),
      .DI(cpu_din),
      .DO(cpu_dout_c),
      .WE(rnw_c),
      .IRQ(!via_irq_n),
      .NMI(1'b0),
      .RDY(cpu_clken)
      );

   // The outputs of Arlets's 6502 core need registing
   always @(posedge clk64)
     begin
        if (cpu_clken)
          begin
             address  <= address_c;
             cpu_dout <= cpu_dout_c;
             rnw      <= !rnw_c;
          end
     end

   // Snoop bit 5 of #E7 (the lock flag)
   always @(posedge clk64 or posedge reset)
     if (reset)
       lock <= 1'b0;
     else if (cpu_clken)
       if ((address == 16'he7) && !rnw)
         lock <= cpu_dout[5];

   // ===============================================================
   // Address decoding logic and data in multiplexor
   // ===============================================================

   // 0000-7FFF RAM
   // 8000-97FF Video RAM
   // 9800-9FFF RAM
   // A000-AFFF RAM
   // B000-B00F 8255 PIA
   // B010-B3FF BRAN ROM (part 1)
   // B400-B40F empty (returns zero)
   // B410-B7FF BRAN ROM (part 2)
   // B800-B80F 6522 VIA
   // B810-BBFF RAM
   // BC00-BC0F SPI
   // BC10-BCFF RAM
   // C000-CFFF Basic ROM
   // D000-DFFF FP ROM
   // E000-EFFF SDDOS ROM
   // F000-FFFF MOS ROM

   wire [7:0]  pl8_dout = 8'b0;

   wire         rom_cs = (address[15:14] == 2'b11 | (address[15:12] == 4'b1010 & rom_latch[2:0] != 3'b111));

   assign       pia_cs = (address[15: 4] == 12'hb00);
   wire         pl8_cs = (address[15: 4] == 12'hb40);
   wire         via_cs = (address[15: 4] == 12'hb80);
   wire         spi_cs = (address[15: 4] == 12'hbc0);
   assign       sid_cs = (address[15: 8] ==  8'hbd);
   assign      a000_cs = (address[15:12] == 4'b1010);
   wire         vid_cs = (address[15:12] == 4'b1000) | (address[15:11] == 5'b10010);
   assign rom_latch_cs = (address        == 16'hbfff);

   assign      wemask = rom_cs;

   assign cpu_din = vid_cs   ? vid_dout  :
                    pia_cs   ? pia_dout  :
                    pl8_cs   ? pl8_dout  :
                    spi_cs   ? spi_dout  :
                    via_cs   ? via_dout  :
                    sid_cs   ? sid_dout  :
              rom_latch_cs   ? rom_latch :
                               (address[0] ? sdram_read_data[15:8] : sdram_read_data[7:0]);

   // ===============================================================
   // 6522 VIA at 0xB8xx
   // ===============================================================

   m6522 VIA
     (
      .I_RS(address[3:0]),
      .I_DATA(cpu_dout),
      .O_DATA(via_dout),
      .O_DATA_OE_L(),
      .I_RW_L(rnw),
      .I_CS1(via_cs),
      .I_CS2_L(1'b0),
      .O_IRQ_L(via_irq_n),
      .I_CA1(1'b0),
      .I_CA2(1'b0),
      .O_CA2(),
      .O_CA2_OE_L(),
      .I_PA(8'b0),
      .O_PA(),
      .O_PA_OE_L(),
      .I_CB1(1'b0),
      .O_CB1(),
      .O_CB1_OE_L(),
      .I_CB2(1'b0),
      .O_CB2(),
      .O_CB2_OE_L(),
      .I_PB(8'b0),
      .O_PB(),
      .O_PB_OE_L(),
      .I_P2_H(via1_clken),
      .RESET_L(!reset),
      .ENA_4(via4_clken),
      .CLK(clk64)
      );

   // ===============================================================
   // SD Card Interface
   // ===============================================================

   spi SPI
     (
      .clk(clk64),
      .reset(reset),
      .enable(spi_cs & cpu_clken),
      .rnw(rnw),
      .addr(address[2:0]),
      .din(cpu_dout),
      .dout(spi_dout),
      .miso(miso),
      .mosi(mosi),
      .ss(ss),
      .sclk(sclk)
   );

   // ===============================================================
   // Dual Port Video RAM
   // ===============================================================

   // Port A to CPU
   wire        we_a = vid_cs & !rnw;
   reg [1:0]   rd_state;

   // Port B to VDG
   wire [12:0] vid_addr;
   reg  [7:0]  vid_data;
   wire [7:0]  ram_data;
   
   vid_ram
     #(.MEM_INIT_FILE (VID_RAM_INIT_FILE))
   VID_RAM
     (
      // Port A
      .clk_a(clk64),
      .we_a(we_a),
      .addr_a(address[12:0]),
      .din_a(cpu_dout),
`ifdef ulx3s
      .dout_a(vid_dout),
`endif	      
      // Port B
      .clk_b(clk_vga),
`ifdef ulx3s
      .addr_b(vid_addr[12:0]),
`else
      .addr_b(rd_state == 2'b10 ? address[12:0] : vid_addr[12:0]),
`endif
`ifdef ulx3s
      .dout_b(vid_data)
`else
      .dout_b(ram_data)
`endif
      );

   // The follow state machine works a bit like the Atom Noise Killer
   // allowing a single video ram read port to be shared between the
   // VDG and the CPU without any conflicts.
   //
   // The CPU is given priority.
   //
   // There are two holding registers for video RAM read data:
   //    vid_data holds data from VDG read cycles
   //    vid_dout holds data from CPU read cycles
   //
   // This sharing works because there is plenty of memory bandwidth
   // and neither the VGD or the CPU require the read to happen
   // immediately.

`ifdef ulx3s
`else
   always @(posedge clk32, posedge reset)
     begin
        if (reset)
          rd_state <= 2'b00;
        else
          case (rd_state)
            2'b00:
              begin
                 if (cpu_clken)
                   rd_state <= 2'b01;
                 vid_data <= ram_data; // for the VDG
              end
            2'b01:
              begin
                 if (vid_cs & rnw)
                   rd_state <= 2'b10;
                 else
                   rd_state <= 2'b00;
                 vid_data <= ram_data; // for the VDG
              end
            2'b10:
              begin
                 rd_state <= 2'b11;
                 vid_data <= ram_data; // for the VDG
              end
            2'b11:
              begin
                 vid_dout <= ram_data; // for the CPU
                 rd_state <= 2'b00;
              end
            default:
              rd_state <= 2'b00;
          endcase
     end
`endif

   // ===============================================================
   // 6847 VDG
   // ===============================================================

   wire        an_g     = pia_pa[4];
   wire [2:0]  gm       = pia_pa[7:5];
   wire        css      = pia_pc[3];
   wire        inv      = vid_data[7]; // See Atom schematic
   wire        intn_ext = vid_data[6]; // See Atom schematic
   wire        an_s     = vid_data[6]; // See Atom schematic
   wire [10:0] char_a;
   wire [7:0]  char_d;
   wire [8:0]  packed_char_a;
   wire [7:0]  packed_char_d;

   mc6847 VDG
     (
      .clk(clk_vga),
      .clk_ena(clk_vga_en),
      .reset(!hard_reset_n),
      .da0(),
      .videoaddr(vid_addr),
      .dd(vid_data),
      .hs_n(),
      .fs_n(fs_n),
      .an_g(an_g),
      .an_s(an_s),
      .intn_ext(intn_ext),
      .gm(gm),
      .css(css),
      .inv(inv),
      .red(red),
      .green(green),
      .blue(blue),
      .hsync(hsync),
      .vsync(vsync),
      .hblank(),
      .vblank(),
      .artifact_en(1'b0),
      .artifact_set(1'b0),
      .artifact_phase(1'b1),
      .cvbs(),
      .black_backgnd(1'b1),
      .char_a(char_a),
      .char_d_o(char_d)
      );

   charrom
     #(.MEM_INIT_FILE (CHARROM_INIT_FILE))
   CHARROM
     (
      .clk(clk_vga),
      .address(packed_char_a),
      .dout(packed_char_d)
      );

   assign packed_char_a[8:3] = char_a[9:4];
   assign packed_char_a[2:0] = char_a[3:0] - 2'b11;
   assign char_d = (char_a[3:0] < 3 || char_a[3:0] > 10) ? 8'h00 : packed_char_d;

endmodule
