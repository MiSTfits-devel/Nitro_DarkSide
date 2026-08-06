// Stand-in for the Quartus WYSIWYG so the slave can be linted and simulated.
// Port list and widths copied from Quartus's own xml_info entry.
module cyclonev_hps_interface_hps2fpga_light_weight
(
	input  wire        clk,
	output reg  [11:0] awid, output reg [20:0] awaddr, output reg [3:0] awlen,
	output reg   [2:0] awsize, output reg [1:0] awburst, output reg [1:0] awlock,
	output reg   [3:0] awcache, output reg [2:0] awprot, output reg awvalid,
	input  wire        awready,
	output reg  [11:0] wid, output reg [31:0] wdata, output reg [3:0] wstrb,
	output reg         wlast, output reg wvalid, input wire wready,
	input  wire [11:0] bid, input wire [1:0] bresp, input wire bvalid,
	output reg         bready,
	output reg  [11:0] arid, output reg [20:0] araddr, output reg [3:0] arlen,
	output reg   [2:0] arsize, output reg [1:0] arburst, output reg [1:0] arlock,
	output reg   [3:0] arcache, output reg [2:0] arprot, output reg arvalid,
	input  wire        arready,
	input  wire [11:0] rid, input wire [31:0] rdata, input wire [1:0] rresp,
	input  wire        rlast, input wire rvalid, output reg rready
);
endmodule
