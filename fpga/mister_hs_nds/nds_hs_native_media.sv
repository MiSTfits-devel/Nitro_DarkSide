// SPDX-License-Identifier: GPL-3.0-or-later
// Host ABI is the v1.0.1 FIO/EXT/slot-1 implementation, not a ROM embedded
// at synthesis. Lifecycle/persistence survives guest Reset. Direct boot
// images (FIO7/op3) cannot release either CPU in this native-only core.
module nds_hs_native_media #(parameter bit SIMULATE = 0) (
    input wire host_clk, guest_clk, media_reset, cart_download,
    input wire firmware_io_enable, firmware_io_strobe,
    input wire [15:0] firmware_io_din,
    output wire firmware_io_override, output wire [15:0] firmware_io_dout,
    input wire ioctl_download, ioctl_wr, input wire [15:0] ioctl_index, ioctl_dout,
    input wire [26:0] ioctl_addr, output wire ioctl_wait,
    input wire img_mounted, img_readonly, input wire [63:0] img_size,
    output wire [31:0] sd_lba, output wire sd_rd, sd_wr,
    input wire sd_ack, input wire [12:0] sd_buff_addr,
    input wire [15:0] sd_buff_dout, input wire sd_buff_wr, output wire [15:0] sd_buff_din,
    input wire [31:0] boot9_addr, boot7_addr, output wire [31:0] boot9_word, boot7_word,
    input wire [15:0] fw_addr, input wire fw_req, fw_wr, fw_release,
    input wire [1:0] fw_wlane, input wire [7:0] fw_wdata,
    output wire fw_done, fw_busy, output wire [31:0] fw_data,
    input wire [55:0] rtc_datetime, input wire rtc_date_written,
    output wire [39:0] cal_x, cal_y,
    output wire native_ready_host, media_fault, save_profile_ready,
    output wire [31:0] save_code, output wire [3:0] save_type
);
    wire hold_console, native_mode, bios7_ready, bios9_ready, profile_ready, direct_ready;
    wire lifecycle_sel, rtc_sel, mounted, clean, cache_fault, persist_pending;
    wire [15:0] lifecycle_reply, rtc_reply, persist_sequence, commit_sequence;
    wire flush_req, commit_ack;
    wire [11:0] a7; wire [9:0] a9; wire [31:0] d7,d9; wire [3:0] be7,be9; wire we7,we9;
    nds_firmware_control #(.SIMULATE(SIMULATE), .CART_464(1), .HOST_SAVE_PROFILE(1)) control (
        .clk(host_clk), .clk7(guest_clk), .clk9(guest_clk), .reset(media_reset),
        .io_enable(firmware_io_enable), .io_strobe(firmware_io_strobe), .io_din(firmware_io_din),
        // FIO7 is the donor direct-boot profile; this core has no direct boot
        // sequencer. Do not acknowledge its readiness or allow op3 success.
        .io_override(lifecycle_sel), .io_dout(lifecycle_reply), .ioctl_download(ioctl_download && ioctl_index!=7),.ioctl_wr,.ioctl_index,.ioctl_dout,.ioctl_addr,.ioctl_wait,
        .cart_download,.cart_profile_ready(save_profile_ready),.cart_profile_code(save_code),.cart_profile_type(save_type),
        .mounted,.clean,.cache_fault,.persist_pending,.persist_sequence,.hold_console,.native_mode,
        .bios7_ready,.bios9_ready,.profile_ready,.direct_profile_ready(direct_ready),.fault(media_fault),
        .flush_req,.commit_ack,.commit_sequence,
        .bios7_addr(a7),.bios7_data(d7),.bios7_be(be7),.bios7_we(we7),
        .bios9_addr(a9),.bios9_data(d9),.bios9_be(be9),.bios9_we(we9),
        .builtin_addr(),.builtin_data(),.builtin_be(),.builtin_we(),.profile_addr(5'b0),.profile_data(),
        .profile_fw_offset(),.profile_fw_checksums());
    nds_hs_bios_ram #(.WORD_BITS(12)) arm7_bios (.clk(guest_clk),.read_addr(boot7_addr[13:2]),.read_data(boot7_word),.load_addr(a7),.load_data(d7),.load_be(be7),.load_we(we7));
    nds_hs_bios_ram #(.WORD_BITS(10)) arm9_bios (.clk(guest_clk),.read_addr(boot9_addr[11:2]),.read_data(boot9_word),.load_addr(a9),.load_data(d9),.load_be(be9),.load_we(we9));
    nds_firmware_cache #(.SIMULATE(SIMULATE)) flash (.clk(host_clk),.guest_clk,.reset(media_reset),.enable(mounted),
        .img_mounted,.img_readonly,.img_size,.fw_addr,.fw_req,.fw_wr,.fw_wlane,.fw_wdata,.fw_release,.fw_done,.fw_busy,.fw_data,
        .flush_req,.commit_ack,.commit_sequence,.mounted,.clean,.persist_pending,.persist_sequence,.fault(cache_fault),
        .sd_lba,.sd_rd,.sd_wr,.sd_ack,.sd_buff_addr,.sd_buff_dout,.sd_buff_wr,.sd_buff_din);
    nds_rtc_host_bridge rtc (.clk(host_clk),.rtc_clk(guest_clk),.rtc_datetime,.rtc_date_written,
        .io_enable(firmware_io_enable),.io_strobe(firmware_io_strobe),.io_din(firmware_io_din),.io_override(rtc_sel),.io_dout(rtc_reply));
    assign firmware_io_override = rtc_sel | lifecycle_sel;
    assign firmware_io_dout = rtc_sel ? rtc_reply : lifecycle_reply;
    assign native_ready_host = native_mode && !hold_console && !media_fault && bios7_ready && bios9_ready && profile_ready && !direct_ready && mounted;
    // Immutable until the next held upload. The lifecycle checks the whole
    // sequential 120-byte profile before release. The guest reset synchronizer
    // provides the settling interval for this bundled-data crossing.
    reg [11:0] ax1,ax2,ay1,ay2; reg [7:0] px1,px2,py1,py2;
    always @(posedge host_clk) if (hold_console && ioctl_download && ioctl_index==16'd6 && ioctl_wr) case (ioctl_addr)
        27'h60: ax1 <= ioctl_dout[11:0]; 27'h62: ay1 <= ioctl_dout[11:0];
        27'h64: {py1,px1} <= ioctl_dout; 27'h66: ax2 <= ioctl_dout[11:0];
        27'h68: ay2 <= ioctl_dout[11:0]; 27'h6a: {py2,px2} <= ioctl_dout;
    endcase
    assign cal_x = {ax1,ax2,px1,px2}; assign cal_y = {ay1,ay2,py1,py2};
endmodule
