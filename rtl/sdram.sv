
module sdram
#(
	parameter integer DQ_PIPE = 0,

	parameter integer CAS_LATENCY = 2,

	parameter integer TRCD_WAIT = 1
)
(
	input             init,
	input             clk,

	inout     [15:0] SDRAM_DQ,
	output reg [12:0] SDRAM_A,
	output            SDRAM_DQML,
	output            SDRAM_DQMH,
	output reg  [1:0] SDRAM_BA,
	output            SDRAM_nCS,
	output            SDRAM_nWE,
	output            SDRAM_nRAS,
	output            SDRAM_nCAS,
	output            SDRAM_CKE,
	output            SDRAM_CLK,

   input             refresh_req,

	input      [26:1] ch1_addr,
	output reg [63:0] ch1_dout,
	input      [15:0] ch1_din,
	input             ch1_req,
	input             ch1_rnw,
	output reg        ch1_ready,
	output reg        ch1_accept,

	input      [26:1] ch2_addr,
	output reg [31:0] ch2_dout,
	input      [31:0] ch2_din,
	input       [3:0] ch2_be,      // byte enables for writes (DQM masks), keep 4'b1111 for reads
	input             ch2_req,
	input             ch2_cancel,
	input             ch2_rnw,
	output reg        ch2_ready,
	output reg        ch2_ready16,
	output reg [31:0] ch2_dout_hi,
	output reg        ch2_ready64,

	input      [24:1] ch3_addr,
	output reg [15:0] ch3_dout,
	input      [15:0] ch3_din,
	input             ch3_req,
	input             ch3_rnw,
	output reg        ch3_ready
);

localparam BURST_LENGTH        = 4;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;
localparam ACCESS_TYPE         = 1'b0;
localparam OP_MODE             = 2'b00;
localparam NO_WRITE_BURST      = 1'b1;
localparam [2:0] CAS_LAT_B     = CAS_LATENCY[2:0];
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LAT_B, ACCESS_TYPE, BURST_CODE};

localparam RDLY                = CAS_LATENCY + BURST_LENGTH + DQ_PIPE;

localparam sdram_startup_cycles= 14'd12100;
localparam cycles_per_refresh  = 14'd750;
localparam startup_refresh_max = 14'b11111111111111;

wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command;
reg        chip;

reg        refresh_due = 0;

reg [15:0] dq_reg;
reg [15:0] dq_p1, dq_p2, dq_p3;

wire [15:0] dqu1 = DQ_PIPE ? dq_p1 : dq_reg;
wire [15:0] dqu2 = DQ_PIPE ? dq_p2 : dq_reg;
wire [15:0] dqu3 = DQ_PIPE ? dq_p3 : dq_reg;

reg [15:0] dq_out;
reg        dq_oe;
assign SDRAM_DQ = dq_oe ? dq_out : 16'bZ;

reg [15:0] dq_pre;

assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam STATE_STARTUP = 0;
localparam STATE_WAIT    = 1;
localparam STATE_RW1     = 2;
localparam STATE_RW2     = 3;
localparam STATE_IDLE    = 4;
localparam STATE_IDLE_1  = 5;
localparam STATE_IDLE_2  = 6;
localparam STATE_IDLE_3  = 7;
localparam STATE_IDLE_4  = 8;
localparam STATE_IDLE_5  = 9;
localparam STATE_RFSH    = 10;
localparam STATE_WAIT2   = 11;


