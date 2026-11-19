// SPDX-License-Identifier: GPL-3.0-or-later
// Runtime FIO upload and architectural fetch share the guest master clock.
// No INIT_FILE and no array reset: the lifecycle holds the CPU until the
// last halfword of each complete image was acknowledged by the target RAM.
module nds_hs_bios_ram #(parameter WORD_BITS = 10) (
    input wire clk,
    input wire [WORD_BITS-1:0] read_addr, load_addr,
    input wire [31:0] load_data, input wire [3:0] load_be, input wire load_we,
    output reg [31:0] read_data
);
    (* ramstyle = "M10K" *) reg [31:0] words [0:(1<<WORD_BITS)-1];
    always @(posedge clk) begin
        if (load_we) begin
            for (int b = 0; b < 4; b++)
                if (load_be[b]) words[load_addr][8*b+:8] <= load_data[8*b+:8];
        end
        read_data <= words[read_addr];
    end
endmodule
