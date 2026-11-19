// SPDX-License-Identifier: GPL-3.0-or-later
// Exact v1.0.1 paired-frame delivery. Local tile raster can be selected for
// BIOS/pin diagnostics; product frames use acknowledged host publication.
module nds_hs_scanout (
    input wire clk,guest_clk,media_reset,guest_reset,session_reset, external_mode,external_enable,
    input wire [27:0] raster,input wire publish,input wire [1:0] bank,output wire adopted,quiescent,
    output wire [27:1] fb5_addr,fb6_addr,output wire [63:0] fb5_din,output wire fb5_req,fb6_req,
    input wire fb5_next,fb5_ready,fb6_ready,fb6_valid,input wire [63:0] fb6_dout,
    input wire [1:0] layout_select,gap_select,input wire screen_order_select,fps_select,crt_select,split_select,analog_screen_select,
    output wire [1:0] layout_active,gap_active,output wire screen_order_active,fps_active,crt_active,split_active,analog_screen_active,
    input wire touch_pressed,input wire [7:0] touch_x,touch_y,
    output wire ce_pixel,de,hsync,vsync,output wire [7:0] red,green,blue,
    output wire analog_ce,analog_de,analog_hs,analog_vs,output wire [7:0] analog_r,analog_g,analog_b,
    output wire fault
);
    // Core raster is physical top/then touch. Explicit x/y are recovered
    // only from real active pixels; VS resets the frame even on a GPU fault.
    reg [8:0] x=0; reg [7:0] y=0;
    wire pixel=raster[27] && raster[26];
    always @(posedge guest_clk) begin
        if (guest_reset || (raster[27] && raster[24])) begin x<=0; y<=0; end
        else if(pixel) begin x<=x+1'b1; if(&x) y<=y+1'b1; end
    end
    wire [17:0] bgr={raster[7:2],raster[15:10],raster[23:18]};
    wire [34:0] q; wire have,empty,overflow;
    nds_nitro_async_fifo #(.WIDTH(35),.LGDEPTH(4)) pixels (.write_clk(guest_clk),.write_reset(guest_reset),
        .write_enable(pixel && !external_mode),.write_data({x[8],bgr,y,x[7:0]}),.write_full(),.write_overflow(overflow),
        .read_clk(clk),.read_reset(session_reset),.read_enable(!empty),.read_data(q),.read_valid(have),.read_empty(empty));
    (* async_reg="true" *) reg [1:0] overflow_sync=0;
    always @(posedge clk) overflow_sync<={overflow_sync[0],overflow};
    wire pf_tgl,pf_scr,pf_bank,pf_external,pf_ticket,pf_slot,split_frame_toggle,fb_quiet,scan_quiet,toggle;
    wire [7:0] pf_line;wire [1:0] pf_frame_bank,pub_bank;wire [3:0] pf_completed,lb_acquire,lb_hold,lb_selected_slot;
    wire [8:0] lb_raddr;wire [35:0] lb_q;wire lb_valid;wire [9:0] fb_fault;
    reg descriptor_toggle=0;
    always @(posedge clk) if(session_reset) descriptor_toggle<=0; else if(adopted) descriptor_toggle<=~descriptor_toggle;
    assign fault=overflow_sync[1] || |fb_fault;
    assign quiescent=fb_quiet && scan_quiet;
    nds_nitro_fb_ddr3 framebuffer (.clk_sys(clk),.CLK_VIDEO(clk),.reset_sys(session_reset),.reset_video(media_reset),.reset_read(media_reset),
        .external_enable,.external_quiescent(fb_quiet),.external_frame_mode(external_mode),.external_frame_publish(publish),.external_frame_bank(bank),.external_frame_adopted(adopted),
        .pix_x(q[7:0]),.pix_y(q[15:8]),.pix_d(q[33:16]),.pix_we(have && !q[34]),.pixb_x(q[7:0]),.pixb_y(q[15:8]),.pixb_d(q[33:16]),.pixb_we(have && q[34]),
        .source_fault(overflow_sync[1]),.telemetry_session(32'b0),.dbg0(18'b0),.dbg1(18'b0),.dbg2(18'b0),.dbg3(18'b0),.dbg4(18'b0),.dbg5(18'b0),.dbg6(18'b0),.dbg7(18'b0),.dbg8(18'b0),.dbg9(18'b0),.dbg10(18'b0),.dbg11(18'b0),
        .pf_tgl,.pf_scr,.pf_line,.pf_bank,.pf_frame_bank,.pf_external,.split_mode(split_active),.pf_slot,.pf_ticket,.split_frame_toggle,.pf_completed,.lb_acquire,.lb_hold,.lb_selected_slot,
        .published_frame_toggle(toggle),.published_frame_bank(pub_bank),.scanout_late_count(),.runtime_fault_flags(fb_fault),.bank_diagnostic(),
        .lb_raddr,.lb_q,.lb_valid,.fb5_addr,.fb6_addr,.fb5_req,.fb6_req,.fb5_din,.fb5_next,.fb5_ready,.fb6_ready,.fb6_valid,.fb6_dout);
    nds_nitro_video_scanout scanout (.clk_video(clk),.reset(media_reset),.session_reset,.layout_select,.screen_order_select,.gap_select,.fps_select,.crt_select,.split_select,.analog_screen_select,
        .crt_active,.split_active,.analog_screen_active,.layout_active,.screen_order_active,.gap_active,.fps_active,.touch_pressed,.touch_x,.touch_y,
        .pf_tgl,.pf_scr,.pf_line,.pf_bank,.pf_frame_bank,.pf_external,.pf_slot,.pf_ticket,.split_frame_toggle,.pf_completed,.lb_acquire,.lb_hold,.lb_selected_slot,
        .published_frame_toggle(toggle),.published_frame_bank(pub_bank),.external_screen_toggle(1'b0),.external_screen_bank(2'b0),.external_screen_select(1'b0),.external_screen_adopted_toggle(),
        .external_enable,.external_quiescent(scan_quiet),.effective_3d_frame_toggle(descriptor_toggle),.lb_raddr,.lb_q,.lb_valid,.ce_pixel,.de,.hsync,.vsync,.red,.green,.blue,.analog_ce,.analog_de,.analog_hs,.analog_vs,.analog_r,.analog_g,.analog_b);
endmodule
