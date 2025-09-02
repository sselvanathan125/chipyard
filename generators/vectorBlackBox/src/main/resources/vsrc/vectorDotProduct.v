module dot_product(
    input [31:0] Ax, Ay, Az,
    input [31:0] Bx, By, Bz,
    output wire [63:0] result // Output is 64 bits because 32x32 multiplication can result in 64 bits
);
    // Perform dot product for a single set of vectors
    assign result = (Ax * Bx) + (Ay * By) + (Az * Bz);
endmodule

module vectormulti(
    input [31:0] ax [0:31], ay [0:31], az [0:31],  // Vector A components
    input [31:0] bx [0:31], by [0:31], bz [0:31],  // Vector B components
    output [63:0] scalar_out [0:31]               // Output scalar results
);
    wire [63:0] dot_results [0:31]; // Intermediate wires to hold results of dot products

    genvar i; // Generate block for looping
    generate
        for (i = 0; i < 32; i = i + 1) begin : dot_product_instances
            // Instantiate 32 dot_product modules in parallel
            dot_product dp (
                .Ax(ax[i]), .Ay(ay[i]), .Az(az[i]),
                .Bx(bx[i]), .By(by[i]), .Bz(bz[i]),
                .result(dot_results[i])
            );
        end
    endgenerate

    assign scalar_out[0]  = dot_results[0];
    assign scalar_out[1]  = dot_results[1];
    assign scalar_out[2]  = dot_results[2];
    assign scalar_out[3]  = dot_results[3];
    assign scalar_out[4]  = dot_results[4];
    assign scalar_out[5]  = dot_results[5];
    assign scalar_out[6]  = dot_results[6];
    assign scalar_out[7]  = dot_results[7];
    assign scalar_out[8]  = dot_results[8];
    assign scalar_out[9]  = dot_results[9];
    assign scalar_out[10] = dot_results[10];
    assign scalar_out[11] = dot_results[11];
    assign scalar_out[12] = dot_results[12];
    assign scalar_out[13] = dot_results[13];
    assign scalar_out[14] = dot_results[14];
    assign scalar_out[15] = dot_results[15];
    assign scalar_out[16] = dot_results[16];
    assign scalar_out[17] = dot_results[17];
    assign scalar_out[18] = dot_results[18];
    assign scalar_out[19] = dot_results[19];
    assign scalar_out[20] = dot_results[20];
    assign scalar_out[21] = dot_results[21];
    assign scalar_out[22] = dot_results[22];
    assign scalar_out[23] = dot_results[23];
    assign scalar_out[24] = dot_results[24];
    assign scalar_out[25] = dot_results[25];
    assign scalar_out[26] = dot_results[26];
    assign scalar_out[27] = dot_results[27];
    assign scalar_out[28] = dot_results[28];
    assign scalar_out[29] = dot_results[29];
    assign scalar_out[30] = dot_results[30];
    assign scalar_out[31] = dot_results[31];
endmodule
