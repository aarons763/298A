`default_nettype none
// Paste this ENTIRE file into VGA Playground's project.v tab.
// 25.175 MHz pixel clock; 640x480; active-high buttons.
// One-tile candidate: actual GF180 fit MUST be checked by hardening.
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
    // Standard 800 x 525 raster, negative sync polarity.
    reg [9:0] h;
    reg [9:0] v;
    always @(posedge clk) begin
        if (!rst_n) begin
            h <= 10'd0;
            v <= 10'd0;
        end else if (h == 10'd799) begin
            h <= 10'd0;
            v <= (v == 10'd524) ? 10'd0 : v + 10'd1;
        end else begin
            h <= h + 10'd1;
        end
    end
    wire hsync = !((h >= 10'd656) && (h < 10'd752));
    wire vsync = !((v >= 10'd490) && (v < 10'd492));
    wire visible = (h < 10'd640) && (v < 10'd480);
    // Update just after the last visible line, avoiding image tearing.
    wire frame_tick = (h == 10'd799) && (v == 10'd479);

    // Synchronize external buttons to the pixel clock. Holding a button
    // moves continuously; pressing both directions cancels movement.
    reg [4:0] buttons_meta, buttons;
    always @(posedge clk) begin
        if (!rst_n) begin
            buttons_meta <= 5'd0;
            buttons <= 5'd0;
        end else begin
            buttons_meta <= ui_in[4:0];
            buttons <= buttons_meta;
        end
    end

    // Game coordinates use 8x8 pixel cells: 80 columns, 60 rows.
    // Paddles are 1x8 cells (8x64 pixels); ball is 1 cell.
    reg [5:0] p1_y, p2_y;
    reg [6:0] ball_x;
    reg [5:0] ball_y;
    reg dir_x, dir_y;  // 0 = left/up, 1 = right/down
    reg playing, half_frame;
    reg [3:0] score1, score2; // Binary scores, wrap from 15 to 0.

    // Reflect BEFORE moving: no unsigned underflow at the walls.
    wire next_dir_y = (ball_y == 6'd0)  ? 1'b1 :
                      (ball_y == 6'd59) ? 1'b0 : dir_y;
    wire [5:0] next_ball_y = next_dir_y ? ball_y + 6'd1 :
                                                        ball_y - 6'd1;
    // Modulo subtraction safely tests an eight-cell interval here:
    // valid paddle tops are 0..52 and ball rows are 0..59.
    wire [5:0] hit_offset1 = next_ball_y - p1_y;
    wire [5:0] hit_offset2 = next_ball_y - p2_y;
    wire hit1 = (hit_offset1 < 6'd8);
    wire hit2 = (hit_offset2 < 6'd8);

    always @(posedge clk) begin
        if (!rst_n) begin
            p1_y <= 6'd26;
            p2_y <= 6'd26;
            ball_x <= 7'd40;
            ball_y <= 6'd30;
            dir_x <= 1'b1;
            dir_y <= 1'b1;
            playing <= 1'b0;
            half_frame <= 1'b0;
            score1 <= 4'd0;
            score2 <= 4'd0;
        end else if (frame_tick && ena) begin
            half_frame <= ~half_frame;
            if (buttons[0] && !buttons[1] && p1_y != 6'd0)
                p1_y <= p1_y - 6'd1;
            else if (buttons[1] && !buttons[0] && p1_y < 6'd52)
                p1_y <= p1_y + 6'd1;
            if (buttons[2] && !buttons[3] && p2_y != 6'd0)
                p2_y <= p2_y - 6'd1;
            else if (buttons[3] && !buttons[2] && p2_y < 6'd52)
                p2_y <= p2_y + 6'd1;

            if (!playing) begin
                ball_x <= 7'd40;
                ball_y <= 6'd30;
                // Level-sensitive serve: hold high for automatic re-serves.
                if (buttons[4]) begin
                    playing <= 1'b1;
                    half_frame <= 1'b0;
                end
            end else if (half_frame) begin
                // Ball moves 8 pixels in each axis every two frames.
                ball_y <= next_ball_y;
                dir_y <= next_dir_y;
                if ((!dir_x && ball_x == 7'd0) ||
                    ( dir_x && ball_x == 7'd79)) begin
                    if (dir_x) score1 <= score1 + 4'd1;
                    else       score2 <= score2 + 4'd1;
                    playing <= 1'b0;
                    ball_x <= 7'd40;
                    ball_y <= 6'd30;
                    dir_x <= ~dir_x;
                end else if (!dir_x && ball_x == 7'd4 && hit1) begin
                    ball_x <= 7'd5;
                    dir_x <= 1'b1;
                    // Upper/lower half of paddle chooses outgoing slope.
                    dir_y <= hit_offset1[2];
                end else if (dir_x && ball_x == 7'd75 && hit2) begin
                    ball_x <= 7'd74;
                    dir_x <= 1'b0;
                    dir_y <= hit_offset2[2];
                end else begin
                    ball_x <= dir_x ? ball_x + 7'd1 : ball_x - 7'd1;
                end
            end
        end
    end

    // No framebuffer, font ROM, division, multiplication or pixel registers.
    wire [6:0] cell_x = h[9:3];
    wire [5:0] cell_y = v[8:3];
    wire [5:0] paddle_offset1 = cell_y - p1_y;
    wire [5:0] paddle_offset2 = cell_y - p2_y;
    wire left_pixel  = (cell_x == 7'd3) && (paddle_offset1 < 6'd8);
    wire right_pixel = (cell_x == 7'd76) && (paddle_offset2 < 6'd8);
    wire ball_pixel = (cell_x == ball_x) && (cell_y == ball_y);
    wire net_pixel = (h[9:1] == 9'd160) && !v[4];
    wire r = visible && (ball_pixel || right_pixel);
    wire g = visible && (ball_pixel || left_pixel);
    wire b = visible && (ball_pixel || left_pixel || right_pixel);
    wire net = visible && net_pixel;
    // Tiny VGA: {HS, B0, G0, R0, VS, B1, G1, R1}.
    // Dim grey net; cyan left paddle; magenta right paddle; white ball.
    assign uo_out = {hsync, (b | net), (g | net), (r | net),
                     vsync, b, g, r};
    // Scores need physical outputs to remain observable after synthesis.
    assign uio_out = {score2, score1};
    assign uio_oe = 8'hff;
    wire _unused = &{1'b0, ui_in[7:5], uio_in};
endmodule
`default_nettype wire
