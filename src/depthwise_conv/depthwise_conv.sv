`timescale 1ns / 1ns

module depthwise_conv #(
    parameter IN_CHANNELS = 192,
    parameter HEIGHT = 28,
    parameter WIDTH = 32,
    parameter KERNEL_SIZE = 3,
    parameter DATA_WIDTH = 8
)(
    input logic clk,
    input logic rst_n,
    input logic start,
    output logic done
);

    typedef enum logic [2:0] {
        IDLE, LOAD, WAIT, COMPUTE, BIAS_ADD, WRITE, DONE
    } state_t;

    state_t state, next_state;

    logic [$clog2(IN_CHANNELS)-1:0] c;
    logic [$clog2(HEIGHT)-1:0] h;
    logic [$clog2(WIDTH)-1:0] w;
    logic [$clog2(KERNEL_SIZE)-1:0] kh, kw;

    logic [15:0] sum;
    logic [15:0] prod;
    logic [15:0] bias_dout, input_dout, weight_dout;

    logic [17:0] input_addr, output_addr;
    logic [10:0] weight_addr;

    logic input_en, weight_en, output_en, output_we;
    logic [15:0] output_din;
    wire [15:0] output_dout;

    // FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE:       next_state = start ? LOAD : IDLE;
            LOAD:       next_state = WAIT;
            WAIT:       next_state = COMPUTE;
            COMPUTE:    next_state = (kh == KERNEL_SIZE-1 && kw == KERNEL_SIZE-1) ? BIAS_ADD : LOAD;
            BIAS_ADD:   next_state = WRITE;
            WRITE:      next_state = (c == IN_CHANNELS-1 && h == HEIGHT-1 && w == WIDTH-1) ? DONE : LOAD;
            DONE:       next_state = IDLE;
        endcase
    end

    // Index Calculation Functions
    function int input_idx(int c, int h, int w);
        return c * HEIGHT * WIDTH + h * WIDTH + w;
    endfunction

    function int weight_idx(int c, int kh, int kw);
        return c * KERNEL_SIZE * KERNEL_SIZE + kh * KERNEL_SIZE + kw;
    endfunction

    function int output_idx(int c, int h, int w);
        return c * HEIGHT * WIDTH + h * WIDTH + w;
    endfunction

    // Main Data Path and Control
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c <= 0; h <= 0; w <= 0; kh <= 0; kw <= 0;
            sum <= 0; prod <= 0; done <= 0;
            input_en <= 0; weight_en <= 0; output_en <= 0; output_we <= 0;
            input_addr <= 0; weight_addr <= 0; output_addr <= 0; output_din <= 0;
        end else begin
            done <= 0;
            input_en <= 0; weight_en <= 0; output_en <= 0; output_we <= 0;

            case (state)
                IDLE: begin
                    c <= 0; h <= 0; w <= 0; kh <= 0; kw <= 0;
                    sum <= 0; prod <= 0;
                end

                LOAD: begin
                    if ((h + kh - 1) >= 0 && (h + kh - 1) < HEIGHT &&
                        (w + kw - 1) >= 0 && (w + kw - 1) < WIDTH) begin
                        input_addr <= input_idx(c, h + kh - 1, w + kw - 1);
                        weight_addr <= weight_idx(c, kh, kw);
                        input_en <= 1;
                        weight_en <= 1;
                    end else begin
                        prod <= 0; // zero padding
                    end
                end

                WAIT: begin
                    prod <= input_dout * weight_dout;
                end

                COMPUTE: begin
                    sum <= sum + prod;
                    if (kw == KERNEL_SIZE - 1) begin
                        kw <= 0;
                        kh <= kh + 1;
                    end else begin
                        kw <= kw + 1;
                    end
                end

                BIAS_ADD: begin
                    sum <= sum + bias_dout;
                end

                WRITE: begin
                    output_addr <= output_idx(c, h, w);
                    output_din <= sum[15:0];
                    output_en <= 1;
                    output_we <= 1;

                    if (w == WIDTH-1) begin
                        w <= 0;
                        if (h == HEIGHT-1) begin
                            h <= 0;
                            c <= c + 1;
                        end else h <= h + 1;
                    end else w <= w + 1;

                    kh <= 0; kw <= 0; sum <= 0;
                end

                DONE: begin
                    done <= 1;
                end
            endcase
        end
    end

    // BRAM Instances
    blk_mem_gen_0 input_data_bram_inst (
        .clka(clk), .ena(input_en), .wea(1'b0),
        .addra(input_addr), .dina(8'b0), .douta(input_dout)
    );

    blk_mem_gen_1 weight_bram_inst (
        .clka(clk), .ena(weight_en), .wea(1'b0),
        .addra(weight_addr), .dina(8'b0), .douta(weight_dout)
    );

    blk_mem_gen_2 bias_bram_inst (
        .clka(clk), .ena(1'b1), .wea(1'b0),
        .addra(c), .dina(8'b0), .douta(bias_dout)
    );

    blk_mem_gen_3 output_bram_inst (
        .clka(clk), .ena(output_en), .wea(output_we),
        .addra(output_addr), .dina(output_din), .douta(output_dout)
    );

endmodule
