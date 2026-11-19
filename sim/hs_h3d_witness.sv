// SPDX-License-Identifier: GPL-3.0-or-later
module hs_h3d_witness(input wire clk,source_clk,reset,input wire [31:0] boot,requested_session,
    output wire [31:0] boot_addr, mailbox_addr, mailbox_data, fault_bits,
    output wire [2:0] cpu_fault,output wire store, console_release,
    output wire write9,write7,query9,hblank,frame_end,published,output wire [1:0] bank,
    output wire adopted,screen_mode,pixel,output wire [23:0] rgb,
    output wire rd,wr,output wire [7:0] burst,be,output wire [28:0] addr,output wire [63:0] data,
    input wire busy,rv,input wire [63:0] q);
    wire space, vblank, result_valid, take;
    wire [31:0] active_session;
    // Hold the public guest in reset during pre-media helper attachment.
    wire guest_reset=reset || !console_release || active_session!=2 || requested_session!=2;
    wire [31:0] status,result,addr9,data9; wire [2:0] width9; wire [8:0] line;
    wire [31:0] addr7,data7,query_addr; wire [2:0] width7;
`ifdef H3D_NATIVE_BOARD
    hs_h3d_native_guest native (.clk(source_clk),.reset(guest_reset),.space,.boot,
        .status,.result,.result_valid,.boot_addr,.addr9,.data9,.addr7,.data7,.query_addr,
        .mailbox_addr,.mailbox_data,.width9,.width7,.cpu_fault,.write9,.write7,.query9,.take,.hblank,.frame_end,.vblank,.store,.line);
`else
    assign write7=0; assign addr7=0; assign data7=0; assign width7=0; assign query_addr=addr9;
    nds_h3d_guest cpu (.CLK(source_clk),.RST(guest_reset),.SPACE(space),.BOOT(boot),
        .STATUS(status),.RESULT_VALID(result_valid),.RESULT(result),.BOOT_ADDR(boot_addr),
        .WRITE9(write9),.ADDR9(addr9),.WIDTH9(width9),.DATA9(data9),.QUERY9(query9),.TAKE9(take),
        .HBLANK(hblank),.LINE(line),.FRAME_END(frame_end),.VBLANK(vblank),.FAULT(cpu_fault),
        .STORE(store),.STORE_ADDR(mailbox_addr),.STORE_DATA(mailbox_data));
`endif
    wire legacy_scanout_pending,legacy_read,legacy_write,legacy_busy,legacy_read_data_ready,quiet;
    wire [7:0] legacy_burst_count,legacy_byte_enable; wire [28:0] legacy_address;
    wire [63:0] legacy_write_data,legacy_read_data;
`ifdef H3D_SCANOUT
    assign screen_mode=1;
    wire [27:1] fb5_addr,fb6_addr; wire [63:0] fb5_din,fb6_dout;
    wire fb5_req,fb6_req,fb5_next,fb5_ready,fb6_ready,fb6_valid,ce,de;
    assign pixel=ce && de;
    nds_hs_scanout screen (.clk,.guest_clk(source_clk),.media_reset(reset),.guest_reset,
        .session_reset(guest_reset),.external_mode(1'b1),.external_enable(console_release),.raster(28'b0),
        .publish(published),.bank,.adopted,.quiescent(quiet),.fb5_addr,.fb6_addr,.fb5_din,.fb5_req,.fb6_req,
        .fb5_next,.fb5_ready,.fb6_ready,.fb6_valid,.fb6_dout,.layout_select(2'b0),.gap_select(2'b0),
        .screen_order_select(1'b0),.fps_select(1'b0),.crt_select(1'b0),.split_select(1'b0),.analog_screen_select(1'b0),
        .touch_pressed(1'b0),.touch_x(8'b0),.touch_y(8'b0),.ce_pixel(ce),.de,.red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));
    nds_hs_media_ddr media (.clk,.hard_reset(reset),.rom_valid(1'b0),.rom_addr(32'b0),.fb5_addr,.fb6_addr,.fb5_din,.fb5_req,.fb6_req,
        .fb5_next,.fb5_ready,.fb6_ready,.fb6_valid,.fb6_dout,.scanout_pending(legacy_scanout_pending),
        .read_cmd(legacy_read),.write_cmd(legacy_write),.address(legacy_address),.burst_count(legacy_burst_count),
        .write_data(legacy_write_data),.byte_enable(legacy_byte_enable),.busy(legacy_busy),.read_valid(legacy_read_data_ready),.read_data(legacy_read_data));
`else
    assign screen_mode=0; assign adopted=0; assign quiet=1; assign pixel=0; assign rgb=0;
    assign legacy_scanout_pending=0; assign legacy_read=0; assign legacy_write=0;
    assign legacy_address=0; assign legacy_burst_count=0; assign legacy_write_data=0; assign legacy_byte_enable=0;
`endif
    nds_hs_h3d bridge (.clk,.source_clk,.reset,.requested_session,.active_session,.engine_b_pixels_enable(1'b1),
        .video_quiescent(quiet),
        .console_release,.fault_bits,.capture_ready(space),.write9,.addr9,.data9,.width9,
        .write7,.addr7,.data7,.width7,
        .query9,.query_addr9(query_addr),.gx_live_status(status),.result_valid9(result_valid),.result_data9(result),.result_take9(take),
        .hblank,.frame_end,.lcd_vblank(vblank),.scanline(line),.external_frame_publish(published),.external_frame_bank(bank),
        .external_frame_adopted(adopted),.legacy_scanout_pending,.legacy_read,.legacy_write,.legacy_address,
        .legacy_burst_count,.legacy_byte_enable,.legacy_write_data,.legacy_read_data_ready,.legacy_read_data,.legacy_busy,
        .ddram_read(rd),.ddram_write(wr),.ddram_burst_count(burst),.ddram_byte_enable(be),.ddram_address(addr),
        .ddram_write_data(data),.ddram_busy(busy),.ddram_read_data_ready(rv),.ddram_read_data(q));
endmodule
