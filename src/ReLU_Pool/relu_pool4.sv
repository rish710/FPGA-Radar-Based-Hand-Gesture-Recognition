`timescale 1ns/1ps

module relu_pool4 #(
    parameter DATA_WIDTH = 8,
    parameter CHANNELS   = 128,
    parameter IN_HEIGHT  = 3,
    parameter IN_WIDTH   = 4,

    parameter ADDR_WIDTH = 11   // log2(CH*H*W) = log2(128*3*4=1536) ? 11
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    output logic done
);

    // ----------------------------
    // Internal signals
    // ----------------------------
    logic [ADDR_WIDTH-1:0] in_addr;
    logic signed [DATA_WIDTH-1:0] in_dout;

    logic [ADDR_WIDTH-1:0] out_addr;
    logic signed [DATA_WIDTH-1:0] out_din;
    logic out_we;
    logic signed [DATA_WIDTH-1:0] dummy;

    // FSM states
    typedef enum logic [1:0] {IDLE, READ, WRITE, FINISH} state_t;
    state_t state;

    logic [ADDR_WIDTH-1:0] counter;   // global pixel counter

    // ----------------------------
    // Input BRAM Instance
    // ----------------------------
    blk_mem_gen_28 input_bram (
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
    blk_mem_gen_29 output_bram (
        .clka(clk),
        .ena(1'b1),
        .wea(out_we),
        .addra(out_addr),
        .dina(out_din),
        .douta(dummy)
    );

    // ----------------------------
    // FSM Sequential
    // ----------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            counter  <= 0;
            in_addr  <= 0;
            out_addr <= 0;
            out_we   <= 0;
            done     <= 0;
        end else begin
            case (state)
                IDLE: begin
                    done    <= 0;
                    out_we  <= 0;
                    if (start) begin
                        counter <= 0;
                        in_addr <= 0;
                        out_addr <= 0;
                        state   <= READ;
                    end
                end

                READ: begin
                    // BRAM read latency: in_dout valid next cycle
                    state <= WRITE;
                end

                WRITE: begin
                    // Apply ReLU
                    if (in_dout < 0)
                        out_din <= 0;
                    else
                        out_din <= in_dout;

                    out_we   <= 1;  // enable write
                    out_addr <= counter;
                    state    <= (counter == (CHANNELS*IN_HEIGHT*IN_WIDTH - 1)) ? FINISH : READ;

                    // increment counter + address
                    counter <= counter + 1;
                    in_addr <= counter + 1;
                end

                FINISH: begin
                    out_we <= 0;
                    done   <= 1;
                    state  <= IDLE;
                end
            endcase
        end
    end

endmodule
