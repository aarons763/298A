/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // All output pins must be assigned. If not used, assign to 0.
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

  // List all unused inputs to prevent warnings
    wire _unused = &{ui_in[7:2], 1'b0};

endmodule
`default_nettype wire
