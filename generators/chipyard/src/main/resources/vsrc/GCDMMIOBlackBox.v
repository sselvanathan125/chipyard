//Only Exp function // removed sq and sq functions
//TODO use exp o/p to get cosh and sinh
module GCDMMIOBlackBox
 #(parameter WIDTH = 32)
 (
    input                       clock,
    input                       reset,

    // AXI-Lite Style Slave Interface (from CPU)
    output                      input_ready,
    input                       input_valid,
    input      [WIDTH-1:0]      ax,
    input      [4:0]            read_addr,
    input                       output_ready,
    output                      output_valid,
    output     [WIDTH-1:0]      res,
    output                      busy
 );

    localparam S_IDLE            = 5'b00001,
               S_PRIME_START     = 5'b00010, //to start the flush cycle
               S_PRIME_WAIT      = 5'b00100, //to wait 
               S_COMPUTE_START   = 5'b01000,
               S_COMPUTE_WAIT    = 5'b10000,
               S_COMPUTE_LATCH   = 5'b10001, 
               S_RESULTS_READY   = 5'b10010;

    reg [4:0] state;

    // Internal memory and counters
    reg [WIDTH-1:0] internal_mem[0:31];
    reg [4:0]       load_idx;
    reg [4:0]       compute_idx;

    // Latency 
    localparam EXP_LATENCY = 30; // Total latency 30

    // Wires and registers
    reg [WIDTH-1:0] exp_in;
    reg             exp_enable;
    wire [WIDTH-1:0] exp_out;
    reg [WIDTH-1:0] exp_results[0:31];
    reg [4:0]       latency_counter;

    // instantiate the MATLAB-generated exp function 
    Subsystem exp_unit (
        .clk(clock),
        .reset(reset),
        .clk_enable(exp_enable),
        .In1(exp_in),
        .ce_out(),
        .Out1(exp_out)
    );

    // Handshake and O/p 
    assign input_ready  = (state == S_IDLE);
    assign output_valid = (state == S_RESULTS_READY);
    assign busy         = (state != S_IDLE);
    assign res          = exp_results[read_addr];

    // FSM 
    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= S_IDLE;
            load_idx <= 0;
            compute_idx <= 0;
            latency_counter <= 0;
            exp_enable <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (input_valid) begin
                        internal_mem[load_idx] <= ax;
                        if (load_idx == 31) begin
                            state <= S_PRIME_START; // All data loaded, start priming
                            exp_enable <= 1'b1;     // Enable the unit
                            load_idx <= 0;          // Reset for next run
                        end else begin
                            load_idx <= load_idx + 1;
                        end
                    end
                end

                S_PRIME_START: begin
                    exp_in <= internal_mem[0]; 
                    state <= S_PRIME_WAIT;
                end

                S_PRIME_WAIT: begin
                    if (latency_counter == EXP_LATENCY - 1) begin
                        //discarded 1st o/p becuase of 1st cycle pipeline has no o/p. junk result is not considered.
                        state <= S_COMPUTE_START;
                        latency_counter <= 0;
                    end else begin
                        latency_counter <= latency_counter + 1;
                    end
                end


                S_COMPUTE_START: begin
                    exp_in <= internal_mem[compute_idx];
                    state <= S_COMPUTE_WAIT;
                end

                S_COMPUTE_WAIT: begin
                    if (latency_counter == EXP_LATENCY - 1) begin
                        state <= S_COMPUTE_LATCH;
                        latency_counter <= 0;
                    end else begin
                        latency_counter <= latency_counter + 1;
                    end
                end

                S_COMPUTE_LATCH: begin
                    exp_results[compute_idx] <= exp_out; // Latch the valid, aligned result
                    if (compute_idx == 31) begin
                        exp_enable <= 1'b0; // Computation finished, disable the unit
                        state <= S_RESULTS_READY;
                    end else begin
                        compute_idx <= compute_idx + 1;
                        state <= S_COMPUTE_START;
                    end
                end

                S_RESULTS_READY: begin

                    state <= S_RESULTS_READY;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

