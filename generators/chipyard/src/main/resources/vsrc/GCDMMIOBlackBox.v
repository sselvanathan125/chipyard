module GCDMMIOBlackBox
 #(parameter WIDTH = 32)
 (
    input                       clock,
    input                       reset,
    input [10:0]                batch_size,
    output                      input_ready,
    input                       input_valid,
    input [WIDTH-1:0]           ax,
    input                       output_ready,
    output                      output_valid,
    output reg [(2*WIDTH)-1:0]  res,
    output                      busy,
    input [$clog2(1024)-1:0]    mem_addr,
    input [WIDTH-1:0]           mem_write_data,
    input                       mem_write_en,
    output reg [10:0]           load_count,
    input [5:0]                 dp_read_addr
 );

    // --- FSM States (Expanded to 23 bits) ---
    localparam S_IDLE               = 23'b00000000000000000000001,
               S_LOADING            = 23'b00000000000000000000010,
               S_BATCH_START        = 23'b00000000000000000000100,
               S_COMPUTE_SQUARE     = 23'b00000000000000000001000,
               S_SUM_WAIT           = 23'b00000000000000000010000,
               S_ACCUMULATE_SUM     = 23'b00000000000000000100000,
               S_CHECK_BATCH_DONE   = 23'b00000000000000001000000,
               
               // SQRT States
               S_SQRT_START         = 23'b00000000000000010000000, 
               S_SQRT_WAIT          = 23'b00000000000000100000000, 
               S_SQRT_STORE         = 23'b00000000000001000000000,
               
               // DIV States
               S_DIV_START          = 23'b00000000000010000000000,
               S_DIV_WAIT           = 23'b00000000000100000000000,
               S_DIV_STORE          = 23'b00000000001000000000000,
               
               // EXP States 
               S_EXP_START_POS      = 23'b00000000010000000000000,
               S_EXP_WAIT_POS       = 23'b00000000100000000000000,
               S_EXP_STORE_POS      = 23'b00000001000000000000000,
               
               S_EXP_START_NEG      = 23'b00000010000000000000000,
               S_EXP_WAIT_NEG       = 23'b00000100000000000000000,
               S_EXP_STORE_NEG      = 23'b00001000000000000000000,

               // HYP (ADD/SUB) States
               S_HYP_START          = 23'b00010000000000000000000,
               S_HYP_WAIT           = 23'b00100000000000000000000,
               S_HYP_STORE          = 23'b01000000000000000000000,
               
               S_RESULT_READY       = 23'b10000000000000000000000;

    reg [22:0] state;

    reg [10:0] load_idx;
    reg [4:0]  batch_idx; 
    reg [WIDTH-1:0]  internal_mem [0:1023];
    reg [(2*WIDTH)-1:0] squared_results [0:31];
    
    reg [31:0]          results_memory [0:31];       
    integer i;

    reg [10:0] batch_size_reg;
    reg [4:0]  micro_batch_counter;
    reg [68:0] sum_accumulator;

    // --- SQRT SIGNALS ---
    reg [31:0] sqrt_data_in_float; 
    wire [31:0] sqrt_result_out;
    localparam SQRT_LATENCY_CYCLES = 20; 
    reg [5:0]  sqrt_latency_counter; 

    // --- DIV SIGNALS ---
    reg [31:0] div_input_a;
    reg [31:0] div_input_b;
    wire [31:0] div_result_out;
    localparam DIV_LATENCY_CYCLES = 25; 
    reg [5:0]  div_latency_counter;
    localparam [31:0] FLOAT_TWO = 32'h40000000; // 2.0

    // --- EXP SIGNALS ---
    reg [31:0] exp_input;
    wire [31:0] exp_output;
    reg exp_clk_enable; 
    wire exp_ce_out;    
    localparam EXP_LATENCY = 20; 
    reg [EXP_LATENCY-1:0] exp_valid_pipeline; 
    
    // Store Positive Exp Result
    reg [31:0] exp_result_pos;
    reg [31:0] exp_result_neg;

    // --- HYPERBOLIC (ADDER) SIGNALS ---
    reg [31:0] cosh_in_a, cosh_in_b;
    wire [31:0] cosh_result;
    
    reg [31:0] sinh_in_a, sinh_in_b;
    wire [31:0] sinh_result;
    
    localparam ADD_LATENCY = 10; // Latency for Floating Addition
    reg [5:0] add_latency_counter;

    // Wire placeholders for exception signals
    wire [2:0] exc_wires; // Overflow, Underflow, Exception

    // --- INSTANTIATIONS ---
    FloatingSqrt #(.XLEN(32)) sqrt_unit (
        .clk(clock), .A(sqrt_data_in_float), .result(sqrt_result_out),
        .overflow(exc_wires[0]), .underflow(exc_wires[1]), .exception(exc_wires[2])
    );

    FloatingDivision #(.XLEN(32)) div_unit (
        .clk(clock), .A(div_input_a), .B(div_input_b), .result(div_result_out),
        .overflow(), .underflow(), .exception()
    );
    
    Subsystem exp_unit (
        .clk(clock), .reset(reset), .clk_enable(exp_clk_enable),
        .In1(exp_input), .ce_out(exp_ce_out), .Out1(exp_output)
    );

    // COSH Adder: Exp(x) + Exp(-x)
    FloatingAddition #(.XLEN(32)) add_cosh (
        .clk(clock), .A(cosh_in_a), .B(cosh_in_b), .result(cosh_result),
        .exception() // Assuming standard interface
    );

    // SINH Adder: Exp(x) + (-Exp(-x)) -> Exp(x) - Exp(-x)
    FloatingAddition #(.XLEN(32)) add_sinh (
        .clk(clock), .A(sinh_in_a), .B(sinh_in_b), .result(sinh_result),
        .exception()
    );

    function [31:0] int_to_float;
        input [63:0] int_val;
        reg [7:0] exponent;
        reg [22:0] mantissa;
        integer k;
        reg [6:0] msb_pos;
        reg found;
        begin
            if (int_val == 0) begin
                int_to_float = 32'b0;
            end else begin
                msb_pos = 0;
                found = 0;
                for (k = 63; k >= 0; k = k - 1) begin
                    if (!found && int_val[k]) begin
                        msb_pos = k[6:0];
                        found = 1;
                    end
                end
                exponent = 127 + msb_pos;
                if (msb_pos >= 23) mantissa = int_val >> (msb_pos - 23);
                else mantissa = int_val << (23 - msb_pos);
                int_to_float = {1'b0, exponent, mantissa}; 
            end
        end
    endfunction

    wire [(2*WIDTH)-1:0] parallel_sum = 
        squared_results[0]  + squared_results[1]  + squared_results[2]  + squared_results[3] +
        squared_results[4]  + squared_results[5]  + squared_results[6]  + squared_results[7] +
        squared_results[8]  + squared_results[9]  + squared_results[10] + squared_results[11] +
        squared_results[12] + squared_results[13] + squared_results[14] + squared_results[15] +
        squared_results[16] + squared_results[17] + squared_results[18] + squared_results[19] +
        squared_results[20] + squared_results[21] + squared_results[22] + squared_results[23] +
        squared_results[24] + squared_results[25] + squared_results[26] + squared_results[27] +
        squared_results[28] + squared_results[29] + squared_results[30] + squared_results[31];

    assign input_ready = (state == S_IDLE) || (state == S_LOADING);
    assign output_valid = (state == S_RESULT_READY);
    assign busy = (state != S_IDLE);

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= S_IDLE;
            load_idx <= 0; load_count <= 0; batch_idx <= 0;
            micro_batch_counter <= 0; sum_accumulator <= 0;
            res <= 0; batch_size_reg <= 32;
            sqrt_data_in_float <= 0; 
            div_input_a <= 0; div_input_b <= 0;
            exp_input <= 0; exp_clk_enable <= 0; exp_valid_pipeline <= 0;
            exp_result_pos <= 0; exp_result_neg <= 0;
            cosh_in_a <= 0; cosh_in_b <= 0; sinh_in_a <= 0; sinh_in_b <= 0;
            sqrt_latency_counter <= 0; div_latency_counter <= 0; add_latency_counter <= 0;
            batch_idx <= 0;
        end else begin
            case (state)
                S_IDLE: if (input_valid) begin
                    internal_mem[0] <= ax;
                    load_idx <= 1; load_count <= 1;
                    batch_size_reg <= batch_size;
                    state <= S_LOADING;
                end
                
                S_LOADING: if (load_idx == 1024) begin
                    state <= S_BATCH_START;
                end else if (input_valid) begin
                    internal_mem[load_idx] <= ax;
                    load_idx <= load_idx + 1; load_count <= load_count + 1;
                end
                
                S_BATCH_START: begin
                    sum_accumulator <= 0;
                    micro_batch_counter <= 0;
                    state <= S_COMPUTE_SQUARE;
                end
                
                S_COMPUTE_SQUARE: begin
                    // Flush Logic: Batch 4 forces 0 inputs
                    if (batch_idx >= 4) begin
                        for (i = 0; i < 32; i = i + 1) squared_results[i] <= 0;
                    end else begin
                        for (i = 0; i < 32; i = i + 1)
                            squared_results[i] <= internal_mem[(batch_idx * batch_size_reg) + (micro_batch_counter * 32) + i] * internal_mem[(batch_idx * batch_size_reg) + (micro_batch_counter * 32) + i];
                    end
                    state <= S_SUM_WAIT;
                end
                
                S_SUM_WAIT: state <= S_ACCUMULATE_SUM;
                
                S_ACCUMULATE_SUM: begin
                    sum_accumulator <= sum_accumulator + parallel_sum;
                    state <= S_CHECK_BATCH_DONE;
                end

                S_CHECK_BATCH_DONE: begin
                    if (micro_batch_counter == (batch_size_reg / 32) - 1) state <= S_SQRT_START; 
                    else begin
                        micro_batch_counter <= micro_batch_counter + 1;
                        state <= S_COMPUTE_SQUARE;
                    end
                end
                
                // 1. SQRT
                S_SQRT_START: begin
                    sqrt_data_in_float <= int_to_float(sum_accumulator[63:0]);
                    sqrt_latency_counter <= 0;
                    state <= S_SQRT_WAIT;
                end
                
                S_SQRT_WAIT: begin
                    if (sqrt_latency_counter == SQRT_LATENCY_CYCLES) state <= S_SQRT_STORE; 
                    else sqrt_latency_counter <= sqrt_latency_counter + 1;
                end
                
                S_SQRT_STORE: state <= S_DIV_START;

                // 2. DIVISION
                S_DIV_START: begin
                    div_input_a <= sqrt_result_out;
                    div_input_b <= FLOAT_TWO;
                    div_latency_counter <= 0;
                    state <= S_DIV_WAIT;
                end

                S_DIV_WAIT: begin
                    if (div_latency_counter == DIV_LATENCY_CYCLES) state <= S_DIV_STORE;
                    else div_latency_counter <= div_latency_counter + 1;
                end

                S_DIV_STORE: state <= S_EXP_START_POS;

                // 3. EXPONENTIAL (PASS 1: POSITIVE)
                S_EXP_START_POS: begin
                    exp_input <= div_result_out; 
                    exp_clk_enable <= 1; exp_valid_pipeline <= 1; 
                    state <= S_EXP_WAIT_POS;
                end

                S_EXP_WAIT_POS: begin
                    exp_valid_pipeline <= exp_valid_pipeline << 1;
                    if (exp_valid_pipeline[EXP_LATENCY-1] == 1'b1) state <= S_EXP_STORE_POS;
                end

                S_EXP_STORE_POS: begin
                    exp_clk_enable <= 0;
                    exp_result_pos <= exp_output; 
                    state <= S_EXP_START_NEG;
                end

                // 4. EXPONENTIAL (PASS 2: NEGATIVE)
                S_EXP_START_NEG: begin
                    // Flip Sign Bit
                    exp_input <= { ~div_result_out[31], div_result_out[30:0] };
                    exp_clk_enable <= 1; exp_valid_pipeline <= 1; 
                    state <= S_EXP_WAIT_NEG;
                end

                S_EXP_WAIT_NEG: begin
                    exp_valid_pipeline <= exp_valid_pipeline << 1;
                    if (exp_valid_pipeline[EXP_LATENCY-1] == 1'b1) state <= S_EXP_STORE_NEG;
                end

                S_EXP_STORE_NEG: begin
                    exp_clk_enable <= 0;
                    exp_result_neg <= exp_output;
                    state <= S_HYP_START;
                end

                // 5. HYPERBOLIC ADDITION (COSH & SINH)
                S_HYP_START: begin
                    // Setup Cosh: Pos + Neg
                    cosh_in_a <= exp_result_pos;
                    cosh_in_b <= exp_result_neg;

                    // Setup Sinh: Pos - Neg (Calculated as Pos + (-Neg))
                    sinh_in_a <= exp_result_pos;
                    sinh_in_b <= { ~exp_result_neg[31], exp_result_neg[30:0] };

                    add_latency_counter <= 0;
                    state <= S_HYP_WAIT;
                end

                S_HYP_WAIT: begin
                    if (add_latency_counter == ADD_LATENCY) state <= S_HYP_STORE;
                    else add_latency_counter <= add_latency_counter + 1;
                end

                S_HYP_STORE: begin
                    // Pack Result: { Sinh, Cosh }
                    // Upper 32: Sinh. Lower 32: Cosh.
                    res <= {sinh_result, cosh_result};
                    state <= S_RESULT_READY;
                end

                S_RESULT_READY: if (output_ready) begin
                    // 5 Batches total (0 to 4)
                    if (batch_idx == (1024 / batch_size_reg)) begin
                        state <= S_IDLE;
                        load_idx <= 0; load_count <= 0; batch_idx <= 0;
                    end else begin
                        batch_idx <= batch_idx + 1;
                        state <= S_BATCH_START;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule



`timescale 1ns / 1ps
module FloatingSqrt#(parameter XLEN=32)
                    (input [XLEN-1:0]A,
                     input clk,
                     output overflow,
                     output underflow,
                     output exception,
                     output [XLEN-1:0] result);
wire [7:0] Exponent;
wire [22:0] Mantissa;
wire Sign;
wire [XLEN-1:0] temp1,temp2,temp3,temp4,temp5,temp6,temp7,temp8,temp;
wire [XLEN-1:0] x0,x1,x2,x3;
wire [XLEN-1:0] sqrt_1by05,sqrt_2,sqrt_1by2;
wire [7:0] Exp_2,Exp_Adjust;
wire remainder;
wire pos;
assign x0 = 32'h3f5a827a;
assign sqrt_1by05 = 32'h3fb504f3;  // 1/sqrt(0.5)
assign sqrt_2 = 32'h3fb504f3;
assign sqrt_1by2 = 32'h3f3504f3;
assign Sign = A[31];
assign Exponent = A[30:23];
assign Mantissa = A[22:0];
/*----First Iteration----*/
FloatingDivision D1(.A({1'b0,8'd126,Mantissa}),.B(x0),.result(temp1));
FloatingAddition A1(.A(temp1),.B(x0),.result(temp2));
assign x1 = {temp2[31],temp2[30:23]-1,temp2[22:0]};
/*----Second Iteration----*/
FloatingDivision D2(.A({1'b0,8'd126,Mantissa}),.B(x1),.result(temp3));
FloatingAddition A2(.A(temp3),.B(x1),.result(temp4));
assign x2 = {temp4[31],temp4[30:23]-1,temp4[22:0]};
/*----Third Iteration----*/
FloatingDivision D3(.A({1'b0,8'd126,Mantissa}),.B(x2),.result(temp5));
FloatingAddition A3(.A(temp5),.B(x2),.result(temp6));
assign x3 = {temp6[31],temp6[30:23]-1,temp6[22:0]};
FloatingMultiplication M1(.A(x3),.B(sqrt_1by05),.result(temp7));

assign pos = (Exponent>=8'd127) ? 1'b1 : 1'b0;
assign Exp_2 = pos ? (Exponent-8'd127)/2 : (Exponent-8'd127-1)/2 ;
assign remainder = (Exponent-8'd127)%2;
assign temp = {temp7[31],Exp_2 + temp7[30:23],temp7[22:0]};
//assign temp7[30:23] = Exp_2 + temp7[30:23];
FloatingMultiplication M2(.A(temp),.B(sqrt_2),.result(temp8));
assign result = remainder ? temp8 : temp;
endmodule
