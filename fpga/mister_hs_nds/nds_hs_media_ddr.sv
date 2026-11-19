// SPDX-License-Identifier: GPL-3.0-or-later
// Single legacy client of the release H3D DDR arbiter. No speculation and
// no private copy of the ROM. Addresses at the external port are 64b beats.
// Readdatavalid is independent of waitrequest; drain the full granted burst
// even if the console resets. No soft reset is allowed on this owner.
module nds_hs_media_ddr #(parameter [7:0] FB_BURST=8'd128) (
    input wire clk, hard_reset,
    input wire rom_valid, input wire [31:0] rom_addr, output wire rom_ready,
    output reg rom_reply_valid=0, output reg [63:0] rom_reply_data,
    input wire [27:1] fb5_addr, fb6_addr, input wire [63:0] fb5_din,
    input wire fb5_req, fb6_req, output wire fb5_next, output reg fb5_ready=0, fb6_ready=0,
    output wire [63:0] fb6_dout, output wire fb6_valid, scanout_pending,
    output wire read_cmd,write_cmd, output reg [28:0] address, output reg [7:0] burst_count,
    output reg [63:0] write_data, output wire [7:0] byte_enable,
    input wire busy,read_valid, input wire [63:0] read_data
);
    localparam IDLE=0, ROM_CMD=1, ROM_RETURN=2, LINE_CMD=3, LINE_RETURN=4, STORE=5;
    reg [2:0] state=IDLE;
    reg [7:0] left; reg pending5=0,pending6=0;
    wire want5=pending5|fb5_req, want6=pending6|fb6_req;
    assign scanout_pending=want6 || state==LINE_CMD || state==LINE_RETURN;
    // Drain visible scanout first; keep a whole frame write ahead of a ROM
    // request. Bounds: both display clients issue finite line bursts only.
    assign rom_ready=state==IDLE && !want5 && !want6;
    assign read_cmd=state==ROM_CMD || state==LINE_CMD;
    assign write_cmd=state==STORE;
    assign byte_enable=8'hff;
    assign fb5_next=(state==IDLE && want5 && !want6) || (state==STORE && !busy && left>1);
    assign fb6_valid=state==LINE_RETURN && read_valid;
    assign fb6_dout=read_data;
    function automatic [28:0] cart_beat(input [31:0] a);
        // [0,252MiB), [252,276MiB), [276,464MiB). The host stages FF
        // through the end of the final mapped aperture for short media.
        if (a<32'h0fc00000) cart_beat=(32'h30000000>>3)+a[31:3];
        else if(a<32'h11400000) cart_beat=(32'h22800000>>3)+(a[31:3]-(32'h0fc00000>>3));
        else cart_beat=(32'h24400000>>3)+(a[31:3]-(32'h11400000>>3));
    endfunction
    always @(posedge clk) begin
        fb5_ready<=0; fb6_ready<=0; rom_reply_valid<=0;
        if (fb5_req) pending5<=1;
        if (fb6_req) pending6<=1;
        case(state)
        IDLE: if(want6) begin
            pending6<=0; address<={4'b0011,fb6_addr[27:3]}; burst_count<=FB_BURST; left<=FB_BURST; state<=LINE_CMD;
        end else if(want5) begin
            pending5<=0; address<={4'b0011,fb5_addr[27:3]}; burst_count<=FB_BURST; left<=FB_BURST; write_data<=fb5_din; state<=STORE;
        end else if(rom_valid) begin
            if(rom_addr>=32'h1d000000) begin rom_reply_valid<=1; rom_reply_data<='1; end
            else begin address<=cart_beat(rom_addr); burst_count<=1; state<=ROM_CMD; end
        end
        ROM_CMD: if(!busy) state<=ROM_RETURN;
        ROM_RETURN: if(read_valid) begin rom_reply_valid<=1; rom_reply_data<=read_data; state<=IDLE; end
        LINE_CMD: if(!busy) state<=LINE_RETURN;
        LINE_RETURN: if(read_valid) begin
            left<=left-1'b1;
            if(left==1) begin fb6_ready<=1; state<=IDLE; end
        end
        STORE: if(!busy) begin
            left<=left-1'b1;
            if(left==1) begin fb5_ready<=1; state<=IDLE; end
            else write_data<=fb5_din;
        end
        endcase
        // Only the outer DDR arbiter's quarantine reset cancels ownership.
        if(hard_reset) begin state<=IDLE; pending5<=0; pending6<=0; fb5_ready<=0; fb6_ready<=0; rom_reply_valid<=0; end
    end
endmodule