always @(posedge clk) begin
	reg [RDLY:0] data_ready_delay1, data_ready_delay2, data_ready_delay3;

	reg        saved_wr;
	reg [12:0] cas_addr;
	reg [31:0] saved_data;
	reg  [3:0] saved_be;
	reg  [3:0] state = STATE_STARTUP;

	reg       ch1_rq, ch2_rq, ch3_rq;
	reg [1:0] ch;

	reg [12:0] pre_a, pre_cas;
	reg  [1:0] pre_ba;
	reg [31:0] pre_data;
	reg  [3:0] pre_be;
	reg        pre_rfsh = 0, pre_ch1 = 0, pre_ch2 = 0, pre_ch3 = 0;
	reg        pre_chip, pre_wr;
	reg        n_ch1, n_ch2, n_ch3;

	reg [26:1] ch2_addr_r;
	reg [31:0] ch2_din_r;
	reg  [3:0] ch2_be_r;
	reg        ch2_rnw_r;
	reg        ch2_kill = 0;

	ch1_rq <= ch1_rq | ch1_req;
	ch2_rq <= (ch2_rq & ~ch2_cancel) | ch2_req;
	ch3_rq <= ch3_rq | ch3_req;

	n_ch1 = ch1_rq | ch1_req;
	n_ch2 = (ch2_rq & ~ch2_cancel) | ch2_req;
	n_ch3 = ch3_rq | ch3_req;

	pre_rfsh <= refresh_req | refresh_due;
	pre_ch1  <= ~(refresh_req | refresh_due) & n_ch1;
	pre_ch2  <= ~(refresh_req | refresh_due) & ~n_ch1 & n_ch2;
	pre_ch3  <= ~(refresh_req | refresh_due) & ~n_ch1 & ~n_ch2 & n_ch3;

	if (n_ch1) begin
		{pre_cas[12:9], pre_ba, pre_a, pre_cas[8:0]} <= {2'b00, 1'b1, ch1_addr[25:1]};
		pre_chip <= ch1_addr[26];
		pre_data <= ch1_din;
		pre_be   <= 4'b1111;
		pre_wr   <= ~ch1_rnw;
	end
	else if (n_ch2) begin
		if (ch2_req) begin
			{pre_cas[12:9], pre_ba, pre_a, pre_cas[8:0]} <= {2'b00, ch2_rnw, ch2_addr[25:1]};
			pre_chip <= ch2_addr[26];
			pre_data <= ch2_din;
			pre_be   <= ch2_be;
			pre_wr   <= ~ch2_rnw;
		end
		else begin
			{pre_cas[12:9], pre_ba, pre_a, pre_cas[8:0]} <= {2'b00, ch2_rnw_r, ch2_addr_r[25:1]};
			pre_chip <= ch2_addr_r[26];
			pre_data <= ch2_din_r;
			pre_be   <= ch2_be_r;
			pre_wr   <= ~ch2_rnw_r;
		end
	end
	else begin
		{pre_cas[12:9], pre_ba, pre_a, pre_cas[8:0]} <= {2'b00, ch3_rnw, ch3_addr[23:1], 2'b00};
		pre_chip <= ch3_addr[24];
		pre_data <= {8'hFF, ch3_din[15:8], 8'hFF, ch3_din[7:0]};
		pre_be   <= 4'b1111;
		pre_wr   <= ~ch3_rnw;
	end

	if (ch2_req) begin
		ch2_addr_r <= ch2_addr;
		ch2_din_r  <= ch2_din;
		ch2_be_r   <= ch2_be;
		ch2_rnw_r  <= ch2_rnw;
	end

	ch1_ready   <= 0;
	ch1_accept  <= 0;
	ch2_ready   <= 0;
	ch2_ready16 <= 0;
	ch2_ready64 <= 0;
	ch3_ready   <= 0;

	refresh_count <= refresh_count+1'b1;
	refresh_due   <= (refresh_count >= cycles_per_refresh);

	data_ready_delay1 <= data_ready_delay1>>1;
	data_ready_delay2 <= data_ready_delay2>>1;
	data_ready_delay3 <= data_ready_delay3>>1;

	dq_reg <= SDRAM_DQ;
	dq_p1  <= dq_reg;
	dq_p2  <= dq_reg;
	dq_p3  <= dq_reg;

	if(data_ready_delay1[3]) ch1_dout[15:00] <= dqu1;
	if(data_ready_delay1[2]) ch1_dout[31:16] <= dqu1;
	if(data_ready_delay1[1]) ch1_dout[47:32] <= dqu1;
	if(data_ready_delay1[0]) ch1_dout[63:48] <= dqu1;
	if(data_ready_delay1[0]) ch1_ready <= 1;

	if(data_ready_delay2[3]) ch2_dout[15:00] <= dqu2;
	if(data_ready_delay2[2]) ch2_dout[31:16] <= dqu2;
	if(data_ready_delay2[2]) ch2_ready   <= 1;
	if(data_ready_delay2[3]) ch2_ready16 <= 1;
	if(data_ready_delay2[1]) ch2_dout_hi[15:00] <= dqu2;
	if(data_ready_delay2[0]) ch2_dout_hi[31:16] <= dqu2;
	if(data_ready_delay2[0]) ch2_ready64 <= 1;

	if(data_ready_delay3[3]) ch3_dout[07:00] <= dqu3[7:0];
	if(data_ready_delay3[1]) ch3_dout[15:08] <= dqu3[7:0];
	if(data_ready_delay3[1]) ch3_ready <= 1;

	dq_oe  <= 0;
	dq_out <= dq_pre;

	command <= CMD_NOP;
	case (state)
		STATE_STARTUP: begin
			SDRAM_A    <= 0;
			SDRAM_BA   <= 0;

			if (refresh_count == (startup_refresh_max-64)) chip <= 0;
			if (refresh_count == (startup_refresh_max-32)) chip <= 1;

			if (refresh_count == startup_refresh_max-63 || refresh_count == startup_refresh_max-31) begin
				command     <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1;
				SDRAM_BA    <= 2'b00;
			end
			if (refresh_count == startup_refresh_max-55 || refresh_count == startup_refresh_max-23) begin
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-47 || refresh_count == startup_refresh_max-15) begin
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-39 || refresh_count == startup_refresh_max-7) begin
				command     <= CMD_LOAD_MODE;
				SDRAM_A     <= MODE;
			end

			if (!refresh_count) begin
				state   <= STATE_IDLE;
				refresh_count <= 0;
				refresh_due   <= 0;   // count is being cleared; keep the flag in step
			end
		end

		STATE_IDLE_5: state <= STATE_IDLE_4;
		STATE_IDLE_4: state <= STATE_IDLE_3;
		STATE_IDLE_3: state <= STATE_IDLE_2;
		STATE_IDLE_2: state <= STATE_IDLE_1;
		STATE_IDLE_1: state <= STATE_IDLE;

		STATE_RFSH: begin
			state    <= STATE_IDLE_5;
			command  <= CMD_AUTO_REFRESH;
			chip     <= 1;
		end

		STATE_IDLE: begin
			if (pre_rfsh) begin
				state         <= STATE_RFSH;
				command       <= CMD_AUTO_REFRESH;
				refresh_count <= 0;
				refresh_due   <= 0;
				chip          <= 0;
			end
			else if (pre_ch1 | pre_ch2 | pre_ch3) begin
				SDRAM_A    <= pre_a;
				SDRAM_BA   <= pre_ba;
				cas_addr   <= pre_cas;
				chip       <= pre_chip;
				saved_data <= pre_data;
				saved_be   <= pre_be;
				saved_wr   <= pre_wr;
				command    <= CMD_ACTIVE;
				state      <= STATE_WAIT;

				if (pre_ch1) begin
					ch         <= 0;
					ch1_rq     <= 0;
					ch1_accept <= 1;
				end
				else if (pre_ch2) begin
					ch       <= 1;
					ch2_rq   <= 0;
					ch2_kill <= 0;
				end
				else begin
					ch      <= 2;
					ch3_rq  <= 0;
				end
			end
		end

		STATE_WAIT: begin
			state  <= (TRCD_WAIT > 1) ? STATE_WAIT2 : STATE_RW1;
			dq_pre <= saved_data[15:0];
		end
		STATE_WAIT2: state <= STATE_RW1;
		STATE_RW1: begin
			SDRAM_A <= cas_addr;
			if(saved_wr) begin
				command  <= CMD_WRITE;
				dq_pre   <= saved_data[31:16];
				dq_oe    <= 1;
				SDRAM_A[12:11] <= ~saved_be[1:0];
				if(!ch) begin
					ch1_ready  <= 1;
					state <= STATE_IDLE_2;
				end
				else begin
					state <= STATE_RW2;
				end
			end
			else begin
				command <= CMD_READ;
				state   <= STATE_IDLE_5;
				     if(ch == 0) data_ready_delay1[RDLY] <= 1;
				else if(ch == 1) begin
					if (~ch2_kill) data_ready_delay2[RDLY] <= 1;
				end
				else             data_ready_delay3[RDLY] <= 1;
			end
		end

		STATE_RW2: begin
			if(ch == 1) begin
				state       <= STATE_IDLE_4;
				SDRAM_A[10] <= 1;
				SDRAM_A[0]  <= 1;
				SDRAM_A[12:11] <= ~saved_be[3:2];
				command     <= CMD_WRITE;
				dq_oe       <= 1;
				ch2_ready   <= 1;
				ch2_ready16 <= 1;
				ch2_ready64 <= 1;
			end
			else begin
				state       <= STATE_IDLE_2;
				SDRAM_A[10] <= 1;
				SDRAM_A[1]  <= 1;
				command     <= CMD_WRITE;
				dq_oe       <= 1;
				ch3_ready   <= 1;
			end
		end
	endcase

	if (init) begin
		state <= STATE_STARTUP;
		refresh_count <= startup_refresh_max - sdram_startup_cycles;
		refresh_due   <= 0;
	end

   if (ch2_cancel) begin
		data_ready_delay2 <= 'd0;
		ch2_ready         <= 0;
		ch2_ready16       <= 0;
		ch2_ready64       <= 0;
		if (!ch2_req) ch2_kill <= 1;
	end

end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
