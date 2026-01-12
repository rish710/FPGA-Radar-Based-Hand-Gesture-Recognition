`timescale 1ns / 1ps

module top (
    input  wire clk_p,   // differential clock input (AH12)
    input  wire clk_n, 
    input  wire rst_n,
    input  wire start,    // start processing all layers
    output reg  done      // goes high when all layers finished
);
    
    wire clk;
    // Differential clock buffer
    IBUFDS ibufds_sysclk (
        .I (clk_p),
        .IB(clk_n),
        .O (clk)
    );
    
    // Layer done signals
    wire done_dw, done_pw, done_bn, done_relu_pool;
    wire done_dw2, done_pw2, done_bn2, done_relu_pool2;
    wire done_dw3, done_pw3, done_bn3, done_relu_pool3;

    // Layer start signals
    reg start_dw, start_pw, start_relu_pool;
    reg start_dw2, start_pw2, start_relu_pool2;
    reg start_dw3, start_pw3, start_relu_pool3;
    wire done_gconv, done_bn4, done_relu_pool4;
    reg start_gconv, start_relu_pool4;
        // Layer done signals
    wire done_fc1, done_fc2;
    reg start_fc1, start_fc2;
    // FSM states
    typedef enum logic [5:0] {
        IDLE,
        RUN_DW,
        RUN_PW,
        RUN_BN,
        RUN_RELU_POOL,
        RUN_DW2,
        RUN_PW2,
        RUN_BN2,
        RUN_RELU_POOL2,
        RUN_DW3,
        RUN_PW3,
        RUN_BN3,
        RUN_RELU_POOL3,
        RUN_GCONV, RUN_BN4, RUN_RELU_POOL4,
        RUN_FC1, RUN_FC2,
        FINISH
    } state_t;

    state_t state, next_state;

    // FSM sequential
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // FSM combinational
    always @(*) begin
        // defaults
        start_dw        = 0;
        start_pw        = 0;
        start_relu_pool = 0;
        start_dw2       = 0;
        start_pw2       = 0;
        start_relu_pool2= 0;
        start_dw3       = 0;
        start_pw3       = 0;
        start_relu_pool3= 0;
        start_gconv=0;
        start_relu_pool4=0;
        done            = 0;
        start_fc1=0;
        start_fc2=0;
        next_state      = state;

        case (state)
            IDLE: begin
                if (start)
                    next_state = RUN_DW;
            end

            // First set of layers
            RUN_DW: begin
                start_dw = 1;
                if (done_dw)
                    next_state = RUN_PW;
            end

            RUN_PW: begin
                start_pw = 1;
                if (done_pw)
                    next_state = RUN_BN;
            end

            RUN_BN: begin
                if (done_bn)
                    next_state = RUN_RELU_POOL;
            end

            RUN_RELU_POOL: begin
                start_relu_pool = 1;
                if (done_relu_pool)
                    next_state = RUN_DW2; 
            end

            // Second set of layers
            RUN_DW2: begin
                start_dw2 = 1;
                if (done_dw2)
                    next_state = RUN_PW2;
            end

            RUN_PW2: begin
                start_pw2 = 1;
                if (done_pw2)
                    next_state = RUN_BN2;
            end

            RUN_BN2: begin
                if (done_bn2)
                    next_state = RUN_RELU_POOL2;
            end

            RUN_RELU_POOL2: begin
                start_relu_pool2 = 1;
                if (done_relu_pool2)
                    next_state = RUN_DW3; // move to third set
            end

            // Third set of layers
            RUN_DW3: begin
                start_dw3 = 1;
                if (done_dw3)
                    next_state = RUN_PW3;
            end

            RUN_PW3: begin
                start_pw3 = 1;
                if (done_pw3)
                    next_state = RUN_BN3;
            end

            RUN_BN3: begin
                if (done_bn3)
                    next_state = RUN_RELU_POOL3;
            end

            RUN_RELU_POOL3: begin
                start_relu_pool3 = 1;
                if (done_relu_pool3)
                    next_state = RUN_GCONV;
            end

            RUN_GCONV: begin
                start_gconv = 1;
                if (done_gconv)
                    next_state = RUN_BN4;
            end
            
            RUN_BN4: begin
                if (done_bn4)
                    next_state = RUN_RELU_POOL4;
            end
            
            RUN_RELU_POOL4: begin
                start_relu_pool4 = 1;
                if (done_relu_pool4)
                    next_state = RUN_FC1;
            end
            RUN_FC1: begin start_fc1 = 1; if (done_fc1) next_state = RUN_FC2; end   
            
            RUN_FC2: begin start_fc2 = 1; if (done_fc2) next_state = FINISH; end

            FINISH: begin
                done = 1;
            end
        endcase
    end

    // === Instantiate first set of layers ===
    depthwise_conv u_depthwise (
        .clk(clk), .rst_n(rst_n),
        .start(start_dw), .done(done_dw)
    );

    pointwise_conv u_pointwise (
        .clk(clk), .rst_n(rst_n),
        .start(start_pw), 
        .ena(1'b1),
        .done(done_pw)
    );

    batch_norm u_batchnorm (
        .clk(clk), .rst_n(rst_n),
        .done(done_bn)
    );

    relu_pool u_relu_pool (
        .clk(clk), .rst_n(rst_n),
        .start(start_relu_pool), .done(done_relu_pool)
    );

    // === Instantiate second set of layers ===
    depthwise_conv2 u_depthwise2 (
        .clk(clk), .rst_n(rst_n),
        .start(start_dw2), .done(done_dw2)
    );

    pointwise_conv2 u_pointwise2 (
        .clk(clk), .rst_n(rst_n),
        .start(start_pw2), 
        .ena(1'b1),
        .done(done_pw2)
    );

    batch_norm2 u_batchnorm2 (
        .clk(clk), .rst_n(rst_n),
        .done(done_bn2)
    );

    relu_pool2 u_relu_pool2 (
        .clk(clk), .rst_n(rst_n),
        .start(start_relu_pool2), .done(done_relu_pool2)
    );

    depthwise_con3 u_depthwise3 (
        .clk(clk), .rst_n(rst_n),
        .start(start_dw3), .done(done_dw3)
    );

    pointwise_conv3 u_pointwise3 (
        .clk(clk), .rst_n(rst_n),
        .start(start_pw3), 
        .ena(1'b1),
        .done(done_pw3)
    );

    batch_norm3 u_batchnorm3 (
        .clk(clk), .rst_n(rst_n),
        .done(done_bn3)
    );

    relu_pool3 u_relu_pool3 (
        .clk(clk), .rst_n(rst_n),
        .start(start_relu_pool3), .done(done_relu_pool3)
    );
    
    grouped_convolution_bram u_gconv (
        .clk(clk),
        .reset(rst_n),
        .start(start_gconv),
        .done(done_gconv)
    );
    
    batch_norm4 u_batchnorm4 (
        .clk(clk),
        .rst_n(rst_n),
        .done(done_bn4)
    );
    
    relu_pool4 u_relu_pool4 (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_relu_pool4),
        .done(done_relu_pool4)
    );
    
        // FC1 Layer (writes to blk_mem_gen_3)
    fc1_layer_bram u_fc1 (
        .clk(clk), 
        .reset(~rst_n),
        .start(start_fc1), 
        .done(done_fc1)
    );

    // FC2 Layer (reads from blk_mem_gen_3)
    fc2_layer_bram u_fc2 (
        .clk(clk), 
        .reset(~rst_n),
        .start(start_fc2),
        //.ena(1'b1),              // Always enabled like your friend's pointwise
        .done(done_fc2)
    );


endmodule
