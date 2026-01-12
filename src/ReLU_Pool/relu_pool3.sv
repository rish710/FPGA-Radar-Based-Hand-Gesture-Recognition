`timescale 1ns/1ps

module relu_pool3 #(
    parameter DATA_WIDTH = 8,
    parameter CHANNELS   = 128,
    parameter IN_HEIGHT  = 7,
    parameter IN_WIDTH   = 8,
    parameter OUT_HEIGHT = 3,
    parameter OUT_WIDTH  = 4,

    parameter IN_ADDR_WIDTH  = 13,   // log2(CH*H*W)
    parameter OUT_ADDR_WIDTH = 11    // log2(CH*H/2*W/2)
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    output logic done
);

    // ----------------------------
    // Internal signals
    // ----------------------------
    logic [IN_ADDR_WIDTH-1:0]  in_addr;
    logic signed [DATA_WIDTH-1:0] in_dout;

    logic [OUT_ADDR_WIDTH-1:0] out_addr;
    logic signed [DATA_WIDTH-1:0] out_din;
    logic out_we;
    logic signed [DATA_WIDTH-1:0] dummy;

    // ----------------------------
    // FSM States
    // ----------------------------
    typedef enum logic [2:0] {
        IDLE,
        READ,
        WAIT,
        RELU,
        POOL_LOAD,
        POOL_CALC,
        WRITE,
        WRITE_DONE
    } state_t;

    state_t state, next_state;

    // ----------------------------
    // Registers
    // ----------------------------
    logic signed [DATA_WIDTH-1:0] relu_val;

    // Flattened pool registers to avoid set/reset conflict
    logic signed [DATA_WIDTH-1:0] pool00, pool01, pool10, pool11;
    logic signed [DATA_WIDTH-1:0] pool_max;

    // Counters
    integer cnt_c, cnt_h, cnt_w;
    integer pool_idx_h, pool_idx_w;

    // Address registers
    logic [IN_ADDR_WIDTH-1:0]  in_addr_reg;
    logic [OUT_ADDR_WIDTH-1:0] out_addr_reg;

    assign in_addr  = in_addr_reg;
    assign out_addr = out_addr_reg;

    // ----------------------------
    // FSM State Register
    // ----------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // ----------------------------
    // FSM Next-State Logic
    // ----------------------------
    always_comb begin
        next_state = state;
        case(state)
            IDLE:       if (start) next_state = READ;
            READ:       next_state = WAIT;
            WAIT:       next_state = RELU;
            RELU:       next_state = POOL_LOAD;
            POOL_LOAD:  if (pool_idx_h == 1 && pool_idx_w == 1) next_state = POOL_CALC;
                        else next_state = READ;
            POOL_CALC:  next_state = WRITE;
            WRITE:      next_state = WRITE_DONE;
            WRITE_DONE: if (cnt_c == CHANNELS-1 && cnt_h == OUT_HEIGHT-1 && cnt_w == OUT_WIDTH-1)
                            next_state = IDLE;
                        else
                            next_state = READ;
        endcase
    end

    // ----------------------------
    // FSM Outputs / Counters
    // ----------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all registers
            in_addr_reg  <= 0;
            out_addr_reg <= 0;
            out_din      <= 0;
            out_we       <= 0;
            relu_val     <= 0;
            pool_max     <= 0;

            pool00 <= 0; pool01 <= 0;
            pool10 <= 0; pool11 <= 0;

            cnt_c <= 0; cnt_h <= 0; cnt_w <= 0;
            pool_idx_h <= 0; pool_idx_w <= 0;
            done <= 0;
        end
        else begin
            case(state)
                IDLE: begin
                    out_we <= 0;
                    done   <= 0;
                    in_addr_reg  <= 0;
                    out_addr_reg <= 0;
                    pool_idx_h <= 0; pool_idx_w <= 0;
                end
                READ: begin
                    in_addr_reg <= (cnt_c * IN_HEIGHT * IN_WIDTH) +
                                   ((cnt_h*2 + pool_idx_h) * IN_WIDTH) +
                                   (cnt_w*2 + pool_idx_w);
                end
                WAIT: begin
                    // Wait for BRAM read
                end
                RELU: begin
                    relu_val <= (in_dout > 0) ? in_dout : 0;
                end
                POOL_LOAD: begin
                    // Load relu_val into flattened pool register
                    case ({pool_idx_h, pool_idx_w})
                        2'b00: pool00 <= relu_val;
                        2'b01: pool01 <= relu_val;
                        2'b10: pool10 <= relu_val;
                        2'b11: pool11 <= relu_val;
                    endcase

                    // Move inside 2x2 window
                    if (pool_idx_w < 1)
                        pool_idx_w <= pool_idx_w + 1;
                    else begin
                        pool_idx_w <= 0;
                        pool_idx_h <= pool_idx_h + 1;
                    end
                end
                POOL_CALC: begin
                    // Max pooling
                    pool_max <= pool00;
                    if (pool01 > pool_max) pool_max <= pool01;
                    if (pool10 > pool_max) pool_max <= pool10;
                    if (pool11 > pool_max) pool_max <= pool11;
                end
                WRITE: begin
                    out_din <= pool_max;
                    out_we  <= 1;
                end
                WRITE_DONE: begin
                    out_we  <= 0;
                    out_addr_reg <= out_addr_reg + 1;

                    // Update counters
                    if (cnt_w < OUT_WIDTH-1)
                        cnt_w <= cnt_w + 1;
                    else begin
                        cnt_w <= 0;
                        if (cnt_h < OUT_HEIGHT-1)
                            cnt_h <= cnt_h + 1;
                        else begin
                            cnt_h <= 0;
                            if (cnt_c < CHANNELS-1)
                                cnt_c <= cnt_c + 1;
                            else begin
                                cnt_c <= 0;
                                done <= 1;
                            end
                        end
                    end

                    // Reset pooling window indexes
                    pool_idx_h <= 0;
                    pool_idx_w <= 0;
                end
            endcase
        end
    end

    // ----------------------------
    // Input BRAM Instance
    // ----------------------------
    blk_mem_gen_23 input_bram (
        .clka(clk),
        .ena(1'b1),
        .wea(1'b0),
        .addra(in_addr),
        .dina({DATA_WIDTH{1'b0}}),
        .douta(in_dout)
    );

    // ----------------------------
    // Output BRAM Instance
    // ----------------------------
    blk_mem_gen_24 output_bram (
        .clka(clk),
        .ena(1'b1),
        .wea(out_we),
        .addra(out_addr),
        .dina(out_din),
        .douta(dummy)
    );

endmodule
