// SPDX-License-Identifier: GPL-3.0-or-later
// Haskell console -> NDS4MiSTer v1.0.1 matched-display transport. No guest
// CPU, host acknowledgement or pixel generator here. See sim/run_hs_h3d.sh.
module nds_hs_h3d #(
    parameter integer DDR_HZ = 60_000_000
) (
    input wire clk, reset, source_clk,
    input wire [31:0] requested_session,
    input wire engine_b_pixels_enable, video_quiescent,
    output wire console_release, output wire [31:0] active_session, fault_bits,
    output wire external_frame_publish, output wire [1:0] external_frame_bank,
    input wire external_frame_adopted,
    output wire capture_ready,
    input wire write9, write7, input wire [31:0] addr9, addr7, data9, data7,
    input wire [2:0] width9, width7,
    input wire hblank, frame_end, lcd_vblank, input wire [8:0] scanline,
    output wire [31:0] gx_live_status,
    input wire query9, input wire [31:0] query_addr9,
    output logic result_valid9, output logic [31:0] result_data9, input wire result_take9,
    input wire legacy_scanout_pending, legacy_read, legacy_write,
    input wire [7:0] legacy_burst_count, legacy_byte_enable,
    input wire [28:0] legacy_address, input wire [63:0] legacy_write_data,
    output wire legacy_busy, legacy_command_accepted, legacy_read_data_ready,
    output wire [63:0] legacy_read_data,
    output wire ddram_read, ddram_write, output wire [7:0] ddram_burst_count, ddram_byte_enable,
    output wire [28:0] ddram_address, output wire [63:0] ddram_write_data,
    input wire ddram_busy, ddram_read_data_ready, input wire [63:0] ddram_read_data
);
    // The physical port takes full 64-bit word addresses (no 0x30000000 translation).
    localparam [28:0] CTRL=29'h07f80000, SLOTS=29'h07f82000;
    typedef struct packed {logic rd,wr; logic [7:0] burst; logic [28:0] addr;
                           logic [63:0] data; logic [7:0] be;} cmd_t;
    typedef struct packed {logic busy,accepted,valid; logic [63:0] data;} rsp_t;
    cmd_t ctl, pkt, plane, shared_ctl; rsp_t c,p,v,m;
    wire arb_fault, mux_fault, packet_fault, cdc_fault, readback_fault;
    wire [3:0] cdc_reason; wire [4:0] packet_reason;
    logic ingress_fault;
    (* async_reg="true" *) logic [1:0] src_fault_ddr;
    always_ff @(posedge clk) if (reset || !console_release) src_fault_ddr<=0;
                             else src_fault_ddr<={src_fault_ddr[0],ingress_fault || readback_fault};
    wire [31:0] external_faults = {8'b0,packet_reason,cdc_reason,2'b0,src_fault_ddr[1],mux_fault,arb_fault,packet_fault,cdc_fault,8'b0};
    nds_h3d_control_init #(.BASE_WORD(CTRL),.PACKET_MODE(1),.SESSION_POLICY_ENABLE(1),
        .MATCHED_DISPLAY_TEST(1),.MATCHED_ENGINE_B_OPTIONAL(1),.DIAGNOSTIC_HOLD_ENABLE(0),
        .HPS_HEARTBEAT_TIMEOUT_CYCLES(DDR_HZ)) control_unit (
        .clk,.reset,.requested_session,.engine_b_pixels_enable,.video_quiescent,
        .external_fault_bits(external_faults),.fpga_heartbeat_value(32'b0),.fpga_telemetry_value(32'b0),
        .console_release,.active_session,.fault_bits,
        .ddram_read(ctl.rd),.ddram_write(ctl.wr),.ddram_burst_count(ctl.burst),.ddram_address(ctl.addr),
        .ddram_write_data(ctl.data),.ddram_byte_enable(ctl.be),.ddram_busy(c.busy),
        .ddram_command_accepted(c.accepted),.ddram_read_data(c.data),.ddram_read_data_ready(c.valid));

    // Asynchronous assertion/synchronous release; session is stable well
    // before release and held until the next reset/quiesce sequence.
    wire path_reset = reset || !console_release;
    (* async_reg="true" *) logic [2:0] source_reset_pipe;
    (* async_reg="true" *) logic [31:0] session_meta, session_src;
    always_ff @(posedge source_clk or posedge path_reset)
        if(path_reset) source_reset_pipe<=7; else source_reset_pipe<={source_reset_pipe[1:0],1'b0};
    always_ff @(posedge source_clk) begin session_meta<=active_session; session_src<=session_meta; end
    wire src_reset=source_reset_pipe[2];

    // One capture slot per simultaneous architectural effect, one timestamp
    // per issuing edge. No new source bundle can overtake a retained member.
    // capture_ready is independent of valid and must qualify the *original*
    // guest/LCD effect. A violation faults the session instead of dropping it.
    typedef struct packed { logic [27:0] addr; logic [1:0] width;
                            logic [3:0] be; logic [31:0] data; } beat_t;
    function automatic beat_t access_beat(input logic [31:0] a,d,input logic [2:0] w);
        access_beat={a[27:0],(w==1?2'd0:w==2?2'd1:2'd2),
                     (w==1?4'b1:w==2?4'b11:4'hf)<<a[1:0],d<<{a[1:0],3'b0}};
    endfunction
    wire source_active,rg,r9,r7,rh,rf;
    logic vg,v9,v7,vh,vf;
    logic [63:0] stamp, tag;
    logic [8:0] line;
    logic [31:0] lcd_frame, terminal_frame, held_phase, held_end;
    beat_t a9,a7;
    logic fence, request_pending, waiting_result;
    logic [31:0] token;
    logic [4:0] read_index;
    wire req_ready, response; wire [31:0] rsp_id,cache_data;
    wire vram9=addr9[31:24]==8'h06;
    wire [8:0] fifo_level; wire [6:0] stack_status; wire gx_busy, empty, below_half;
    assign gx_live_status={4'b0,gx_busy,empty,below_half,fifo_level,stack_status[6],1'b0,stack_status[5:0],8'b0};
    wire clear_stack=vg && rg && !fence && a9.addr[27:2]==26'h1000180 && a9.be[1] && a9.data[15];
    assign capture_ready=source_active && !src_reset && !(vg||v9||v7||vh||vf) && !ingress_fault;
    wire any_effect=write9||write7||hblank||frame_end||query9;
    always_ff @(posedge source_clk) begin
        if (src_reset) begin
            vg<=0; v9<=0; v7<=0; vh<=0; vf<=0; stamp<=0; lcd_frame<=0; terminal_frame<=0;
            token<=0; request_pending<=0; waiting_result<=0; result_valid9<=0; ingress_fault<=0;
        end else begin
            stamp<=stamp+1'b1;
            if(rg) vg<=0; if(r9) v9<=0; if(r7) v7<=0; if(rh) vh<=0; if(rf) vf<=0;
            if (result_take9) result_valid9<=0;
            if (request_pending && req_ready) request_pending<=0;
            if (response) begin
                if (!waiting_result || rsp_id!=token) ingress_fault<=1;
                else begin result_data9<=cache_data; result_valid9<=1; waiting_result<=0; end
            end
            if(any_effect && !capture_ready) ingress_fault<=1;
            if (capture_ready && any_effect) begin
                tag<=stamp; line<=scanline; held_phase<=lcd_frame; held_end<=terminal_frame+1'b1;
                vg<=query9 || (write9&&!vram9); v9<=write9&&vram9; v7<=write7; vh<=hblank; vf<=frame_end;
                a9<=access_beat(addr9,data9,width9); a7<=access_beat(addr7,data7,width7); fence<=query9;
                if (hblank && scanline==262) lcd_frame<=lcd_frame+1'b1;
                if (frame_end) terminal_frame<=terminal_frame+1'b1;
                if (query9) begin
                    if (write9 || waiting_result || result_valid9 || &token) ingress_fault<=1;
                    token<=token+1'b1; request_pending<=1; waiting_result<=1;
                    read_index<=query_addr9==32'h04000600 ? 5'd4 : 5'd5+(query_addr9[6:2]^5'd16);
                end
                if (write7 && addr7[31:24]!=8'h06) ingress_fault<=1;
            end
        end
    end
    wire raw_v,raw_r,raw_fe,raw_bv,raw_br,out_v,out_r,out_fe,out_bv,out_br;
    wire [31:0] raw_f,raw_bf,out_f,out_bf; wire [127:0] raw_d,out_d;
    nds_h3d_frame_record_cdc #(.ASYNC_LGDEPTH(4),.SPARSE_HBLANK(0),.SCANLINE_TAGS(1)) records (
        .source_clk,.ddr_clk(clk),.reset,.session_flush(!console_release),.lcd_vblank,
        .gpu_valid(vg),.gpu_ready(rg),.gpu_address(fence?28'h7f0:a9.addr-28'h4000000),
        .gpu_access(fence?2'b11:a9.width),.gpu_byte_enable(fence?4'b0:a9.be),.gpu_data(fence?token:a9.data),
        .gpu_timestamp(tag),.gpu_scanline(line),
        .arm9_vram_valid(v9),.arm9_vram_ready(r9),.arm9_vram_address(a9.addr),.arm9_vram_access(a9.width),
        .arm9_vram_byte_enable(a9.be),.arm9_vram_data(a9.data),.arm9_vram_timestamp(tag),.arm9_vram_scanline(line),
        .arm7_vram_valid(v7),.arm7_vram_ready(r7),.arm7_vram_address(a7.addr),.arm7_vram_access(a7.width),
        .arm7_vram_byte_enable(a7.be),.arm7_vram_data(a7.data),.arm7_vram_timestamp(tag),.arm7_vram_scanline(line),
        .hblank_valid(vh),.hblank_ready(rh),.hblank_line(line),.hblank_frame(held_phase),.hblank_timestamp(tag),
        .frame_valid(vf),.frame_ready(rf),.frame_number(held_end),.frame_timestamp(tag),.source_active,
        .ddr_fault(cdc_fault),.ddr_fault_reason(cdc_reason),.fifo_level,.fifo_empty(empty),.fifo_below_half(below_half),
        .gx_stack_ack(clear_stack),.gx_stack_status(stack_status),.gx_geometry_busy(gx_busy),
        .record_valid(raw_v),.record_ready(raw_r),.record(raw_d),.record_frame(raw_f),.record_frame_end(raw_fe),
        .boundary_valid(raw_bv),.boundary_ready(raw_br),.boundary_frame(raw_bf));
    nds_h3d_vram_record_packer #(.RECONSTRUCT_FRAME(1),.BANKED_RAM(1)) packer (
        .clk,.reset(path_reset),.in_record_valid(raw_v),.in_record_ready(raw_r),.in_record(raw_d),
        .in_record_frame(raw_f),.in_record_frame_end(raw_fe),.in_boundary_valid(raw_bv),.in_boundary_ready(raw_br),
        .in_boundary_frame(raw_bf),.out_record_valid(out_v),.out_record_ready(out_r),.out_record(out_d),
        .out_record_frame(out_f),.out_record_frame_end(out_fe),.out_boundary_valid(out_bv),.out_boundary_ready(out_br),
        .out_boundary_frame(out_bf));
    nds_h3d_frame_packet_writer #(.CONTROL_BASE_WORD(CTRL),.SLOT_BASE_WORD(SLOTS),.MAX_RECORDS(1024)) packets (
        .clk,.reset,.session_flush(!console_release),.session(active_session),.record_valid(out_v),.record_ready(out_r),
        .record(out_d),.record_frame(out_f),.record_frame_end(out_fe),.boundary_valid(out_bv),.boundary_ready(out_br),
        .boundary_frame(out_bf),.fault(packet_fault),.fault_reason(packet_reason),
        .ddram_read(pkt.rd),.ddram_write(pkt.wr),.ddram_burst_count(pkt.burst),.ddram_address(pkt.addr),
        .ddram_write_data(pkt.data),.ddram_byte_enable(pkt.be),.ddram_busy(p.busy),
        .ddram_command_accepted(p.accepted),.ddram_read_data(p.data),.ddram_read_data_ready(p.valid));

    wire qr; wire [7:0] qb; wire [28:0] qa; rsp_t q;
    nds_h3d_gx_readback_reply #(.CONTROL_BASE_WORD(CTRL),.BURST_FILL(1)) readback (
        .source_clk,.ddr_clk(clk),.reset,.session_flush(!console_release),.session(session_src),
        .request_valid(request_pending),.request_id(token),.request_ready(req_ready),
        .response_valid(response),.response_id(rsp_id),.read_index,.read_data(cache_data),.source_fault(readback_fault),
        .ddram_read(qr),.ddram_burst_count(qb),.ddram_address(qa),.ddram_busy(q.busy),
        .ddram_command_accepted(q.accepted),.ddram_read_data(q.data),.ddram_read_data_ready(q.valid));
    nds_fpga3d_port_mux readback_mux (.clk,.reset,
        .c_rd(ctl.rd),.c_wr(ctl.wr),.c_burst(ctl.burst),.c_addr(ctl.addr),.c_din(ctl.data),.c_be(ctl.be),
        .c_busy(c.busy),.c_accepted(c.accepted),.c_dout(c.data),.c_valid(c.valid),
        .a_rd(qr),.a_wr(1'b0),.a_burst(qb),.a_addr(qa),.a_din(64'b0),.a_be(8'hff),
        .a_busy(q.busy),.a_accepted(q.accepted),.a_dout(q.data),.a_valid(q.valid),
        .rd(shared_ctl.rd),.wr(shared_ctl.wr),.burst(shared_ctl.burst),.addr(shared_ctl.addr),
        .din(shared_ctl.data),.be(shared_ctl.be),.busy(m.busy),.accepted(m.accepted),.dout(m.data),.valid(m.valid),
        .protocol_error(mux_fault));

    // The v1.0.1 companion in matched mode sends format 2: two already
    // composited physical screens, not an Engine-A transparent 3D plane.
    // Poll independently of CPU startup. Only the *real* framebuffer may
    // adopt and release ownership. There is no line fetch in paired mode.
    logic descriptor_request; logic [11:0] retry_count; wire desc_ready, desc_pending;
    always_ff @(posedge source_clk) begin
        if (src_reset) begin descriptor_request<=0; retry_count<=0; end
        else if (descriptor_request && desc_ready) begin descriptor_request<=0; retry_count<='1; end
        else if (!descriptor_request && !desc_pending) begin
            if (retry_count==0) descriptor_request<=1; else retry_count<=retry_count-1'b1;
        end
    end
    nds_h3d_plane_reader #(.CONTROL_BASE_WORD(CTRL),.BANK0_BASE_WORD(29'h07fa0000),.BANK1_BASE_WORD(29'h07fa8000)) descriptor (
        .ddr_clk(clk),.ddr_reset(path_reset),.pixel_clk(source_clk),.pixel_reset(src_reset),
        .ddr_session(active_session),.pixel_session(session_src),.external_enable(console_release),
        .descriptor_request,.descriptor_request_ready(desc_ready),.pixel_descriptor_pending(desc_pending),
        .line_request(1'b0),.line_frame(32'b0),.line_y(8'b0),.frame_boundary(frame_end),.descriptor_switch_window(lcd_vblank),
        .scanline_tick(hblank),.scanline_y(scanline[7:0]),.line_start(1'b0),.line_end(1'b0),
        .merge_frame(32'b0),.merge_y(8'b0),.pixel_x(8'b0),.full_frame_publish(external_frame_publish),
        .full_frame_bank(external_frame_bank),.full_frame_adopted(external_frame_adopted),
        .ddram_read(plane.rd),.ddram_write(plane.wr),.ddram_burst_count(plane.burst),.ddram_address(plane.addr),
        .ddram_write_data(plane.data),.ddram_byte_enable(plane.be),.ddram_busy(v.busy),
        .ddram_command_accepted(v.accepted),.ddram_read_data(v.data),.ddram_read_data_ready(v.valid));
    nds_h3d_ddr_fabric fabric (.clk,.reset,.legacy_scanout_pending,.legacy_read,.legacy_write,.legacy_burst_count,
        .legacy_address,.legacy_write_data,.legacy_byte_enable,.legacy_busy,.legacy_command_accepted,
        .legacy_read_data,.legacy_read_data_ready,
        .plane_read(plane.rd),.plane_write(plane.wr),.plane_burst_count(plane.burst),.plane_address(plane.addr),
        .plane_write_data(plane.data),.plane_byte_enable(plane.be),.plane_busy(v.busy),
        .plane_command_accepted(v.accepted),.plane_read_data(v.data),.plane_read_data_ready(v.valid),
        .event_read(pkt.rd),.event_write(pkt.wr),.event_burst_count(pkt.burst),.event_address(pkt.addr),
        .event_write_data(pkt.data),.event_byte_enable(pkt.be),.event_busy(p.busy),
        .event_command_accepted(p.accepted),.event_read_data(p.data),.event_read_data_ready(p.valid),
        .control_read(shared_ctl.rd),.control_write(shared_ctl.wr),.control_burst_count(shared_ctl.burst),
        .control_address(shared_ctl.addr),.control_write_data(shared_ctl.data),.control_byte_enable(shared_ctl.be),
        .control_busy(m.busy),.control_command_accepted(m.accepted),.control_read_data(m.data),.control_read_data_ready(m.valid),
        .ddram_read,.ddram_write,.ddram_burst_count,.ddram_address,.ddram_write_data,.ddram_byte_enable,
        .ddram_busy,.ddram_read_data,.ddram_read_data_ready,.protocol_error(arb_fault));
endmodule
