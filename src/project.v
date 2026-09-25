`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire load = ui_in[0];
    wire oe   = ui_in[1];

    reg [7:0] reg_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            reg_count <= 8'd0;
        else if (load)
            reg_count <= uio_in;
        else
            reg_count <= reg_count + 8'd1;
    end

    assign uo_out  = reg_count;
    assign uio_out = reg_count;
    assign uio_oe  = {8{oe & ena}};

    wire _unused = &{ui_in[7:2], 1'b0};

endmodule

`default_nettype wire
