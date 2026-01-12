`timescale 1ns/1ps

module fc2_layer_bram #(
    parameter int DATA_W = 8,
    parameter int N_IN   = 128,
    parameter int N_OUT  = 5
)(
    input  wire                   clk,
    input  wire                   reset,
    input  wire                   start,
    output logic                  done
);

    // State machine
    typedef enum logic [2:0] {
        S_IDLE, S_PREP, S_MAC, S_NEXT_OUT, S_WRITE, S_DONE
    } state_t;
    state_t state, next_state;

    logic [$clog2(N_IN)-1:0]     in_idx;
    logic [$clog2(N_OUT)-1:0]    out_idx;
    logic [DATA_W-1:0]           input_val, weight_val, bias_val;
    logic signed [DATA_W+8:0]    acc;
    logic [DATA_W-1:0]           out_val;
    logic [$clog2(N_IN*N_OUT)-1:0] weight_addr;
    logic [DATA_W-1:0] out_readback;
    
    // Memory control signals
    logic bram_en;
    
    // Address calculation
    assign weight_addr = out_idx * N_IN + in_idx;
    assign out_val = acc[DATA_W-1:0];  // No ReLU for final layer

    // FC2 Input BRAM (blk_mem_gen_3) - SAME as FC1 output BRAM
    blk_mem_gen_32 fc2_input_bram (
        .clka(clk),
        .ena(1'b1),
        .wea(1'b0),
        .addra(in_idx),
        .dina(16'b0), 
        .douta(input_val)
    );

    // FC2 Weight BRAM (blk_mem_gen_4)
    blk_mem_gen_33 fc2_weight_bram (
        .clka(clk),
        .addra(weight_addr),
        .douta(weight_val)
    );

    // FC2 Bias BRAM (blk_mem_gen_5)
    blk_mem_gen_34 fc2_bias_bram (
        .clka(clk),
        .addra(out_idx),
        .douta(bias_val)
    );


    blk_mem_gen_35 fc2_output_bram (
        .clka(clk),
        .ena(state == S_WRITE),
        .wea(state == S_WRITE),
        .addra(out_idx),
        .dina(out_val),
        .douta(out_readback)
    );

    // FSM Sequential Logic
    always_ff @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            in_idx    <= 0;
            out_idx   <= 0;
            acc       <= 0;
            done      <= 0;
        end else begin
            state <= next_state;
            case (state)
                S_IDLE: begin
                    done    <= 0;
                    out_idx <= 0;
                end
                S_PREP: begin
                    in_idx <= 0;
                    acc    <= $signed(bias_val);
                end
                S_MAC: begin
                    acc    <= acc + $signed(input_val) * $signed(weight_val);
                    in_idx <= in_idx + 1;
                end
                S_NEXT_OUT: begin
                    out_idx <= out_idx + 1;
                end
                S_WRITE: begin
                    in_idx <= 0;
                end
                S_DONE: begin
                    done   <= 1;
                end
            endcase
        end
    end

    // FSM Combinational Logic
    always_comb begin
        next_state = state;
        bram_en = 0;
        
        case (state)
            S_IDLE:      if (start)                     next_state = S_PREP;
            S_PREP:      begin
                             bram_en = 1;
                             next_state = S_MAC;
                         end
            S_MAC:       begin
                             if (in_idx == N_IN-1)
                                next_state = S_WRITE;
                         end
            S_WRITE:     next_state = (out_idx == N_OUT-1) ? S_DONE : S_NEXT_OUT;
            S_NEXT_OUT:  next_state = S_PREP;
            S_DONE:      if (!start)                    next_state = S_IDLE;
        endcase
    end

endmodule
