`timescale 1ns / 1ps

module pointwise_conv2 #(
    parameter IN_CHANNELS = 32,
    parameter OUT_CHANNELS = 64,
    parameter HEIGHT = 14,
    parameter WIDTH = 16,
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 13      // updated
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire ena,

    output wire done
);

    wire [DATA_WIDTH-1:0] depthwise_bram_data;
    wire [ADDR_WIDTH-1:0] depthwise_bram_addr;

    wire [DATA_WIDTH-1:0] weights_bram_data;
    wire [10:0] weights_bram_addr;

    wire [DATA_WIDTH-1:0] bias_bram_data;
    wire [5:0] bias_bram_addr;

    wire [DATA_WIDTH-1:0] pointwise_bram_data;
    wire [13:0] pointwise_bram_addr; // 14 bits to cover 64*14*16=14336
    wire pointwise_bram_we;
    wire [DATA_WIDTH-1:0] output_dout;

    blk_mem_gen_11 depthwise_output (
        .clka(clk),
        .ena(ena),
        .wea(1'b0),
        .addra(depthwise_bram_addr),
        .dina(16'b0),
        .douta(depthwise_bram_data)
    );

    blk_mem_gen_12 pointwise_weights (
        .clka(clk),
        .ena(ena),
        .wea(1'b0),
        .addra(weights_bram_addr),
        .dina(16'b0),
        .douta(weights_bram_data)
    );

    blk_mem_gen_13 pointwise_biases (
    .clka(clk),                     // 1-bit clock
    .ena(ena),                       // 1-bit enable
    .wea(1'b0),                      // 1-bit write enable
    .addra(bias_bram_addr),          // 6-bit address (log2(OUT_CHANNELS=64) = 6)
    .dina(16'b0),                    // 16-bit input data
    .douta(bias_bram_data)           // 16-bit output data
);


   blk_mem_gen_14 pointwise_output_bram (
    .clka(clk),                     // 1-bit clock
    .ena(ena),                       // 1-bit enable
    .wea(pointwise_bram_we),         // 1-bit write enable
    .addra(pointwise_bram_addr),     // 14-bit address (to cover 64*14*16=14336 locations)
    .dina(pointwise_bram_data),      // 16-bit input data
    .douta(output_dout)              // 16-bit output data
);


    pointwise_conv_logic2 #(
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .HEIGHT(HEIGHT),
        .WIDTH(WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) logic_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .depthwise_bram_data(depthwise_bram_data),
        .depthwise_bram_addr(depthwise_bram_addr),
        .weights_bram_data(weights_bram_data),
        .weights_bram_addr(weights_bram_addr),
        .bias_bram_data(bias_bram_data),
        .bias_bram_addr(bias_bram_addr),
        .pointwise_bram_data(pointwise_bram_data),
        .pointwise_bram_addr(pointwise_bram_addr),
        .pointwise_bram_we(pointwise_bram_we),
        .done(done)
    );

endmodule

//===============================
// Pointwise Convolution Logic
//===============================
module pointwise_conv_logic2 #(
    parameter IN_CHANNELS = 32,
    parameter OUT_CHANNELS = 64,
    parameter HEIGHT = 14,
    parameter WIDTH = 16,
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 13
)(
    input wire clk,
    input wire rst_n,
    input wire start,

    input wire [DATA_WIDTH-1:0] depthwise_bram_data,
    output reg [ADDR_WIDTH-1:0] depthwise_bram_addr,

    input wire [DATA_WIDTH-1:0] weights_bram_data,
    output reg [10:0] weights_bram_addr,

    input wire [DATA_WIDTH-1:0] bias_bram_data,
    output reg [5:0] bias_bram_addr,

    output reg [DATA_WIDTH-1:0] pointwise_bram_data,
    output reg [13:0] pointwise_bram_addr,
    output reg pointwise_bram_we,
    output reg done
);

    typedef enum logic [1:0] {
        IDLE = 2'b00,
        LOAD = 2'b01,
        WAIT_BIAS = 2'b10,
        COMPUTE = 2'b11
    } state_t;

    state_t state;

    integer out_c, row, col, in_c;
    reg [31:0] acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 0;
            out_c <= 0;
            row <= 0;
            col <= 0;
            in_c <= 0;
            depthwise_bram_addr <= 0;
            weights_bram_addr <= 0;
            bias_bram_addr <= 0;
            pointwise_bram_addr <= 0;
            pointwise_bram_we <= 0;
            acc <= 0;
            pointwise_bram_data <= 0;
        end else begin
            pointwise_bram_we <= 0;
            case (state)
                IDLE: begin
                    done <= 0;
                    if (start) begin
                        out_c <= 0;
                        row <= 0;
                        col <= 0;
                        in_c <= 0;
                        acc <= 0;
                        bias_bram_addr <= 0;
                        state <= LOAD;
                    end
                end
                LOAD: begin
                    bias_bram_addr <= out_c;
                    state <= WAIT_BIAS;
                end
                WAIT_BIAS: begin
                    acc <= 0;
                    in_c <= 0;
                    state <= COMPUTE;
                end
                COMPUTE: begin
                    if (in_c < IN_CHANNELS) begin
                        depthwise_bram_addr <= in_c * HEIGHT * WIDTH + row * WIDTH + col;
                        weights_bram_addr <= out_c * IN_CHANNELS + in_c;
                        acc <= acc + depthwise_bram_data * weights_bram_data;
                        in_c <= in_c + 1;
                    end else begin
                        acc <= acc + bias_bram_data;
                        pointwise_bram_data <= acc[DATA_WIDTH-1:0];
                        pointwise_bram_addr <= out_c * HEIGHT * WIDTH + row * WIDTH + col;
                        pointwise_bram_we <= 1;
                        in_c <= 0;
                        acc <= 0;

                        if (col < WIDTH - 1) col <= col + 1;
                        else if (row < HEIGHT - 1) begin
                            col <= 0; row <= row + 1;
                        end else if (out_c < OUT_CHANNELS - 1) begin
                            col <= 0; row <= 0; out_c <= out_c + 1; state <= LOAD;
                        end else begin
                            state <= IDLE; done <= 1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
