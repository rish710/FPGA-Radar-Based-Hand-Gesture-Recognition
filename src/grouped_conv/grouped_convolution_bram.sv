`timescale 1ns/1ps

module grouped_convolution_bram #(
    parameter OUT_CHANNELS = 128,
    parameter IN_CHANNELS_PER_GROUP = 8,
    parameter GROUPS = 16,
    parameter HEIGHT = 3,
    parameter WIDTH = 4
)(
    input  logic               clk,
    input  logic               reset,
    input  logic               start,
    output logic               done
);

    // Internal BRAM signals
    logic [31:0] bram_input_addr, bram_weight_addr, bram_bias_addr, bram_output_addr;
    logic signed [15:0] bram_input_data, bram_weight_data, bram_bias_data;
    logic signed [15:0] bram_output_data;
    logic bram_output_we;
    logic signed [15:0] bram_output_read_data;  // Capturing unused output to avoid optimization warnings

    // FSM State
    typedef enum logic [2:0] {IDLE, LOAD, COMPUTE, STORE, DONE} state_t;
    state_t state;

    // Counters and Control
    logic [6:0] out_channel;
    logic [1:0] row, col;
    logic [1:0] kr, kc;
    logic [3:0] ic;
    logic [3:0] group;
    logic [6:0] in_channel_base;
    logic signed [40:0] sum;
    logic compute_start;

    // Combinational helpers
    logic [6:0] group_calc;
    logic [6:0] in_channel_base_calc;
    logic signed [31:0] sum_next;

    assign group_calc = out_channel / (OUT_CHANNELS / GROUPS);
    assign in_channel_base_calc = group_calc * IN_CHANNELS_PER_GROUP;
    assign bram_input_addr  = (in_channel_base + ic) * HEIGHT * WIDTH + (row + kr - 1) * WIDTH + (col + kc - 1);
    assign bram_weight_addr = out_channel * IN_CHANNELS_PER_GROUP * 9 + ic * 9 + kr * 3 + kc;
    assign bram_bias_addr   = out_channel;
    assign bram_output_addr = out_channel * HEIGHT * WIDTH + row * WIDTH + col;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state           <= IDLE;
            done            <= 0;
            out_channel     <= 0;
            row             <= 0;
            col             <= 0;
            kr              <= 0;
            kc              <= 0;
            ic              <= 0;
            sum             <= 0;
            bram_output_we  <= 0;
            in_channel_base <= 0;
            compute_start   <= 0;
            bram_output_data <= 0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 0;
                    bram_output_we <= 0;
                    if (start) begin
                        out_channel <= 0;
                        row <= 0;
                        col <= 0;
                        state <= LOAD;
                    end
                end

                LOAD: begin
                    in_channel_base <= in_channel_base_calc;
                    kr <= 0;
                    kc <= 0;
                    ic <= 0;
                    sum <= 0;
                    compute_start <= 1;
                    state <= COMPUTE;
                end

                COMPUTE: begin
                    logic signed [31:0] sum_temp = sum;
                    int r_i = row + kr - 1;
                    int c_i = col + kc - 1;

                    if (compute_start) begin
                        compute_start <= 0;
                    end else begin
                        if (r_i >= 0 && r_i < HEIGHT && c_i >= 0 && c_i < WIDTH) begin
                            sum_temp = sum_temp + $signed(bram_input_data) * $signed(bram_weight_data);
                        end

                        if (ic < IN_CHANNELS_PER_GROUP - 1) begin
                            ic <= ic + 1;
                        end else if (kc < 2) begin
                            ic <= 0;
                            kc <= kc + 1;
                        end else if (kr < 2) begin
                            ic <= 0;
                            kc <= 0;
                            kr <= kr + 1;
                        end else begin
                            sum <= sum_temp;
                            state <= STORE;
                        end

                        sum <= sum_temp;
                    end
                end

                STORE: begin
                    sum <= sum + $signed(bram_bias_data);
                    bram_output_data <= sum[15:0];
                    bram_output_we <= 1;

                    if (col < WIDTH - 1) begin
                        col <= col + 1;
                        state <= LOAD;
                    end else if (row < HEIGHT - 1) begin
                        col <= 0;
                        row <= row + 1;
                        state <= LOAD;
                    end else if (out_channel < OUT_CHANNELS - 1) begin
                        col <= 0;
                        row <= 0;
                        out_channel <= out_channel + 1;
                        state <= LOAD;
                    end else begin
                        state <= DONE;
                    end

                    bram_output_we <= 0;
                end

                DONE: begin
                    done <= 1;
                    bram_output_we <= 0;
                end

            endcase
        end
    end

    // BRAM Instantiations
    blk_mem_gen_24 input_bram (
        .clka(clk),
        .ena(1'b1),
        .wea(1'b0),
        .addra(bram_input_addr[10:0]),
        .dina(16'b0),
        .douta(bram_input_data)
    );

    blk_mem_gen_25 weight_bram (
        .clka(clk),
        .ena(1'b1),
        .wea(1'b0),
        .addra(bram_weight_addr[13:0]),
        .dina(16'b0),
        .douta(bram_weight_data)
    );

    blk_mem_gen_26 bias_bram (
        .clka(clk),
        .ena(1'b1),
        .wea(1'b0),
        .addra(bram_bias_addr[6:0]),
        .dina(16'b0),
        .douta(bram_bias_data)
    );

    blk_mem_gen_27 output_bram (
        .clka(clk),
        .ena(1'b1),
        .wea(bram_output_we),
        .addra(bram_output_addr[10:0]),
        .dina(bram_output_data),
        .douta(bram_output_read_data)
    );

endmodule
