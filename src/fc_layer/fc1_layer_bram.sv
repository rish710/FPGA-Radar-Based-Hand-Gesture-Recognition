
`timescale 1ns/1ps

module fc1_layer_bram #(
    parameter int DATA_W = 8,
    parameter int N_IN   = 1536,
    parameter int N_OUT  = 128
)(
    input  wire                   clk,
    input  wire                   reset,
    input  wire                   start,
    output logic                  done
);

    // State machine (keep exactly the same)
    typedef enum logic [2:0] {
        S_IDLE, S_PREP, S_MAC, S_NEXT_OUT, S_WRITE, S_DONE
    } state_t;
    state_t state, next_state;

    logic [$clog2(N_IN)-1:0]     in_idx;
    logic [$clog2(N_OUT)-1:0]    out_idx;
    logic [DATA_W-1:0]           input_val, weight_val, bias_val;
    logic signed [DATA_W+8:0]    acc;
    logic [$clog2(N_IN*N_OUT)-1:0] weight_addr;

    // Memory control signals
    logic bram_en;
    logic [DATA_W-1:0] unused_readback;
    logic output_en, output_we;
    logic [DATA_W-1:0] output_din;
    
    // Address calculation
    assign weight_addr = out_idx * N_IN + in_idx;
    
    // ReLU logic
    logic [DATA_W-1:0] relu_result;
    always_comb begin
        if ($signed(acc) < 0)
            relu_result = 0;
        else
            relu_result = acc[DATA_W-1:0];
    end

    // Control signals (like your friend's depthwise)
    assign output_en = 1'b0;//(state == S_WRITE);
    assign output_we = (state == S_WRITE);
    assign output_din = relu_result;

    // FC1 Input BRAM (blk_mem_gen_0)

    blk_mem_gen_29 fc1_input_bram (
      .clka(clk),    
      .ena(1'b1),      // input wire ena
      .wea(1'b0),      // input wire [0 : 0] wea
      .addra(in_idx),  // input wire [10 : 0] addra
      .dina({DATA_W{1'b0}}),    // input wire [15 : 0] dina
      .douta(input_val)  // output wire [15 : 0] douta
    );

    // FC1 Weight BRAM (blk_mem_gen_1)
    blk_mem_gen_30 fc1_weight_bram (
        .clka(clk),
        .addra(weight_addr),
        .douta(weight_val)
    );

    // FC1 Bias BRAM (blk_mem_gen_2)
    blk_mem_gen_31 fc1_bias_bram (
        .clka(clk),
        .addra(out_idx),
        .douta(bias_val)
    );

    
    blk_mem_gen_32 fc1_output_bram (
        .clka(clk), 
        .ena(output_en), 
        .wea(output_we),
        .addra(out_idx), 
        .dina(output_din), 
        .douta(unused_readback)
    );

    // FSM Sequential Logic (keep exactly the same)
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

    // FSM Combinational Logic (keep exactly the same)
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

