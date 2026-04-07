/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

 

module tt_um_lorenz_motion (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

 

    // =========================================================================
    // 1. VGA TIMING GENERATOR (640x480 @ 60Hz)
    // =========================================================================
    reg [9:0] hpos = 0;
    reg [9:0] vpos = 0;
    wire hsync, vsync, display_on;

 

    always @(posedge clk) begin
        if (~rst_n) begin
            hpos <= 0;
            vpos <= 0;
        end else begin
            if (hpos == 799) begin
                hpos <= 0;
                if (vpos == 524) vpos <= 0;
                else vpos <= vpos + 1;
            end else begin
                hpos <= hpos + 1;
            end
        end
    end

 

    assign hsync = ~(hpos >= 656 && hpos < 752);
    assign vsync = ~(vpos >= 490 && vpos < 492);
    assign display_on = (hpos < 640 && vpos < 480);

 

    // =========================================================================
    // 2. CHAOS ENGINE: LORENZ ATTRACTOR 
    // =========================================================================
    reg signed [31:0] x, y, z;

 

    localparam signed [63:0] RHO_64  = 64'sd29360128; // 28.0 in Q12.20
    localparam signed [63:0] BETA_64 = 64'sd2796203;  // 8/3 in Q12.20

 

    wire signed [63:0] x_64 = {{32{x[31]}}, x};
    wire signed [63:0] y_64 = {{32{y[31]}}, y};
    wire signed [63:0] z_64 = {{32{z[31]}}, z};

 

    wire signed [63:0] p_xy    = x_64 * y_64;
    wire signed [63:0] p_x_rho = x_64 * (RHO_64 - z_64);
    wire signed [63:0] p_z_b   = z_64 * BETA_64;

 

    wire signed [31:0] dx = (y - x) * 32'sd10;
    wire signed [31:0] dy = p_x_rho[51:20] - y;
    wire signed [31:0] dz = p_xy[51:20] - p_z_b[51:20];

 

    // --- EVEN SLOWER UPDATE SPEED ---
    // Increased from 14 bits to 15 bits. It now updates every 32,768 clock 
    // cycles, cutting the speed in half for a more graceful trace.
    reg [14:0] tick;
    always @(posedge clk) begin
        if (~rst_n) tick <= 0;
        else tick <= tick + 1;
    end
    wire update_pulse = (tick == 0);

 

    always @(posedge clk) begin
        if (~rst_n) begin
            x <= 32'sd1048576; // 1.0
            y <= 32'sd0; 
            z <= 32'sd0; 
        end else if (update_pulse) begin
            x <= x + (dx >>> 8); 
            y <= y + (dy >>> 8);
            z <= z + (dz >>> 8);
        end
    end

 

    // =========================================================================
    // 3. 3D TO 2D SCREEN PROJECTION & DISTANCE FIELD
    // =========================================================================
    wire signed [31:0] sx = 32'sd320 + (x >>> 17); 
    wire signed [31:0] sy = 32'sd440 - (z >>> 17);

 

    wire signed [31:0] shpos = {22'b0, hpos};
    wire signed [31:0] svpos = {22'b0, vpos};

 

    wire signed [31:0] d_x = shpos - sx;
    wire signed [31:0] d_y = svpos - sy;

    // Distance squared from the current pixel to the center of the ball
    wire signed [31:0] dist_sq = (d_x * d_x) + (d_y * d_y);

 

    // --- PROPER BALL SHADING ---
    // We break the ball into 3 concentric zones based on radius
    wire core  = (dist_sq < 32'sd16);  // Radius < 4 (Center)
    wire mid   = (dist_sq < 32'sd49);  // Radius < 7 (Middle)
    wire outer = (dist_sq < 32'sd100); // Radius < 10 (Edge)

 

    // =========================================================================
    // 4. COLOR ASSIGNMENT
    // =========================================================================
    wire grid = (hpos[5:0] == 0) || (vpos[5:0] == 0); 

    wire [1:0] r_base, g_base, b_base;

 

    // Gradient logic:
    // Core  = White (R:3, G:3, B:3)
    // Mid   = Orange (R:3, G:2, B:0)
    // Outer = Dark Red (R:2, G:0, B:0)
    // Grid  = Faint Blue (R:0, G:0, B:1)

    assign r_base = core ? 2'b11 : (mid ? 2'b11 : (outer ? 2'b10 : 2'b00));
    assign g_base = core ? 2'b11 : (mid ? 2'b10 : (outer ? 2'b00 : 2'b00));
    assign b_base = core ? 2'b11 : (mid ? 2'b00 : (outer ? 2'b00 : (grid ? 2'b01 : 2'b00)));

 

    wire [1:0] r_out = display_on ? r_base : 2'b00;
    wire [1:0] g_out = display_on ? g_base : 2'b00;
    wire [1:0] b_out = display_on ? b_base : 2'b00;

 

    assign uo_out[0] = r_out[1]; 
    assign uo_out[4] = r_out[0]; 
    assign uo_out[1] = g_out[1]; 
    assign uo_out[5] = g_out[0]; 
    assign uo_out[2] = b_out[1]; 
    assign uo_out[6] = b_out[0]; 
    assign uo_out[3] = vsync;
    assign uo_out[7] = hsync;

 

    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;
    wire _unused = &{ena, uio_in, ui_in, 1'b0};

 

endmodule
