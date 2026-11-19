// SPDX-License-Identifier: GPL-3.0-or-later
// CPU + VRAM display prototype: the Clash ARM9 slice runs the staged boot
// ROM and draws through its GPU link into Clash VRAM; display mode 2 is
// scanned out 2x at 640x480. Not an NDS core.
module emu (
    `include "sys/emu_ports.vh"
);
    localparam CONF_STR = {
        "Haskell CPU+VRAM display prototype;;",
        "T[0],Restart program;",
        "V,1.0"
    };

    // MiSTer's native-video clock switches require a PLL output even at 50 MHz.
    wire clk_sys, locked;
    gfx_pll pll (.refclk(CLK_50M), .clk(clk_sys), .locked(locked));

    wire [127:0] status;
    wire [1:0] buttons;
    wire [35:0] ext_bus;
    assign ext_bus[32] = 1'b0;
    assign ext_bus[15:0] = 16'd0;

    hps_io #(.CONF_STR(CONF_STR)) hps_io (
        .clk_sys(clk_sys), .HPS_BUS(HPS_BUS), .EXT_BUS(ext_bus),
        .buttons(buttons), .status(status),
        .status_in(128'd0), .status_set(1'b0), .status_menumask(16'd0),
        .info(8'd0), .info_req(1'b0), .video_rotated(1'b0), .new_vmode(1'b0),
        .sd_lba('{32'd0}), .sd_blk_cnt('{6'd0}), .sd_rd(1'b0), .sd_wr(1'b0),
        .sd_buff_din('{8'd0}), .ioctl_wait(1'b0), .ioctl_upload_req(1'b0),
        .ioctl_upload_index(8'd0), .ioctl_din(8'd0),
        .joystick_0_rumble(16'd0), .joystick_1_rumble(16'd0),
        .joystick_2_rumble(16'd0), .joystick_3_rumble(16'd0),
        .joystick_4_rumble(16'd0), .joystick_5_rumble(16'd0)
    );

    // The fabric reset can assert at any phase. Release on the core clock.
    wire reset_async = RESET | ~locked;
    (* async_reg = "true" *) reg [1:0] reset_sync = 2'b11;
    always @(posedge clk_sys or posedge reset_async) begin
        if (reset_async) reset_sync <= 2'b11;
        else       reset_sync <= {reset_sync[0], 1'b0};
    end

    // 4 KiB boot window at 0xFFFF0000; the staged image is padded to 1024 words.
    reg [31:0] boot_rom [0:1023];
    initial $readmemh("hs_gfx_arm9.hex", boot_rom);
    wire [31:0] boot_addr;
    wire [31:0] boot_word = boot_addr[31:12] == 20'hffff0 ? boot_rom[boot_addr[11:2]] : 32'd0;

    nds_gfx_soc soc (
        .CLK(clk_sys), .RST(reset_sync[1] | status[0] | buttons[1]),
        .BOOT_WORD(boot_word), .BOOT_ADDR(boot_addr),
        .VIDEO({CE_PIXEL, VGA_DE, VGA_HS, VGA_VS, VGA_R, VGA_G, VGA_B})
    );
    assign CLK_VIDEO = clk_sys;
    assign VIDEO_ARX = 13'd4;
    assign VIDEO_ARY = 13'd3;
    assign {VGA_F1, VGA_SL, VGA_SCALER, VGA_DISABLE} = '0;
    assign {HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT} = '0;
    assign {NDS_F2H_IRQ, NDS_SPLIT_ACTIVE, NDS_ANALOG_R, NDS_ANALOG_G, NDS_ANALOG_B,
            NDS_ANALOG_HS, NDS_ANALOG_VS, NDS_ANALOG_DE, NDS_ANALOG_CE} = '0;
    assign {AUDIO_L, AUDIO_R, AUDIO_S, AUDIO_MIX, LED_USER, LED_DISK, LED_POWER, BUTTONS} = '0;
    assign {UART_RTS, UART_TXD, UART_DTR} = '0;
    assign USER_OUT = '1;
    assign ADC_BUS = 'z;
    assign {SD_SCK, SD_MOSI, SD_CS} = 'z;
    assign DDRAM_CLK = clk_sys;
    assign {DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_RD, DDRAM_DIN, DDRAM_BE, DDRAM_WE} = '0;
    assign {SDRAM_CLK, SDRAM_CKE, SDRAM_A, SDRAM_BA, SDRAM_DQ, SDRAM_DQML,
            SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE} = 'z;
endmodule

// Keep the standard MiSTer pll|pll_inst|altera_pll_i SDC hierarchy.
module gfx_pll (input refclk, output clk, output locked);
    gfx_pll_clock pll_inst (.refclk, .clk, .locked);
endmodule

module gfx_pll_clock (input refclk, output clk, output locked);
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"), .operation_mode("direct"),
        .number_of_clocks(1), .output_clock_frequency0("50.0 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50),
        .pll_type("General"), .pll_subtype("General")
    ) altera_pll_i (
        .refclk(refclk), .rst(1'b0), .fbclk(1'b0), .fboutclk(),
        .outclk(clk), .locked(locked)
    );
endmodule
