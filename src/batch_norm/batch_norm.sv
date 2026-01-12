`timescale 1ns / 1ps

module batch_norm #(
    parameter DATA_WIDTH = 8,
    parameter CHANNELS   = 32,
    parameter HEIGHT     = 28,
    parameter WIDTH      = 32,
    parameter EPSILON    = 1
)(
    input  logic clk,
    input  logic rst_n,
    output logic done
);

    // ---------------------------
    // Derived constants
    // ---------------------------
    localparam int PIXELS_PER_CH = HEIGHT * WIDTH;     // 896 with defaults
    localparam int TOTAL_PIXELS  = CHANNELS * PIXELS_PER_CH; // 28672
    // Address width: 15 bits is enough for 28672 (< 32768)
    // (Your addr_in/addr_out are 15-bit already)

    // ---------------------------
    // Address/counters
    // ---------------------------
    logic [14:0] addr_in, addr_out;
    logic [15:0] pixel_count;         // 0..PIXELS_PER_CH-1
    logic [15:0] channel_count;       // 0..CHANNELS-1

    // ---------------------------
    // BRAM control/data
    // ---------------------------
    logic ena_in,  wea_in;
    logic ena_out, wea_out;

    logic signed [DATA_WIDTH-1:0] din_bram;
    logic signed [DATA_WIDTH-1:0] normalized_value;
    logic [DATA_WIDTH-1:0]        dummy_out;

    // ---------------------------
    // FSM states
    // ---------------------------
    typedef enum logic [3:0] {
        IDLE,
        CALC_STATS,
        FINISH_STATS,           // compute mean/variance registers
        START_CORDIC,           // send variance+epsilon
        WAIT_CORDIC,            // wait sqrt_result valid
        PREP_FIRST_PIXEL,       // prime first pixel of channel
        START_DIV,              // send (din - mean) / sqrt_result
        WAIT_DIV,               // wait divider result
        WRITE_OUTPUT,           // write result, bump addresses
        NEXT_PIXEL_OR_CH,       // loop pixels or next channel
        DONE_STATE
    } state_t;

    state_t state, next_state;

    // ---------------------------
    // Accumulators / stats
    // ---------------------------
    // sum: 32-bit is fine. sum_sq needs wider: 48 bits (worst-case safety).
    logic signed [31:0]  sum;
    logic signed [47:0]  sum_sq;   // widened to avoid overflow
    logic signed [DATA_WIDTH-1:0] mean;
    logic signed [DATA_WIDTH-1:0] variance;

    // ---------------------------
    // CORDIC (sqrt) AXIS signals
    // ---------------------------
    logic        cordic_s_tvalid;
    logic [15:0] cordic_s_tdata;            // feed variance + EPSILON
    logic        cordic_m_tvalid;
    logic [15:0] cordic_m_tdata;

    // Register to hold sqrt(variance+eps) for the whole channel
    logic [15:0] sqrt_result;
    logic        sqrt_load_en;              // clean enable-based update

    // ---------------------------
    // DIV_GEN AXIS signals
    // ---------------------------
    logic        div_s_dividend_tvalid;
    logic [15:0] div_s_dividend_tdata;      // (din - mean)
    logic        div_s_divisor_tvalid;
    logic [15:0] div_s_divisor_tdata;       // sqrt_result
    logic        div_m_tvalid;
    logic [31:0] div_m_tdata;

    // Divider result register (truncated to DATA_WIDTH)
    logic [DATA_WIDTH-1:0] div_result;
    logic                  div_result_load_en;

    // Output register enable
    logic normalized_value_load_en;

    // ---------------------------
    // BRAM instances
    // ---------------------------
    blk_mem_gen_6 input_batchnorm (
        .clka (clk),
        .ena  (ena_in),
        .wea  (wea_in),
        .addra(addr_in),
        .dina (16'b0),
        .douta(din_bram)
    );

    blk_mem_gen_7 output_batchnorm (
        .clka (clk),
        .ena  (ena_out),
        .wea  (wea_out),
        .addra(addr_out),
        .dina (normalized_value),
        .douta(dummy_out)
    );

    // ---------------------------
    // FSM sequential
    // ---------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    // ---------------------------
    // FSM combinational
    // ---------------------------
    always_comb begin
        next_state = state;
        unique case (state)
            IDLE:                 next_state = CALC_STATS;

            CALC_STATS:           next_state = (pixel_count == PIXELS_PER_CH) ? FINISH_STATS : CALC_STATS;

            FINISH_STATS:         next_state = START_CORDIC;

            START_CORDIC:         next_state = WAIT_CORDIC;

            WAIT_CORDIC:          next_state = (cordic_m_tvalid) ? PREP_FIRST_PIXEL : WAIT_CORDIC;

            PREP_FIRST_PIXEL:     next_state = START_DIV;

            START_DIV:            next_state = WAIT_DIV;

            WAIT_DIV:             next_state = (div_m_tvalid) ? WRITE_OUTPUT : WAIT_DIV;

            WRITE_OUTPUT:         next_state = NEXT_PIXEL_OR_CH;

            NEXT_PIXEL_OR_CH: begin
                if ( (pixel_count == PIXELS_PER_CH-1) && (channel_count == CHANNELS-1) )
                    next_state = DONE_STATE;
                else if (pixel_count == PIXELS_PER_CH-1) // next channel
                    next_state = CALC_STATS;
                else
                    next_state = START_DIV; // next pixel in same channel
            end

            DONE_STATE:           next_state = DONE_STATE;

            default:              next_state = IDLE;
        endcase
    end

    // ---------------------------
    // Main sequential logic (with clean enables)
    // ---------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // counters/addr
            addr_in       <= '0;
            addr_out      <= '0;
            pixel_count   <= '0;
            channel_count <= '0;

            // accumulators
            sum           <= '0;
            sum_sq        <= '0;
            mean          <= '0;
            variance      <= '0;

            // outputs / flags
            done          <= 1'b0;
            normalized_value <= '0;

            // IP I/F defaults
            cordic_s_tvalid        <= 1'b0;
            cordic_s_tdata         <= '0;
            sqrt_result            <= '0;

            div_s_dividend_tvalid  <= 1'b0;
            div_s_dividend_tdata   <= '0;
            div_s_divisor_tvalid   <= 1'b0;
            div_s_divisor_tdata    <= '0;
            div_result             <= '0;

            // bram ctl
            ena_in        <= 1'b0;  wea_in  <= 1'b0;
            ena_out       <= 1'b0;  wea_out <= 1'b0;

        end else begin
            // Defaults each cycle
            done                   <= 1'b0;

            // BRAM defaults (will be enabled in states)
            ena_in  <= 1'b0;  wea_in  <= 1'b0;
            ena_out <= 1'b0;  wea_out <= 1'b0;

            // AXIS defaults (pulse-when-used)
            cordic_s_tvalid       <= 1'b0;
            div_s_dividend_tvalid <= 1'b0;
            div_s_divisor_tvalid  <= 1'b0;

            // Hold registers by default; load only when enables asserted
            if (sqrt_load_en)        sqrt_result        <= cordic_m_tdata;
            if (div_result_load_en)  div_result         <= div_m_tdata[DATA_WIDTH-1:0];
            if (normalized_value_load_en) normalized_value <= div_result;

            unique case (state)

                IDLE: begin
                    // Reset per-channel pointers
                    addr_in     <= 15'(channel_count * PIXELS_PER_CH);
                    addr_out    <= 15'(channel_count * PIXELS_PER_CH);
                    pixel_count <= '0;

                    // Clear stats for new channel
                    sum         <= '0;
                    sum_sq      <= '0;

                    // Prime input BRAM read
                    ena_in      <= 1'b1;  // first read of CALC_STATS
                end

                CALC_STATS: begin
                    // Read data and accumulate
                    ena_in  <= 1'b1;
                    wea_in  <= 1'b0;

                    // Accumulate (registered input din_bram)
                    sum    <= sum    + $signed(din_bram);
                    sum_sq <= sum_sq + $signed(din_bram) * $signed(din_bram);

                    if (pixel_count < PIXELS_PER_CH-1) begin
                        pixel_count <= pixel_count + 1;
                        addr_in     <= addr_in + 1;
                    end else begin
                        // Finished scanning channel (pixel_count becomes 896 here)
                        pixel_count <= PIXELS_PER_CH; // sentinel to trigger FINISH_STATS
                        // keep addr_in at end; will be reset for normalize later
                    end
                end

                FINISH_STATS: begin
                    // Compute mean and variance (integer form)
                    // mean = sum / N
                    // var = (sum_sq / N) - (mean * mean)
                    mean     <= $signed(sum / PIXELS_PER_CH);
                    variance <= $signed( (sum_sq / PIXELS_PER_CH) - ($signed(sum / PIXELS_PER_CH) * $signed(sum / PIXELS_PER_CH)) );

                    // Reset for normalization phase of this channel
                    pixel_count <= '0;
                    addr_in     <= 15'(channel_count * PIXELS_PER_CH);
                    addr_out    <= 15'(channel_count * PIXELS_PER_CH);
                end

                START_CORDIC: begin
                    // Push variance+EPSILON into CORDIC (sqrt). One-cycle pulse.
                    cordic_s_tdata  <= $unsigned(variance + EPSILON);
                    cordic_s_tvalid <= 1'b1;
                end

                WAIT_CORDIC: begin
                    // Load sqrt_result when valid via enable below
                    // (No actions; enable set in combinational below)
                end

                PREP_FIRST_PIXEL: begin
                    // Enable BRAM read for first pixel in normalize loop
                    ena_in   <= 1'b1;
                end

                START_DIV: begin
                    // Feed divider: dividend=(din - mean), divisor = sqrt_result
                    ena_in   <= 1'b1; // keep reading input BRAM
                    div_s_dividend_tdata  <= $signed(din_bram) - $signed(mean);
                    div_s_dividend_tvalid <= 1'b1;

                    // common divisor for whole channel
                    div_s_divisor_tdata   <= sqrt_result;
                    div_s_divisor_tvalid  <= 1'b1;
                end

                WAIT_DIV: begin
                    // Wait for divider output; load via enable below
                end

                WRITE_OUTPUT: begin
                    // Write result to output BRAM
                    ena_out <= 1'b1;
                    wea_out <= 1'b1;

                    // Advance addresses/counters
                    if (pixel_count < PIXELS_PER_CH-1) begin
                        pixel_count <= pixel_count + 1;
                        addr_in     <= addr_in + 1;
                        addr_out    <= addr_out + 1;
                    end
                end

                NEXT_PIXEL_OR_CH: begin
                    if (pixel_count == PIXELS_PER_CH-1) begin
                        // Completed this channel
                        if (channel_count < CHANNELS-1) begin
                            channel_count <= channel_count + 1;

                            // Reset for next channel
                            addr_in     <= 15'((channel_count+1) * PIXELS_PER_CH);
                            addr_out    <= 15'((channel_count+1) * PIXELS_PER_CH);
                            pixel_count <= '0;

                            // Clear stats for next channel
                            sum         <= '0;
                            sum_sq      <= '0;
                        end
                    end
                end

                DONE_STATE: begin
                    done <= 1'b1;
                end

            endcase
        end
    end

    // ---------------------------
    // Enables (separate small comb logic)
    //  - Keeps registers from having competing set/reset priorities
    // ---------------------------
    always_comb begin
        // default disables
        sqrt_load_en               = 1'b0;
        div_result_load_en         = 1'b0;
        normalized_value_load_en   = 1'b0;

        // latch sqrt when valid
        if (state == WAIT_CORDIC && cordic_m_tvalid)
            sqrt_load_en = 1'b1;

        // latch divider result when valid
        if (state == WAIT_DIV && div_m_tvalid)
            div_result_load_en = 1'b1;

        // move latched div_result into output register right before write
        if (state == WRITE_OUTPUT)
            normalized_value_load_en = 1'b1;
    end

    // ---------------------------
    // CORDIC: sqrt(variance+EPSILON)
    // ---------------------------
    cordic_0 cordic_inst (
        .s_axis_cartesian_tvalid (cordic_s_tvalid),
        .s_axis_cartesian_tdata  (cordic_s_tdata),   // 16-bit input
        .m_axis_dout_tvalid      (cordic_m_tvalid),
        .m_axis_dout_tdata       (cordic_m_tdata)    // 16-bit sqrt output
    );

    // ---------------------------
    // Divider: (din - mean) / sqrt_result
    // ---------------------------
    div_gen_0 div_inst (
        .aclk                      (clk),
        .s_axis_dividend_tvalid    (div_s_dividend_tvalid),
        .s_axis_dividend_tdata     (div_s_dividend_tdata),  // 16-bit
        .s_axis_divisor_tvalid     (div_s_divisor_tvalid),
        .s_axis_divisor_tdata      (div_s_divisor_tdata),   // 16-bit
        .m_axis_dout_tvalid        (div_m_tvalid),
        .m_axis_dout_tdata         (div_m_tdata)            // 32-bit quotient
    );

endmodule
