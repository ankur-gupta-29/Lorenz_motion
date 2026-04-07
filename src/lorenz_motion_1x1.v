/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module tt_um_lorenz_motion(
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // =========================================================================
    // 1. VGA TIMING GENERATOR (640x480 @ 60Hz - 25MHz Clock Expected)
    // =========================================================================
    reg [9:0] hpos;
    reg [9:0] vpos;
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
    // 2. DIGITAL NOISE GENERATOR (16-bit LFSR)
    // =========================================================================
    reg [15:0] lfsr;
    wire feedback = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    always @(posedge clk) begin
        if (~rst_n) begin
            lfsr <= 16'hACE1; 
        end else begin
            lfsr <= {lfsr[14:0], feedback};
        end
    end

    wire signed [31:0] noise_x = {31'b0, lfsr[0]};
    wire signed [31:0] noise_y = {31'b0, lfsr[1]};
    wire signed [31:0] noise_z = {31'b0, lfsr[2]};

    // =========================================================================
    // 3. CHAOS ENGINE: 1x1 TILE AREA OPTIMIZED MATH
    // =========================================================================
    reg signed [31:0] x, y, z;

    // Extracted down to 12-bit slices to drastically reduce multiplier area
    wire signed [31:0] x_ext = {{20{x[31]}}, x[27:16]};
    wire signed [31:0] y_ext = {{20{y[31]}}, y[27:16]};
    wire signed [31:0] z_ext = {{20{z[31]}}, z[27:16]};

    // Constants scaled for the 12-bit Q12.16 slice format
    wire signed [31:0] RHO_32  = 32'sd448; // 28.0 * 16
    wire signed [31:0] BETA_32 = 32'sd42;  // 8/3  * 16

    // Smaller 12x12 = 24-bit physical multipliers
    wire signed [31:0] p_xy_32    = x_ext * y_ext;
    wire signed [31:0] p_x_rho_32 = x_ext * (RHO_32 - z_ext);
    wire signed [31:0] p_z_b_32   = z_ext * BETA_32;

    // Shift back up to standard Q12.20
    wire signed [31:0] p_xy_20    = p_xy_32 <<< 12;
    wire signed [31:0] p_x_rho_20 = p_x_rho_32 <<< 12;
    wire signed [31:0] p_z_b_20   = p_z_b_32 <<< 12;

    wire signed [31:0] y_minus_x = y - x;
    wire signed [31:0] dx = (y_minus_x <<< 3) + (y_minus_x <<< 1); 
    wire signed [31:0] dy = p_x_rho_20 - y;
    wire signed [31:0] dz = p_xy_20 - p_z_b_20;

    reg [14:0] tick;
    always @(posedge clk) begin
        if (~rst_n) tick <= 0;
        else tick <= tick + 1;
    end
    wire update_pulse = (tick == 0);

    // Screen projection
    wire signed [31:0] sx_signed = 32'sd320 + (x >>> 17); 
    wire signed [31:0] sy_signed = 32'sd440 - (z >>> 17); 
    
    wire [9:0] sx = (sx_signed < 0) ? 10'd0 : ((sx_signed > 639) ? 10'd639 : sx_signed[9:0]);
    wire [9:0] sy = (sy_signed < 0) ? 10'd0 : ((sy_signed > 479) ? 10'd479 : sy_signed[9:0]);

    // =========================================================================
    // 4. HISTORY BUFFER (Reduced to 4 Length to fit in 1 Tile)
    // =========================================================================
    localparam TRAIL_LEN = 4;
    reg [9:0] hist_x [0:TRAIL_LEN-1];
    reg [9:0] hist_y [0:TRAIL_LEN-1];
    integer i;

    always @(posedge clk) begin
        if (~rst_n) begin
            x <= 32'sd1048576; // 1.0 in Q12.20
            y <= 32'sd0; 
            z <= 32'sd0; 
            for (i = 0; i < TRAIL_LEN; i = i + 1) begin
                hist_x[i] <= 10'd800; 
                hist_y[i] <= 10'd800;
            end
        end else if (update_pulse) begin
            x <= x + (dx >>> 8) + noise_x; 
            y <= y + (dy >>> 8) + noise_y;
            z <= z + (dz >>> 8) + noise_z;
            
            for (i = TRAIL_LEN-1; i > 0; i = i - 1) begin
                hist_x[i] <= hist_x[i-1];
                hist_y[i] <= hist_y[i-1];
            end
            hist_x[0] <= sx;
            hist_y[0] <= sy;
        end
    end

    // =========================================================================
    // 5. DRAWING THE TAIL (Optimized for Logic Area)
    // =========================================================================
    reg in_trail;
    reg [1:0] trail_age;
    reg [9:0] diff_x, diff_y;
    integer j;

    always @* begin
        in_trail = 0;
        trail_age = 2'd3; 

        for (j = 0; j < TRAIL_LEN; j = j + 1) begin
            diff_x = (hpos > hist_x[j]) ? (hpos - hist_x[j]) : (hist_x[j] - hpos);
            diff_y = (vpos > hist_y[j]) ? (vpos - hist_y[j]) : (hist_y[j] - vpos);
            
            // AREA HACK: Use Bitwise OR instead of Addition
            if ((diff_x | diff_y) < 10'd4) begin
                in_trail = 1;
                trail_age = j[1:0];
            end
        end
    end

    wire [9:0] diff_head_x = (hpos > sx) ? (hpos - sx) : (sx - hpos);
    wire [9:0] diff_head_y = (vpos > sy) ? (vpos - sy) : (sy - vpos);
    wire is_head = ((diff_head_x | diff_head_y) < 10'd6);

    // =========================================================================
    // 6. COLOR ASSIGNMENT
    // =========================================================================
    wire grid = (hpos[5:0] == 0) || (vpos[5:0] == 0); 
    
    reg [1:0] r_base, g_base, b_base;

    always @* begin
        if (is_head) begin
            r_base = 2'b11; g_base = 2'b11; b_base = 2'b11;
        end else if (in_trail) begin
            if (trail_age < 2) begin
                r_base = 2'b11; g_base = 2'b10; b_base = 2'b00; 
            end else begin
                r_base = 2'b11; g_base = 2'b01; b_base = 2'b00; 
            end
        end else if (grid) begin
            r_base = 2'b00; g_base = 2'b00; b_base = 2'b01;
        end else begin
            r_base = 2'b00; g_base = 2'b00; b_base = 2'b00;
        end
    end

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
    assign uio_oe  = 8'b0;
    wire _unused = &{ena, uio_in, ui_in, 1'b0};

endmodule
