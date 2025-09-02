module SimpleDMA(
    input wire clk,
    input wire rst,

    input wire start,
    input wire [31:0] src_addr,
    input wire [31:0] dst_addr,
    input wire [7:0] len,
    output reg done,

    // Read Channel - For sending read requests to memory
    output reg req_valid,
    output reg [31:0] req_addr,
    input wire req_ready,        // Bus is ready for our request

    // Read Response Channel - For receiving data from memory
    input wire resp_valid,      // The data from memory is valid
    input wire [31:0] resp_data,

    // Write Channel - For sending write requests to memory
    output reg [31:0] write_data,
    output reg [31:0] write_addr,
    output reg write_valid,
    input wire write_ready      // Bus is ready for our write
);

    // Internal state registers
    reg [7:0] counter;
    reg [2:0] state;
    reg [31:0] data_reg; // Register to buffer the data read from memory

    // Define states for the FSM
    localparam IDLE          = 3'd0,
               READ_REQ      = 3'd1,
               WAIT_READ_RESP  = 3'd2,
               WRITE_REQ     = 3'd3;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            // Reset all state registers and outputs
            state <= IDLE;
            done <= 1'b0;
            req_valid <= 1'b0;
            write_valid <= 1'b0;
            counter <= 8'd0;
            data_reg <= 32'd0;
            req_addr <= 32'd0; // Initialize req_addr
            write_addr <= 32'd0; // Initialize write_addr
            write_data <= 32'd0; // Initialize write_data
        end else begin
            // Default assignments to prevent latches
            req_valid <= 1'b0;
            write_valid <= 1'b0;

            // The 'done' signal should be latched high until the next 'start'
            if (start) begin
                done <= 1'b0;
            end

            case (state)
                IDLE: begin
                    if (start) begin
                        // Handle zero-length transfer edge case
                        if (len == 0) begin
                            done <= 1'b1; // Immediately finish
                            state <= IDLE;
                        end else begin
                            counter <= 8'd0;
                            state <= READ_REQ;
                        end
                    end
                end

                READ_REQ: begin
                    // Assert valid and address until the bus accepts the request
                    req_valid <= 1'b1;
                    req_addr <= src_addr + (counter << 2); // Calculate read address (word-aligned)
                    if (req_ready) begin
                        req_valid <= 1'b0; // De-assert once request is taken
                        state <= WAIT_READ_RESP; // Go wait for the response
                    end
                end

                WAIT_READ_RESP: begin
                    // Wait here until the read data is valid
                    if (resp_valid) begin
                        data_reg <= resp_data; // Capture the valid data
                        state <= WRITE_REQ;    // Now, proceed to write
                    end
                end

                WRITE_REQ: begin
                    // Use the buffered data from data_reg
                    write_valid <= 1'b1;
                    write_addr <= dst_addr + (counter << 2); // Calculate write address (word-aligned)
                    write_data <= data_reg; // Use the buffered data

                    if (write_ready) begin // If the bus accepts the write
                        write_valid <= 1'b0;
                        if (counter == len - 1) begin // Check if all words are transferred
                            state <= IDLE; // Go back to IDLE when finished
                            done <= 1'b1;  // Assert done, it will be latched
                        end else begin
                            counter <= counter + 1; // Increment counter for next word
                            state <= READ_REQ; // Go read the next word
                        end
                    end
                end
            endcase
        end
    end

endmodule