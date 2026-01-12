`timescale 1ns / 1ps

// ===============================================================
// Top wrapper that wires BRAMs to the pointwise logic FSM
// ===============================================================
module pointwise_conv3 #(
    parameter int IN_CHANNELS  = 64,
    parameter int OUT_CHANNELS = 128,
    parameter int HEIGHT       = 7,
    parameter int WIDTH        = 8,
    parameter int DATA_WIDTH   = 8
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire ena,
    output wire done
);
    // ---------- Derived sizes ----------
    localparam int PIXELS_PER_CH     = HEIGHT * WIDTH;                 // 64*7*8=3584
    localparam int IN_TOTAL_ELEMS    = IN_CHANNELS  * PIXELS_PER_CH;   // 64*3584 = 229,376 (not used as a single BRAM here)
    localparam int OUT_TOTAL_ELEMS   = OUT_CHANNELS * PIXELS_PER_CH;   // 128*3584 = 458,752

    // Address widths
    localparam int DEPTH_ADDR_W   = $clog2(IN_CHANNELS * PIXELS_PER_CH);   // 64*56 = 3584 -> 12 bits
    localparam int WEIGHT_ADDR_W  = $clog2(IN_CHANNELS * OUT_CHANNELS);    // 64*128 = 8192 -> 13 bits
    localparam int BIAS_ADDR_W    = $clog2(OUT_CHANNELS);                  // 128 -> 7 bits
    localparam int OUT_ADDR_W     = $clog2(OUT_CHANNELS * PIXELS_PER_CH);  // 128*56 = 7168 -> 13 bits

    // ---------- BRAM wiring ----------
    wire [DATA_WIDTH-1:0] depthwise_bram_data;
    wire [DEPTH_ADDR_W-1:0] depthwise_bram_addr;

    wire [DATA_WIDTH-1:0] weights_bram_data;
    wire [WEIGHT_ADDR_W-1:0] weights_bram_addr;

    wire [DATA_WIDTH-1:0] bias_bram_data;
    wire [BIAS_ADDR_W-1:0] bias_bram_addr;

    wire [DATA_WIDTH-1:0] pointwise_bram_data;
    wire [OUT_ADDR_W-1:0] pointwise_bram_addr;
    wire                  pointwise_bram_we;
    wire [DATA_WIDTH-1:0] pointwise_bram_dout;

    // ---------- BRAM instances (names kept from your snippet) ----------
    // Depthwise feature map (read-only)
    blk_mem_gen_19 depthwise_output (
        .clka (clk),
        .ena  (ena),
        .wea  (1'b0),
        .addra(depthwise_bram_addr),
        .dina ('0),
        .douta(depthwise_bram_data)
    );

    // Pointwise weights (read-only)
    blk_mem_gen_20 pointwise_weights (
        .clka (clk),
        .ena  (ena),
        .wea  (1'b0),
        .addra(weights_bram_addr),
        .dina ('0),
        .douta(weights_bram_data)
    );

    // Biases (read-only)
    blk_mem_gen_21 pointwise_biases (
        .clka (clk),
        .ena  (ena),
        .wea  (1'b0),
        .addra(bias_bram_addr),
        .dina ('0),
        .douta(bias_bram_data)
    );

    // Output feature map (write)
    blk_mem_gen_22 pointwise_output_bram (
        .clka (clk),
        .ena  (ena),
        .wea  (pointwise_bram_we),       // 1-bit write enable is fine if IP is configured to 1 bit; otherwise replicate to byte lanes
        .addra(pointwise_bram_addr),
        .dina (pointwise_bram_data),
        .douta(pointwise_bram_dout)
    );

    // ---------- Logic FSM ----------
    pointwise_conv_logic3 #(
        .IN_CHANNELS (IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .HEIGHT      (HEIGHT),
        .WIDTH       (WIDTH),
        .DATA_WIDTH  (DATA_WIDTH)
    ) logic_inst (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .start                 (start),

        .depthwise_bram_data   (depthwise_bram_data),
        .depthwise_bram_addr   (depthwise_bram_addr),

        .weights_bram_data     (weights_bram_data),
        .weights_bram_addr     (weights_bram_addr),

        .bias_bram_data        (bias_bram_data),
        .bias_bram_addr        (bias_bram_addr),

        .pointwise_bram_data   (pointwise_bram_data),
        .pointwise_bram_addr   (pointwise_bram_addr),
        .pointwise_bram_we     (pointwise_bram_we),

        .done                  (done)
    );

endmodule


// ===============================================================
// Pointwise conv FSM with 1-cycle BRAM latency handling
// y[out_c, r, c] = bias[out_c] + sum_{in_c} depth[in_c, r, c] * W[out_c, in_c]
// ===============================================================
module pointwise_conv_logic3 #(
    parameter int IN_CHANNELS  = 64,
    parameter int OUT_CHANNELS = 128,
    parameter int HEIGHT       = 7,
    parameter int WIDTH        = 8,
    parameter int DATA_WIDTH   = 16
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,

    // Depthwise feature map BRAM (read-only)
    input  wire [DATA_WIDTH-1:0] depthwise_bram_data,
    output reg  [$clog2(IN_CHANNELS*HEIGHT*WIDTH)-1:0] depthwise_bram_addr,

    // Weights BRAM (read-only)
    input  wire [DATA_WIDTH-1:0] weights_bram_data,
    output reg  [$clog2(IN_CHANNELS*OUT_CHANNELS)-1:0] weights_bram_addr,

    // Bias BRAM (read-only)
    input  wire [DATA_WIDTH-1:0] bias_bram_data,
    output reg  [$clog2(OUT_CHANNELS)-1:0]            bias_bram_addr,

    // Output BRAM (write)
    output reg  [DATA_WIDTH-1:0] pointwise_bram_data,
    output reg  [$clog2(OUT_CHANNELS*HEIGHT*WIDTH)-1:0] pointwise_bram_addr,
    output reg  pointwise_bram_we,

    output reg  done
);
    // ---------- Derived ----------
    localparam int PIXELS_PER_CH = HEIGHT * WIDTH;

    // Loop counters
    reg [$clog2(OUT_CHANNELS)-1:0] out_c;
    reg [$clog2(HEIGHT)-1:0]       row;
    reg [$clog2(WIDTH)-1:0]        col;

    // Pipeline counters for BRAM latency handling
    reg [$clog2(IN_CHANNELS):0] issue_cnt;   // how many (in_c) requests issued
    reg [$clog2(IN_CHANNELS):0] accum_cnt;   // how many MACs completed
    reg                         data_valid;  // becomes 1 once first data pair is latched

    // Latched data for MAC
    reg signed [DATA_WIDTH-1:0] depth_d_r;
    reg signed [DATA_WIDTH-1:0] weight_d_r;

    // Accumulator (wider than 16x16 MAC; 48 bits is safe)
    reg signed [47:0] acc;

    // FSM
    typedef enum logic [2:0] {
        S_IDLE,
        S_LOAD_BIAS,      // set bias address
        S_WAIT_BIAS,      // wait 1 cycle for bias_dout
        S_COMPUTE,        // pipeline issue + accumulate
        S_WRITE,          // write result
        S_NEXT            // advance col/row/out_c
    } state_t;

    state_t state, next_state;

    // ---------- Helpers: flattened address calculations ----------
    function automatic [$clog2(IN_CHANNELS*HEIGHT*WIDTH)-1:0]
    depth_addr(input int unsigned ic, input int unsigned r, input int unsigned c);
        depth_addr = ic * PIXELS_PER_CH + r * WIDTH + c;
    endfunction

    function automatic [$clog2(IN_CHANNELS*OUT_CHANNELS)-1:0]
    weight_addr(input int unsigned oc, input int unsigned ic);
        weight_addr = oc * IN_CHANNELS + ic;
    endfunction

    function automatic [$clog2(OUT_CHANNELS*HEIGHT*WIDTH)-1:0]
    out_addr(input int unsigned oc, input int unsigned r, input int unsigned c);
        out_addr = oc * PIXELS_PER_CH + r * WIDTH + c;
    endfunction

    // ---------- FSM seq ----------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // ---------- FSM comb ----------
    always_comb begin
        next_state = state;
        unique case (state)
            S_IDLE:       next_state = (start ? S_LOAD_BIAS : S_IDLE);
            S_LOAD_BIAS:  next_state = S_WAIT_BIAS;
            S_WAIT_BIAS:  next_state = S_COMPUTE;
            S_COMPUTE:    next_state = (accum_cnt == IN_CHANNELS) ? S_WRITE : S_COMPUTE;
            S_WRITE:      next_state = S_NEXT;
            S_NEXT:       next_state = S_LOAD_BIAS;  // unless we're done (handled in seq)
            default:      next_state = S_IDLE;
        endcase
    end

    // ---------- Datapath ----------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // loops
            out_c <= '0; row <= '0; col <= '0;

            // pipeline
            issue_cnt  <= '0;
            accum_cnt  <= '0;
            data_valid <= 1'b0;
            depth_d_r  <= '0;
            weight_d_r <= '0;

            // acc/result
            acc                <= '0;
            pointwise_bram_data<= '0;
            pointwise_bram_addr<= '0;
            pointwise_bram_we  <= 1'b0;

            // BRAM addresses
            depthwise_bram_addr <= '0;
            weights_bram_addr   <= '0;
            bias_bram_addr      <= '0;

            done <= 1'b0;

        end else begin
            pointwise_bram_we <= 1'b0; // default

            unique case (state)

                // ----- Wait for start -----
                S_IDLE: begin
                    done <= 1'b0;
                    // keep counters zeroed or as-is until start
                end

                // ----- Set bias addr for this output channel -----
                S_LOAD_BIAS: begin
                    bias_bram_addr <= out_c;
                end

                // ----- Bias available next cycle; prime compute -----
                S_WAIT_BIAS: begin
                    // Initialize per-pixel accumulation with bias
                    acc        <= $signed({{(48-DATA_WIDTH){bias_bram_data[DATA_WIDTH-1]}}, bias_bram_data});
                    // Reset pipeline counters and valid flag
                    issue_cnt  <= '0;
                    accum_cnt  <= '0;
                    data_valid <= 1'b0;

                    // Issue first pair (in_c = 0)
                    depthwise_bram_addr <= depth_addr(0, row, col);
                    weights_bram_addr   <= weight_addr(out_c, 0);
                    issue_cnt           <= 1; // we've issued 1 request
                end

                // ----- Overlapped issue + accumulate (handles 1-cycle BRAM latency) -----
                S_COMPUTE: begin
                    // 1) Accumulate using last cycle's latched pair (if valid)
                    if (data_valid) begin
                        acc       <= acc + $signed(depth_d_r) * $signed(weight_d_r);
                        accum_cnt <= accum_cnt + 1;
                    end

                    // 2) Latch the current BRAM outputs for use in next cycle
                    depth_d_r  <= $signed(depthwise_bram_data);
                    weight_d_r <= $signed(weights_bram_data);
                    data_valid <= (issue_cnt != 0); // becomes 1 once at least one request was issued

                    // 3) Issue next addresses if any left
                    if (issue_cnt < IN_CHANNELS) begin
                        depthwise_bram_addr <= depth_addr(issue_cnt, row, col);
                        weights_bram_addr   <= weight_addr(out_c, issue_cnt);
                        issue_cnt           <= issue_cnt + 1;
                    end
                end

                // ----- Write accumulated result -----
                S_WRITE: begin
                    // One more accumulate is still pending (for the last issued pair):
                    // We reach S_WRITE only when accum_cnt == IN_CHANNELS,
                    // which means the last MAC was already consumed.
                    // Truncate/saturate as needed; here simple truncate to DATA_WIDTH.
                    pointwise_bram_data <= acc[DATA_WIDTH-1:0];
                    pointwise_bram_addr <= out_addr(out_c, row, col);
                    pointwise_bram_we   <= 1'b1;
                end

                // ----- Move to next pixel/channel; set 'done' at the very end -----
                S_NEXT: begin
                    // Advance col, row, out_c
                    if (col < WIDTH-1) begin
                        col <= col + 1;
                    end else if (row < HEIGHT-1) begin
                        col <= '0;
                        row <= row + 1;
                    end else if (out_c < OUT_CHANNELS-1) begin
                        col <= '0;
                        row <= '0;
                        out_c <= out_c + 1;
                    end else begin
                        // Completed all outputs
                        done <= 1'b1;
                    end
                end

            endcase
        end
    end

endmodule
