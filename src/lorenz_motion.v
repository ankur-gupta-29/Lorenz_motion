// /*
//  * Copyright (c) 2024 Your Name
//  * SPDX-License-Identifier: Apache-2.0
//  */
// `default_nettype none

// module tt_um_lorenz_motion(
//     input  wire [7:0] ui_in,
//     output wire [7:0] uo_out,
//     input  wire [7:0] uio_in,
//     output wire [7:0] uio_out,
//     output wire [7:0] uio_oe,
//     input  wire       ena,
//     input  wire       clk,
//     input  wire       rst_n
// );

//     // =========================================================================
//     // 1. VGA TIMING GENERATOR (640x480 @ 60Hz)
//     // =========================================================================
//     reg [9:0] hpos = 0;
//     reg [9:0] vpos = 0;
//     wire hsync, vsync, display_on;

//     always @(posedge clk) begin
//         if (~rst_n) begin
//             hpos <= 0;
//             vpos <= 0;
//         end else begin
//             if (hpos == 799) begin
//                 hpos <= 0;
//                 if (vpos == 524) vpos <= 0;
//                 else vpos <= vpos + 1;
//             end else begin
//                 hpos <= hpos + 1;
//             end
//         end
//     end

//     assign hsync = ~(hpos >= 656 && hpos < 752);
//     assign vsync = ~(vpos >= 490 && vpos < 492);
//     assign display_on = (hpos < 640 && vpos < 480);

//     // =========================================================================
//     // 2. CHAOS ENGINE: LORENZ ATTRACTOR 
//     // =========================================================================
//     reg signed [31:0] x, y, z;

//     localparam signed [63:0] RHO_64  = 64'sd29360128; // 28.0 in Q12.20
//     localparam signed [63:0] BETA_64 = 64'sd2796203;  // 8/3 in Q12.20

//     wire signed [63:0] x_64 = {{32{x[31]}}, x};
//     wire signed [63:0] y_64 = {{32{y[31]}}, y};
//     wire signed [63:0] z_64 = {{32{z[31]}}, z};

//     wire signed [63:0] p_xy    = x_64 * y_64;
//     wire signed [63:0] p_x_rho = x_64 * (RHO_64 - z_64);
//     wire signed [63:0] p_z_b   = z_64 * BETA_64;

//     wire signed [31:0] dx = (y - x) * 32'sd10;
//     wire signed [31:0] dy = p_x_rho[51:20] - y;
//     wire signed [31:0] dz = p_xy[51:20] - p_z_b[51:20];

//     // Update speed control
//     reg [14:0] tick;
//     always @(posedge clk) begin
//         if (~rst_n) tick <= 0;
//         else tick <= tick + 1;
//     end
//     wire update_pulse = (tick == 0);

//     // Calculate Screen Projection
//     wire signed [31:0] sx_signed = 32'sd320 + (x >>> 17); 
//     wire signed [31:0] sy_signed = 32'sd440 - (z >>> 17); 
    
//     // Clamp to screen bounds safely
//     wire [9:0] sx = (sx_signed < 0) ? 10'd0 : ((sx_signed > 639) ? 10'd639 : sx_signed[9:0]);
//     wire [9:0] sy = (sy_signed < 0) ? 10'd0 : ((sy_signed > 479) ? 10'd479 : sy_signed[9:0]);

//     // =========================================================================
//     // 3. HISTORY BUFFER (The "Comet Tail" Tracer)
//     // =========================================================================
//     localparam TRAIL_LEN = 32;
//     reg [9:0] hist_x [0:TRAIL_LEN-1];
//     reg [9:0] hist_y [0:TRAIL_LEN-1];
//     integer i;

//     always @(posedge clk) begin
//         if (~rst_n) begin
//             x <= 32'sd1048576; // 1.0
//             y <= 32'sd0; 
//             z <= 32'sd0; 
//             // Initialize history far off-screen so it doesn't draw at startup
//             for (i = 0; i < TRAIL_LEN; i = i + 1) begin
//                 hist_x[i] <= 10'd800; 
//                 hist_y[i] <= 10'd800;
//             end
//         end else if (update_pulse) begin
//             // 1. Update Math
//             x <= x + (dx >>> 8); 
//             y <= y + (dy >>> 8);
//             z <= z + (dz >>> 8);
            
//             // 2. Shift the Array
//             for (i = TRAIL_LEN-1; i > 0; i = i - 1) begin
//                 hist_x[i] <= hist_x[i-1];
//                 hist_y[i] <= hist_y[i-1];
//             end
//             // Insert newest coordinate
//             hist_x[0] <= sx;
//             hist_y[0] <= sy;
//         end
//     end

//     // =========================================================================
//     // 4. DRAWING THE TAIL (Distance checks)
//     // =========================================================================
//     reg in_trail;
//     reg [4:0] trail_age;
//     reg [9:0] diff_x, diff_y;
//     integer j;

//     always @* begin
//         in_trail = 0;
//         trail_age = 5'd31; 

//         for (j = 0; j < TRAIL_LEN; j = j + 1) begin
//             diff_x = (hpos > hist_x[j]) ? (hpos - hist_x[j]) : (hist_x[j] - hpos);
//             diff_y = (vpos > hist_y[j]) ? (vpos - hist_y[j]) : (hist_y[j] - vpos);
            
//             // If pixel is near this history point
//             if (diff_x + diff_y < 10'd4) begin
//                 in_trail = 1;
//                 trail_age = j[4:0];
//             end
//         end
//     end

