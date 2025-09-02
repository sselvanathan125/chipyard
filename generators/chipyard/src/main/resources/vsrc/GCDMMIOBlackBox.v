module GCDMMIOBlackBox
 #(parameter WIDTH = 32)
 (
   input               clock,
   input               reset,
   output              input_ready,
   input               input_valid,
   input [WIDTH-1:0]   ax,
   input               output_ready,     
   output              output_valid,      
   output reg [(2*WIDTH)-1:0] res,
   output              busy,
   input  [$clog2(192)-1:0] mem_addr,
   input  [WIDTH-1:0]   mem_write_data,
   input               mem_write_en,
   output reg [7:0]      load_count,
   input [5:0]           dp_read_addr
 );

    // FSM States-local data
    localparam S_IDLE               = 8'b00000001,
               S_LOADING            = 8'b00000010,
               S_BATCH_START        = 8'b00000100,
               S_COMPUTE_SQUARE     = 8'b00001000,
               S_COMPUTE_WAIT       = 8'b00010000,
               S_SQRT_START         = 8'b00100000,
               S_SQRT_ITER          = 8'b01000000,
               S_STORE_RESULT       = 8'b10000000,
               S_RESULT_READY       = 8'b00000011;
               // S_WAIT_ACK_LOW, S_DONE_WAIT_HIGH, and S_DONE_WAIT_LOW are removed.

    reg [7:0] state;

    // Internal Reg and Mem
    reg [7:0] load_idx;
    reg [2:0] batch_idx;
    reg [WIDTH-1:0]   internal_mem [0:191];
    reg [(2*WIDTH)-1:0] squared_results [0:31];
    reg [WIDTH-1:0]   batch_results [0:5];
    reg [(2*WIDTH)-1:0] sqrt_operand;
    reg [(2*WIDTH)-1:0] sqrt_remainder;
    reg [WIDTH-1:0]   sqrt_root;
    reg [5:0]         sqrt_iter_count;
    integer i;

    // Wire connected adder tree 
    wire [(2*WIDTH)-1:0] parallel_sum =
        squared_results[0]  + squared_results[1]  + squared_results[2]  + squared_results[3] +
        squared_results[4]  + squared_results[5]  + squared_results[6]  + squared_results[7] +
        squared_results[8]  + squared_results[9]  + squared_results[10] + squared_results[11] +
        squared_results[12] + squared_results[13] + squared_results[14] + squared_results[15] +
        squared_results[16] + squared_results[17] + squared_results[18] + squared_results[19] +
        squared_results[20] + squared_results[21] + squared_results[22] + squared_results[23] +
        squared_results[24] + squared_results[25] + squared_results[26] + squared_results[27] +
        squared_results[28] + squared_results[29] + squared_results[30] + squared_results[31];

    // I/O Assignments
    assign input_ready = (state == S_IDLE) || (state == S_LOADING);
    assign output_valid = (state == S_RESULT_READY);
    assign busy = (state != S_IDLE);

    // Wires for SQRT logic
    wire [(2*WIDTH)-1:0] y_ref = {sqrt_remainder[(2*WIDTH)-3:0], sqrt_operand[(2*WIDTH)-1:(2*WIDTH)-2]};
    wire [(2*WIDTH)-1:0] r_ref = {sqrt_root, 2'b01};

    // FSM Logic
    always @(posedge clock or posedge reset) begin
      if (reset) begin
        state <= S_IDLE;
        load_idx <= 0;
        load_count <= 0;
        batch_idx <= 0;
      end else begin
          case (state)
            S_IDLE: if (input_valid) begin
                internal_mem[0] <= ax;
                load_idx <= 1; load_count <= 1; state <= S_LOADING;
            end
            S_LOADING: if (load_idx == 192) begin
                state <= S_BATCH_START;
            end else if (input_valid) begin
                internal_mem[load_idx] <= ax;
                load_idx <= load_idx + 1; load_count <= load_count + 1;
            end
            S_BATCH_START: state <= S_COMPUTE_SQUARE;
            S_COMPUTE_SQUARE: begin
                for (i = 0; i < 32; i = i + 1)
                    squared_results[i] <= internal_mem[batch_idx * 32 + i] * internal_mem[batch_idx * 32 + i];
                state <= S_COMPUTE_WAIT;
            end
            S_COMPUTE_WAIT: state <= S_SQRT_START; 
            S_SQRT_START: begin
                sqrt_operand <= parallel_sum;         //TODO simplify SQ ROOT in few cycles
                sqrt_remainder <= 0;
                sqrt_root <= 0;
                sqrt_iter_count <= 0;
                state <= S_SQRT_ITER;
            end
            S_SQRT_ITER: begin
                sqrt_operand <= sqrt_operand << 2;
                if (y_ref >= r_ref) begin
                    sqrt_remainder <= y_ref - r_ref; sqrt_root <= {sqrt_root[(WIDTH-2):0], 1'b1};
                end else begin
                    sqrt_remainder <= y_ref; sqrt_root <= {sqrt_root[(WIDTH-2):0], 1'b0};
                end
                if (sqrt_iter_count == WIDTH-1) state <= S_STORE_RESULT;
                else sqrt_iter_count <= sqrt_iter_count + 1;
            end
            S_STORE_RESULT: begin
                batch_results[batch_idx] <= sqrt_root;
               // $display("Batch %d - Final Sqrt Result: %d", batch_idx, sqrt_root);
                state <= S_RESULT_READY;
            end
            S_RESULT_READY: if (output_ready) begin
                if (batch_idx == 5) begin  //State change to Reset in last batch
                    state <= S_IDLE;
                    load_idx <= 0;
                    load_count <= 0;
                    batch_idx <= 0;
                end else begin
                    // More batches to process.
                    batch_idx <= batch_idx + 1;
                    state <= S_BATCH_START;
                end
            end
          endcase
      end
    end

    // Combinational read logic for memory
    always @(*) begin
        if (dp_read_addr < 6) res = batch_results[dp_read_addr];
        else res = 0;
    end
endmodule