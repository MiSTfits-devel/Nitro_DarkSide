// Licensed under the repo LICENSE (see the LICENSE file at the repo root).
//
// Electrical/protocol boundary for the Clash HPS I/O replacement. The legacy
// framework hps_io (GPL) is replaced by the source-owned nds_hps_io decoder,
// which implements the exact subset of the uio/fp command set this core uses.
// The module port list is unchanged, so NDS.sv did not need to move.
module nds_hps_io_boundary #(
    parameter CONF_STR = "",
    parameter WIDE = 1,
    parameter VDNUM = 1,
    parameter BLKSZ = 2
) (
    input  wire             clk_sys,
    inout  wire [48:0]      HPS_BUS,
    output wire [1:0]       buttons,
    output wire             forced_scandoubler,
    output wire [15:0]      joystick_0,
    output wire [63:0]      status,
    output wire [26:0]      ioctl_addr,
    output wire [15:0]      ioctl_dout,
    output wire             ioctl_wr,
    output wire             ioctl_download,
    output wire [15:0]      ioctl_index,
    input  wire             ioctl_wait,
    input  wire [31:0]      sd_lba[VDNUM],
    input  wire [VDNUM-1:0] sd_rd,
    input  wire [VDNUM-1:0] sd_wr,
    output wire [VDNUM-1:0] sd_ack,
    output wire [7:0]       sd_buff_addr,
    output wire [15:0]      sd_buff_dout,
    input  wire [15:0]      sd_buff_din[VDNUM],
    output wire             sd_buff_wr,
    output wire [VDNUM-1:0] img_mounted,
    output wire             img_readonly,
    output wire [63:0]      img_size,
    inout  wire [21:0]      gamma_bus,
    output wire [15:0]      joystick_l_analog_0
);
    wire [31:0] n_joystick_0;
    wire [127:0] n_status;
    wire [VDNUM-1:0] n_sd_ack;
    wire [12:0] n_sd_buff_addr;
    wire [15:0] n_sd_buff_dout;
    wire        n_sd_buff_wr;
    wire [VDNUM-1:0] n_img_mounted;
    wire        n_img_readonly;
    wire [63:0] n_img_size;
    wire [5:0]  n_sd_blk_cnt[VDNUM];
    genvar gi;
    generate
        for (gi = 0; gi < VDNUM; gi = gi + 1) begin : tie_blk
            assign n_sd_blk_cnt[gi] = 6'd0;
        end
    endgenerate

    nds_hps_io #(.CONF_STR(CONF_STR), .WIDE(WIDE), .VDNUM(VDNUM), .BLKSZ(BLKSZ)) hpsio (
        .clk_sys(clk_sys),
        .HPS_BUS(HPS_BUS),
        .joystick_0(n_joystick_0),
        .joystick_l_analog_0(joystick_l_analog_0),
        .buttons(buttons),
        .forced_scandoubler(forced_scandoubler),
        .gamma_bus(gamma_bus),
        .status(n_status),
        .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),
        .ioctl_wr(ioctl_wr),
        .ioctl_download(ioctl_download),
        .ioctl_index(ioctl_index),
        .ioctl_wait(ioctl_wait),
        .sd_lba(sd_lba),
        .sd_blk_cnt(n_sd_blk_cnt),
        .sd_rd(sd_rd),
        .sd_wr(sd_wr),
        .sd_ack(n_sd_ack),
        .sd_buff_addr(n_sd_buff_addr),
        .sd_buff_dout(n_sd_buff_dout),
        .sd_buff_din(sd_buff_din),
        .sd_buff_wr(n_sd_buff_wr),
        .img_mounted(n_img_mounted),
        .img_readonly(n_img_readonly),
        .img_size(n_img_size)
    );

    assign joystick_0 = n_joystick_0[15:0];
    assign status = n_status[63:0];
    assign sd_ack = n_sd_ack;
    assign sd_buff_addr = n_sd_buff_addr[7:0];
    assign sd_buff_dout = n_sd_buff_dout;
    assign sd_buff_wr = n_sd_buff_wr;
    assign img_mounted = n_img_mounted;
    assign img_readonly = n_img_readonly;
    assign img_size = n_img_size;
endmodule