//     // -> THIS WAS THE BUG! ADDED [9:0] WIDTH HERE <-
//     wire [9:0] diff_head_x = (hpos > sx) ? (hpos - sx) : (sx - hpos);
//     wire [9:0] diff_head_y = (vpos > sy) ? (vpos - sy) : (sy - vpos);
//     wire is_head = (diff_head_x + diff_head_y < 10'd6);

//     // =========================================================================
//     // 5. COLOR ASSIGNMENT
//     // =========================================================================
//     wire grid = (hpos[5:0] == 0) || (vpos[5:0] == 0); 
    
//     reg [1:0] r_base, g_base, b_base;

//     always @* begin
//         if (is_head) begin
//             // White hot center
//             r_base = 2'b11; g_base = 2'b11; b_base = 2'b11;
//         end else if (in_trail) begin
//             if (trail_age < 5) begin
//                 r_base = 2'b11; g_base = 2'b10; b_base = 2'b00; // Yellow
//             end else if (trail_age < 15) begin
//                 r_base = 2'b11; g_base = 2'b01; b_base = 2'b00; // Orange
//             end else begin
//                 r_base = 2'b10; g_base = 2'b00; b_base = 2'b00; // Dark Red
//             end
//         end else if (grid) begin
//             // Faint background grid
//             r_base = 2'b00; g_base = 2'b00; b_base = 2'b01;
//         end else begin
//             // Empty space
//             r_base = 2'b00; g_base = 2'b00; b_base = 2'b00;
//         end
//     end

//     // Blanking during sync
//     wire [1:0] r_out = display_on ? r_base : 2'b00;
//     wire [1:0] g_out = display_on ? g_base : 2'b00;
//     wire [1:0] b_out = display_on ? b_base : 2'b00;

//     assign uo_out[0] = r_out[1]; 
//     assign uo_out[4] = r_out[0]; 
//     assign uo_out[1] = g_out[1]; 
//     assign uo_out[5] = g_out[0]; 
//     assign uo_out[2] = b_out[1]; 
//     assign uo_out[6] = b_out[0]; 
//     assign uo_out[3] = vsync;
//     assign uo_out[7] = hsync;

//     assign uio_out = 8'b0;
//     assign uio_oe  = 8'b0;
//     wire _unused = &{ena, uio_in, ui_in, 1'b0};

// endmodule
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
    // 1. VGA TIMING GENERATOR (640x480 @ 60Hz)
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

    // Safe signed wires for noise injection
    wire signed [31:0] noise_x = {31'b0, lfsr[0]};
    wire signed [31:0] noise_y = {31'b0, lfsr[1]};
    wire signed [31:0] noise_z = {31'b0, lfsr[2]};

    // =========================================================================
    // 3. CHAOS ENGINE: BULLETPROOF MATH
    // =========================================================================
    reg signed [31:0] x, y, z;

    // Explicitly extend the 16-bit slices to 32-bit BEFORE multiplying
    // This prevents Verilog from truncating intermediate multiplier results
    wire signed [31:0] x_ext = {{16{x[27]}}, x[27:12]};
    wire signed [31:0] y_ext = {{16{y[27]}}, y[27:12]};
    wire signed [31:0] z_ext = {{16{z[27]}}, z[27:12]};

    wire signed [31:0] RHO_32  = 32'sd7168; // 28.0 * 256
    wire signed [31:0] BETA_32 = 32'sd683;  // 8/3  * 256

    // 32-bit multipliers
    wire signed [31:0] p_xy_32    = x_ext * y_ext;
    wire signed [31:0] p_x_rho_32 = x_ext * (RHO_32 - z_ext);
    wire signed [31:0] p_z_b_32   = z_ext * BETA_32;

    wire signed [31:0] p_xy_20    = p_xy_32 <<< 4;
    wire signed [31:0] p_x_rho_20 = p_x_rho_32 <<< 4;
    wire signed [31:0] p_z_b_20   = p_z_b_32 <<< 4;

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
    // 4. HISTORY BUFFER
    // =========================================================================
    localparam TRAIL_LEN = 16;
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
    // 5. DRAWING THE TAIL
    // =========================================================================
    reg in_trail;
    reg [3:0] trail_age;
    reg [9:0] diff_x, diff_y;
    integer j;

    always @* begin
        in_trail = 0;
        trail_age = 4'd15; 

        for (j = 0; j < TRAIL_LEN; j = j + 1) begin
            diff_x = (hpos > hist_x[j]) ? (hpos - hist_x[j]) : (hist_x[j] - hpos);
            diff_y = (vpos > hist_y[j]) ? (vpos - hist_y[j]) : (hist_y[j] - vpos);
            
            if (diff_x + diff_y < 10'd4) begin
                in_trail = 1;
                trail_age = j[3:0];
            end
        end
    end

    wire [9:0] diff_head_x = (hpos > sx) ? (hpos - sx) : (sx - hpos);
    wire [9:0] diff_head_y = (vpos > sy) ? (vpos - sy) : (sy - vpos);
    wire is_head = (diff_head_x + diff_head_y < 10'd6);

    // =========================================================================
    // 6. COLOR ASSIGNMENT
    // =========================================================================
    wire grid = (hpos[5:0] == 0) || (vpos[5:0] == 0); 
    
    reg [1:0] r_base, g_base, b_base;

    always @* begin
        if (is_head) begin
            r_base = 2'b11; g_base = 2'b11; b_base = 2'b11;
        end else if (in_trail) begin
            if (trail_age < 4) begin
                r_base = 2'b11; g_base = 2'b10; b_base = 2'b00; 
            end else if (trail_age < 10) begin
                r_base = 2'b11; g_base = 2'b01; b_base = 2'b00; 
            end else begin
                r_base = 2'b10; g_base = 2'b00; b_base = 2'b00; 
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
