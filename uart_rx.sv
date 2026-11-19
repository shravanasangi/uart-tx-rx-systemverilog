// ============================================================
// uart_rx.sv  -  UART receiver, 8N1, 16x oversampling
//
//  * 2-flop synchronizer on rx (+ 3rd flop for falling-edge detect)
//  * Start bit is detected on a FALLING EDGE only, so a line held
//    low (break) produces one framing error, not an endless stream
//  * Start bit re-checked after half a bit (8 oversample ticks):
//    short glitches are rejected as false starts
//  * Data bits sampled at the bit centre (24, 40, 56 ... ticks after
//    the detected edge), LSB first
//  * Stop bit sampled at its centre
//      stop = 1 : rx_valid pulses for one clock, rx_data holds byte
//      stop = 0 : framing_error pulses for one clock, byte discarded
//
//  CLKS_PER_BIT must be >= OVERSAMPLE.
//  Clocks per oversample tick = CLKS_PER_BIT / OVERSAMPLE (integer
//  division). 5208 / 16 = 325, so the receiver bit period is 5200
//  clocks, about 0.15 % shorter than the transmitter. That is far
//  inside the tolerance of a 16x receiver.
// ============================================================
module uart_rx #(
    parameter integer CLKS_PER_BIT = 5208,
    parameter integer OVERSAMPLE   = 16
)(
    input            clk,
    input            rst,            // Active-high synchronous reset
    input            rx,             // Asynchronous serial input
    output reg [7:0] rx_data,        // Received byte (valid when rx_valid = 1)
    output reg       rx_valid,       // 1-clock pulse: good frame received
    output reg       framing_error   // 1-clock pulse: stop bit was LOW
);

    // ---------------- Derived constants ----------------
    localparam integer CLKS_PER_OS = CLKS_PER_BIT / OVERSAMPLE;  // clocks per tick
    localparam integer HALF        = OVERSAMPLE / 2;             // ticks to bit centre
    localparam integer OS_W        = (CLKS_PER_OS <= 1) ? 1 : $clog2(CLKS_PER_OS);
    localparam integer TICK_W      = (OVERSAMPLE  <= 1) ? 1 : $clog2(OVERSAMPLE);

    initial begin
        if (OVERSAMPLE < 2 || (OVERSAMPLE % 2) != 0)
            $error("OVERSAMPLE must be an even number >= 2");
        if (CLKS_PER_BIT < OVERSAMPLE)
            $error("CLKS_PER_BIT must be >= OVERSAMPLE");
    end

    // ---------------- FSM states ----------------
    localparam IDLE  = 2'b00;
    localparam START = 2'b01;
    localparam DATA  = 2'b10;
    localparam STOP  = 2'b11;

    reg [1:0]        state;
    reg [OS_W-1:0]   os_cnt;     // clocks within one oversample tick
    reg [TICK_W-1:0] tick_cnt;   // oversample ticks within one bit
    reg [2:0]        bit_idx;    // data bit being received (0..7)
    reg [7:0]        rx_shift;   // data bits collected so far

    // ---------------- Input synchronizer ----------------
    reg rx_s1, rx_s2, rx_s3;

    always @(posedge clk) begin
        if (rst) begin
            rx_s1 <= 1'b1;
            rx_s2 <= 1'b1;
            rx_s3 <= 1'b1;
        end
        else begin
            rx_s1 <= rx;
            rx_s2 <= rx_s1;
            rx_s3 <= rx_s2;
        end
    end

    // Falling edge on the synchronized line = possible start bit
    wire start_edge = (rx_s3 == 1'b1) && (rx_s2 == 1'b0);

    // One pulse per oversample tick
    wire os_tick = (os_cnt == CLKS_PER_OS - 1);

    // ---------------- Receiver FSM ----------------
    always @(posedge clk) begin

        if (rst) begin
            state         <= IDLE;
            os_cnt        <= 0;
            tick_cnt      <= 0;
            bit_idx       <= 0;
            rx_shift      <= 8'h00;
            rx_data       <= 8'h00;
            rx_valid      <= 1'b0;
            framing_error <= 1'b0;
        end

        else begin

            // Status outputs are single-cycle pulses
            rx_valid      <= 1'b0;
            framing_error <= 1'b0;

            case (state)

                // Wait for a falling edge on the synchronized rx line
                IDLE: begin
                    os_cnt   <= 0;
                    tick_cnt <= 0;
                    bit_idx  <= 0;

                    if (start_edge)
                        state <= START;
                end

                // Wait half a bit, then confirm the line is still LOW
                START: begin
                    if (os_tick) begin
                        os_cnt <= 0;

                        if (tick_cnt == HALF - 1) begin
                            tick_cnt <= 0;

                            if (rx_s2 == 1'b0)
                                state <= DATA;     // real start bit
                            else
                                state <= IDLE;     // false start: reject
                        end
                        else begin
                            tick_cnt <= tick_cnt + 1'b1;
                        end
                    end
                    else begin
                        os_cnt <= os_cnt + 1'b1;
                    end
                end

                // One sample per bit period, at the bit centre
                DATA: begin
                    if (os_tick) begin
                        os_cnt <= 0;

                        if (tick_cnt == OVERSAMPLE - 1) begin
                            tick_cnt <= 0;

                            // LSB first: new bit enters at the MSB end,
                            // after 8 shifts the first bit sits at [0]
                            rx_shift <= {rx_s2, rx_shift[7:1]};

                            if (bit_idx == 3'd7)
                                state <= STOP;
                            else
                                bit_idx <= bit_idx + 1'b1;
                        end
                        else begin
                            tick_cnt <= tick_cnt + 1'b1;
                        end
                    end
                    else begin
                        os_cnt <= os_cnt + 1'b1;
                    end
                end

                // Sample the stop bit at its centre
                STOP: begin
                    if (os_tick) begin
                        os_cnt <= 0;

                        if (tick_cnt == OVERSAMPLE - 1) begin
                            tick_cnt <= 0;
                            state    <= IDLE;

                            if (rx_s2 == 1'b1) begin
                                rx_data  <= rx_shift;   // good frame
                                rx_valid <= 1'b1;
                            end
                            else begin
                                framing_error <= 1'b1;  // byte discarded
                            end
                        end
                        else begin
                            tick_cnt <= tick_cnt + 1'b1;
                        end
                    end
                    else begin
                        os_cnt <= os_cnt + 1'b1;
                    end
                end

                default: begin
                    state    <= IDLE;
                    os_cnt   <= 0;
                    tick_cnt <= 0;
                    bit_idx  <= 0;
                end

            endcase
        end
    end

endmodule
