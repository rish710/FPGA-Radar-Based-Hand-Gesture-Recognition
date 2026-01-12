`timescale 1ns / 1ps

module batch_norm4 #(
    parameter DATA_WIDTH = 8,
    parameter CHANNELS   = 128,
    parameter HEIGHT     = 3,
    parameter WIDTH      = 4,
    parameter EPSILON    = 1
)(
    input  logic clk,
    input  logic rst_n,
    output logic done
);

    // ---------------------------
    // Derived constants
    // ---------------------------
    localparam int PIXELS_PER_CH = HEIGHT * WIDTH;          // 14 * 16 = 224
    localparam int TOTAL_PIXELS  = CHANNELS * PIXELS_PER_CH; // 14336
    localparam int ADDR_WIDTH    = 11;                      // Enough for 14336

    // ---------------------------
    // Address and counters
    // ---------------------------
    logic [ADDR_WIDTH-1:0] addr_in, addr_out;
    logic [15:0] pixel_count;
    logic [15:0] channel_count;

    // ---------------------------
    // BRAM control/data
    // ---------------------------
    logic ena_in, wea_in;
    logic ena_out, wea_out;
    logic signed [DATA_WIDTH-1:0] din_bram;
    logic signed [DATA_WIDTH-1:0] normalized_value;
    logic [DATA_WIDTH-1:0] dummy_out;

    // ---------------------------
    // FSM states
    // ---------------------------
    typedef enum logic [3:0] {
        IDLE,
        CALC_STATS,
        FINISH_STATS,
        START_CORDIC,
        WAIT_CORDIC,
        PREP_FIRST_PIXEL,
        START_DIV,
        WAIT_DIV,
        WRITE_OUTPUT,
        NEXT_PIXEL_OR_CH,
        DONE_STATE
    } state_t;

    state_t state, next_state;

    // ---------------------------
    // Accumulators and stats
    // ---------------------------
    logic signed [31:0] sum;
    logic signed [47:0] sum_sq;
    logic signed [DATA_WIDTH-1:0] mean;
    logic signed [DATA_WIDTH-1:0] variance;

    // ---------------------------
    // CORDIC sqrt interface
    // ---------------------------
    logic cordic_s_tvalid;
    logic [15:0] cordic_s_tdata;
    logic cordic_m_tvalid;
    logic [15:0] cordic_m_tdata;
    logic [15:0] sqrt_result;
    logic sqrt_load_en;

    // ---------------------------
    // Divider interface
    // ---------------------------
    logic div_s_dividend_tvalid;
    logic [15:0] div_s_dividend_tdata;
    logic div_s_divisor_tvalid;
    logic [15:0] div_s_divisor_tdata;
    logic div_m_tvalid;
    logic [31:0] div_m_tdata;
    logic [DATA_WIDTH-1:0] div_result;
    logic div_result_load_en;
    logic normalized_value_load_en;

    // ---------------------------
    // BRAM Instances
    // ---------------------------
    blk_mem_gen_27 input_batchnorm (
        .clka(clk),
        .ena(ena_in),
        .wea(wea_in),
        .addra(addr_in),
        .dina(16'b0),
        .douta(din_bram)
    );

    blk_mem_gen_28 output_batchnorm (
        .clka(clk),
        .ena(ena_out),
        .wea(wea_out),
        .addra(addr_out),
        .dina(normalized_value),
        .douta(dummy_out)
    );

    // FSM sequential
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // FSM combinational
    always_comb begin
        next_state = state;
        unique case (state)
            IDLE: next_state = CALC_STATS;
            CALC_STATS: if (pixel_count == PIXELS_PER_CH) next_state = FINISH_STATS;
            FINISH_STATS: next_state = START_CORDIC;
            START_CORDIC: next_state = WAIT_CORDIC;
            WAIT_CORDIC: if (cordic_m_tvalid) next_state = PREP_FIRST_PIXEL;
            PREP_FIRST_PIXEL: next_state = START_DIV;
            START_DIV: next_state = WAIT_DIV;
            WAIT_DIV: if (div_m_tvalid) next_state = WRITE_OUTPUT;
            WRITE_OUTPUT: next_state = NEXT_PIXEL_OR_CH;
            NEXT_PIXEL_OR_CH: begin
                if ((pixel_count == PIXELS_PER_CH-1) && (channel_count == CHANNELS-1))
                    next_state = DONE_STATE;
                else if (pixel_count == PIXELS_PER_CH-1)
                    next_state = CALC_STATS;
                else
                    next_state = START_DIV;
            end
            DONE_STATE: next_state = DONE_STATE;
        endcase
    end

    // Sequential operations
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_in <= '0; addr_out <= '0;
            pixel_count <= '0; channel_count <= '0;
            sum <= '0; sum_sq <= '0;
            mean <= '0; variance <= '0;
            done <= 1'b0; normalized_value <= '0;
            cordic_s_tvalid <= 1'b0; cordic_s_tdata <= '0;
            sqrt_result <= '0;
            div_s_dividend_tvalid <= 1'b0; div_s_dividend_tdata <= '0;
            div_s_divisor_tvalid <= 1'b0; div_s_divisor_tdata <= '0;
            div_result <= '0;
            ena_in <= 1'b0; wea_in <= 1'b0;
            ena_out <= 1'b0; wea_out <= 1'b0;
        end else begin
            done <= 1'b0;
            ena_in <= 1'b0; wea_in <= 1'b0;
            ena_out <= 1'b0; wea_out <= 1'b0;
            cordic_s_tvalid <= 1'b0;
            div_s_dividend_tvalid <= 1'b0;
            div_s_divisor_tvalid <= 1'b0;

            if (sqrt_load_en) sqrt_result <= cordic_m_tdata;
            if (div_result_load_en) div_result <= div_m_tdata[DATA_WIDTH-1:0];
            if (normalized_value_load_en) normalized_value <= div_result;

            unique case (state)
                IDLE: begin
                    addr_in <= channel_count * PIXELS_PER_CH;
                    addr_out <= channel_count * PIXELS_PER_CH;
                    pixel_count <= '0;
                    sum <= '0; sum_sq <= '0;
                    ena_in <= 1'b1;
                end
                CALC_STATS: begin
                    ena_in <= 1'b1;
                    sum <= sum + $signed(din_bram);
                    sum_sq <= sum_sq + $signed(din_bram) * $signed(din_bram);
                    if (pixel_count < PIXELS_PER_CH-1) begin
                        pixel_count <= pixel_count + 1;
                        addr_in <= addr_in + 1;
                    end else begin
                        pixel_count <= PIXELS_PER_CH;
                    end
                end
                FINISH_STATS: begin
                    mean <= sum / PIXELS_PER_CH;
                    variance <= (sum_sq / PIXELS_PER_CH) - (mean * mean);
                    pixel_count <= '0;
                    addr_in <= channel_count * PIXELS_PER_CH;
                    addr_out <= channel_count * PIXELS_PER_CH;
                end
                START_CORDIC: begin
                    cordic_s_tdata <= variance + EPSILON;
                    cordic_s_tvalid <= 1'b1;
                end
                PREP_FIRST_PIXEL: begin
                    ena_in <= 1'b1;
                end
                START_DIV: begin
                    ena_in <= 1'b1;
                    div_s_dividend_tdata <= $signed(din_bram) - $signed(mean);
                    div_s_dividend_tvalid <= 1'b1;
                    div_s_divisor_tdata <= sqrt_result;
                    div_s_divisor_tvalid <= 1'b1;
                end
                WRITE_OUTPUT: begin
                    ena_out <= 1'b1;
                    wea_out <= 1'b1;
                    if (pixel_count < PIXELS_PER_CH-1) begin
                        pixel_count <= pixel_count + 1;
                        addr_in <= addr_in + 1;
                        addr_out <= addr_out + 1;
                    end
                end
                NEXT_PIXEL_OR_CH: begin
                    if (pixel_count == PIXELS_PER_CH-1) begin
                        if (channel_count < CHANNELS-1) begin
                            channel_count <= channel_count + 1;
                            addr_in <= (channel_count+1)*PIXELS_PER_CH;
                            addr_out <= (channel_count+1)*PIXELS_PER_CH;
                            pixel_count <= '0;
                            sum <= '0; sum_sq <= '0;
                        end
                    end
                end
                DONE_STATE: done <= 1'b1;
            endcase
        end
    end

    // Enable logic
    always_comb begin
        sqrt_load_en = 1'b0;
        div_result_load_en = 1'b0;
        normalized_value_load_en = 1'b0;
        if (state == WAIT_CORDIC && cordic_m_tvalid)
            sqrt_load_en = 1'b1;
        if (state == WAIT_DIV && div_m_tvalid)
            div_result_load_en = 1'b1;
        if (state == WRITE_OUTPUT)
            normalized_value_load_en = 1'b1;
    end

    // CORDIC instance
    cordic_3 cordic_inst (
        .s_axis_cartesian_tvalid(cordic_s_tvalid),
        .s_axis_cartesian_tdata(cordic_s_tdata),
        .m_axis_dout_tvalid(cordic_m_tvalid),
        .m_axis_dout_tdata(cordic_m_tdata)
    );

    // Divider instance
    div_gen_3 div_inst (
        .aclk(clk),
        .s_axis_dividend_tvalid(div_s_dividend_tvalid),
        .s_axis_dividend_tdata(div_s_dividend_tdata),
        .s_axis_divisor_tvalid(div_s_divisor_tvalid),
        .s_axis_divisor_tdata(div_s_divisor_tdata),
        .m_axis_dout_tvalid(div_m_tvalid),
        .m_axis_dout_tdata(div_m_tdata)
    );

endmodule
