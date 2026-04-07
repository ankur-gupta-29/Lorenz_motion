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
    // 1. VGA TIMING GENERATOR 
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
    // 2. DIGITAL NOISE GENERATOR
    // =========================================================================
    reg [15:0] lfsr;
    wire feedback = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    always @(posedge clk) begin
        if (~rst_n) lfsr <= 16'hACE1; 
        else        lfsr <= {lfsr[14:0], feedback};
    end

    wire signed [31:0] noise_x = {31'b0, lfsr[0]};
    wire signed [31:0] noise_y = {31'b0, lfsr[1]};
    wire signed [31:0] noise_z = {31'b0, lfsr[2]};

    // =========================================================================
    // 3. CHAOS ENGINE: FIXED 1x1 STATE MACHINE 
    // =========================================================================
    reg signed [31:0] x, y, z;
    
    reg [14:0] tick;
    always @(posedge clk) begin
        if (~rst_n) tick <= 0;
        else tick <= tick + 1;
    end
    wire update_pulse = (tick == 0);

    // Slices for multiplication (Q8.4 Format = 12 bits)
    wire signed [11:0] x_slice = {x[31], x[26:16]};
    wire signed [11:0] y_slice = {y[31], y[26:16]};
    wire signed [11:0] z_slice = {z[31], z[26:16]};

    wire signed [11:0] RHO_12  = 12'sd448; // 28.0 * 16
    wire signed [11:0] BETA_12 = 12'sd42;  // 8/3  * 16

    // STATE MACHINE SETUP (Now 4 States to ensure math is stable)
    reg [1:0] state;
    localparam S_IDLE = 2'd0, S_MULT1 = 2'd1, S_MULT2 = 2'd2, S_MULT3 = 2'd3;

    // THE SINGLE SHARED MULTIPLIER 
    wire signed [11:0] mult_a = (state == S_MULT1) ? x_slice : 
                                (state == S_MULT2) ? x_slice : z_slice;
                                
    wire signed [11:0] mult_b = (state == S_MULT1) ? y_slice : 
                                (state == S_MULT2) ? (RHO_12 - z_slice) : BETA_12;

    wire signed [23:0] mult_out = mult_a * mult_b;

    // Registers to hold the intermediate math
    reg signed [23:0] p_xy_res;
    reg signed [23:0] p_x_rho_res;

    // Map the 24-bit results back to 32-bit Q12.20
    wire signed [31:0] p_xy_20    = {{8{p_xy_res[23]}}, p_xy_res} <<< 12;
    wire signed [31:0] p_x_rho_20 = {{8{p_x_rho_res[23]}}, p_x_rho_res} <<< 12;
    wire signed [31:0] p_z_b_20   = {{8{mult_out[23]}}, mult_out} <<< 12; 

    wire signed [31:0] y_minus_x = y - x;
    wire signed [31:0] dx = (y_minus_x <<< 3) + (y_minus_x <<< 1); 
    wire signed [31:0] dy = p_x_rho_20 - y;
    wire signed [31:0] dz = p_xy_20 - p_z_b_20;

    // Screen projection
    wire signed [31:0] sx_signed = 32'sd320 + (x >>> 17); 
    wire signed [31:0] sy_signed = 32'sd440 - (z >>> 17); 
    wire [9:0] sx = (sx_signed < 0) ? 10'd0 : ((sx_signed > 639) ? 10'd639 : sx_signed[9:0]);
    wire [9:0] sy = (sy_signed < 0) ? 10'd0 : ((sy_signed > 479) ? 10'd479 : sy_signed[9:0]);

    // =========================================================================
    // 4. HISTORY BUFFER & FSM EXECUTION
    // =========================================================================
    localparam TRAIL_LEN = 4;
    reg [9:0] hist_x [0:TRAIL_LEN-1];
    reg [9:0] hist_y [0:TRAIL_LEN-1];
    integer i;

    always @(posedge clk) begin
        if (~rst_n) begin
            x <= 32'sd1048576; // 1.0 
            y <= 32'sd0; 
            z <= 32'sd0; 
            state <= S_IDLE;
            for (i = 0; i < TRAIL_LEN; i = i + 1) begin
                hist_x[i] <= 10'd800; 
                hist_y[i] <= 10'd800;
            end
        end else begin
            // STATE MACHINE LOGIC
            if (state == S_IDLE) begin
                if (update_pulse) state <= S_MULT1;
            end 
            else if (state == S_MULT1) begin
                p_xy_res <= mult_out; // Save X*Y
                state <= S_MULT2;
            end 
            else if (state == S_MULT2) begin
                p_x_rho_res <= mult_out; // Save X*(RHO-Z)
                state <= S_MULT3;        // Advance to next multiplier stage
            end 
            else if (state == S_MULT3) begin
                // Now mult_out stably holds Z*BETA! We can safely update.
                x <= x + (dx >>> 8) + noise_x; 
                y <= y + (dy >>> 8) + noise_y;
                z <= z + (dz >>> 8) + noise_z;
                
                for (i = TRAIL_LEN-1; i > 0; i = i - 1) begin
                    hist_x[i] <= hist_x[i-1];
                    hist_y[i] <= hist_y[i-1];
                end
                hist_x[0] <= sx;
                hist_y[0] <= sy;

                state <= S_IDLE; // Done calculating, wait for next tick
            end
        end
    end

    // =========================================================================
    // 5. DRAWING THE TAIL 
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
