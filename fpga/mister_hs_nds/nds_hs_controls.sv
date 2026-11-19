// SPDX-License-Identifier: GPL-3.0-or-later
// The cursor and guest use one release mapping. A held snapshot crosses
// as a unit: a stick update must not combine old high bits with new lows.
// Both clocks continue through guest reset; releases during reset still
// reach the destination. No independent reset of the handshake toggles.
module nds_hs_controls (
    input wire host_clk, guest_clk, input wire [31:0] joystick, input wire [15:0] joystick_analog,
    output wire cursor_pen, output wire [7:0] cursor_x,cursor_y,
    output wire [11:0] keys, output wire pen, output wire [7:0] x,y, output wire lid,blow
);
    wire [11:0] host_keys; wire host_lid,host_blow;
    nds_board_input map_inputs (.JOY(joystick),.ANALOG(joystick_analog),.KEYS(host_keys),
        .PEN(cursor_pen),.X(cursor_x),.Y(cursor_y),.LID(host_lid),.BLOW(host_blow));
    wire [30:0] current={host_keys,cursor_pen,cursor_x,cursor_y,host_lid,host_blow};
    reg [30:0] held=0,received=0;
    reg request=0,ack=0;
    (* async_reg="true" *) reg [1:0] req_sync=0,ack_sync=0;
    always @(posedge host_clk) begin
        ack_sync<={ack_sync[0],ack};
        if(request==ack_sync[1] && current!=held) begin held<=current;request<=~request;end
    end
    always @(posedge guest_clk) begin
        req_sync<={req_sync[0],request};
        if(req_sync[1]!=ack) begin received<=held;ack<=req_sync[1];end
    end
    assign {keys,pen,x,y,lid,blow}=received;
endmodule
