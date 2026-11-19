// ============================================================
// uart_tx.sv  -  UART transmitter, 8N1
// Parameter: CLKS_PER_BIT = clock cycles per UART bit
// ============================================================
module uart_tx #(
    parameter integer CLKS_PER_BIT = 5208
)(
    input        clk,
    input        rst,       // Active-high synchronous reset
    input        start,
    input  [7:0] data_in,
    output reg   tx,
    output       busy
);

    // Check parameter
    initial begin
        if (CLKS_PER_BIT < 1)
            $error("CLKS_PER_BIT must be >= 1");
    end

    // FSM states
    localparam IDLE  = 2'b00;
    localparam START = 2'b01;
    localparam DATA  = 2'b10;
    localparam STOP  = 2'b11;

    reg [1:0] state;

    // Counter sizing
    localparam integer BAUD_WIDTH =
        (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

    reg [BAUD_WIDTH-1:0] baud_count;
    reg [3:0] bit_count;

    // Frame: [9]=stop, [8:1]=data, [0]=start
    reg [9:0] frame;

    // Baud-period completion
    wire baud_tick;
    assign baud_tick = (baud_count == CLKS_PER_BIT - 1);

    // Busy is high outside IDLE
    assign busy = (state != IDLE);

    always @(posedge clk) begin

        if (rst) begin
            state      <= IDLE;
            frame      <= 10'b1111111111;
            baud_count <= 0;
            bit_count  <= 0;
            tx         <= 1'b1;
        end

        else begin

            case (state)

                // IDLE
                IDLE: begin
                    tx         <= 1'b1;
                    baud_count <= 0;
                    bit_count  <= 0;

                    if (start) begin
                        frame <= {1'b1, data_in, 1'b0};
                        tx    <= 1'b0;
                        state <= START;
                    end
                end

                // START BIT
                START: begin
                    if (baud_tick) begin
                        baud_count <= 0;
                        tx         <= frame[1];
                        bit_count  <= 1;
                        state      <= DATA;
                    end
                    else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                // DATA BITS - LSB FIRST
                DATA: begin
                    if (baud_tick) begin
                        baud_count <= 0;

                        if (bit_count < 8) begin
                            tx        <= frame[bit_count + 1'b1];
                            bit_count <= bit_count + 1'b1;
                        end
                        else begin
                            tx    <= frame[9];
                            state <= STOP;
                        end
                    end
                    else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                // STOP BIT
                STOP: begin
                    if (baud_tick) begin
                        baud_count <= 0;
                        tx         <= 1'b1;
                        state      <= IDLE;
                    end
                    else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                // DEFAULT
                default: begin
                    state      <= IDLE;
                    baud_count <= 0;
                    bit_count  <= 0;
                    tx         <= 1'b1;
                end

            endcase
        end
    end

endmodule
