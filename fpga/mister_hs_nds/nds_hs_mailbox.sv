// SPDX-License-Identifier: GPL-3.0-or-later
// One ordered operation crossing from guest to host and one acknowledgement
// crossing back. No guest reset on the toggle pair: never cancel an accepted
// DDR/sector transfer. Instead drain its response without delivering it to a
// restarted guest. Level ready/valid held at both interfaces under stalls.
module nds_hs_mailbox #(parameter Q_BITS=32, P_BITS=64) (
    input wire guest_clk, guest_reset, guest_req_valid,
    input wire [Q_BITS-1:0] guest_req_data, output wire guest_req_ready,
    output reg guest_reply_valid=0, output reg [P_BITS-1:0] guest_reply_data,
    input wire guest_reply_take,
    input wire host_clk, output wire host_req_valid, output wire [Q_BITS-1:0] host_req_data,
    input wire host_req_ready, host_reply_valid, input wire [P_BITS-1:0] host_reply_data,
    output wire host_quiet
);
    reg req=0, ack=0, busy=0, killed=0, issued=0;
    reg [Q_BITS-1:0] payload; reg [P_BITS-1:0] response;
    (* async_reg="true" *) reg [1:0] req_sync=0, ack_sync=0;
    assign guest_req_ready = !guest_reset && !busy && !guest_reply_valid;
    always @(posedge guest_clk) begin
        ack_sync <= {ack_sync[0],ack};
        if (guest_reset || guest_reply_take) guest_reply_valid <= 0;
        if (guest_reset && busy) killed <= 1;
        if (busy && ack_sync[1] == req) begin
            busy <= 0;
            guest_reply_valid <= !(killed || guest_reset);
            guest_reply_data <= response;
        end
        if (guest_req_ready && guest_req_valid) begin
            payload <= guest_req_data; req <= ~req; busy <= 1; killed <= 0;
        end
    end
    assign host_req_valid = !issued && req_sync[1] != ack;
    assign host_req_data = payload;
    assign host_quiet = !issued && req_sync[1] == ack;
    always @(posedge host_clk) begin
        req_sync <= {req_sync[0],req};
        if (host_req_valid && host_req_ready) issued <= 1;
        if (issued && host_reply_valid) begin
            response <= host_reply_data; ack <= req_sync[1]; issued <= 0;
        end
    end
endmodule
