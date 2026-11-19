`timescale 1ns/1ps

// ============================================================
// tb_uart_loopback.sv  -  uart_tx -> uart_rx end-to-end test
//
//  tx output is wired straight into rx input. Every byte sent is
//  queued, and every rx_valid is compared with the next queued byte.
//
//  Part 1: all 256 byte values, one frame at a time (FULL_SWEEP=1),
//          or a short directed list (FULL_SWEEP=0)
//  Part 2: a stream of random bytes with start held high, so frames
//          go out back-to-back
//
//  Default CLKS_PER_BIT = 64 keeps the simulation short.
//  For the real 9600-baud case use CLK_PERIOD = 20 (50 MHz),
//  CLKS_PER_BIT = 5208 and FULL_SWEEP = 0.
//  Vivado: set as simulation top, then "run all".
// ============================================================
module tb_uart_loopback;

    parameter integer CLKS_PER_BIT  = 64;
    parameter integer OVERSAMPLE    = 16;
    parameter integer CLK_PERIOD    = 10;     // ns
    parameter integer FULL_SWEEP    = 1;      // 1 = all 256 bytes
    parameter integer STREAM_FRAMES = 40;     // back-to-back random frames
    parameter integer VERBOSE       = 0;      // 1 = print every PASS

    localparam integer BIT_TIME   = CLKS_PER_BIT * CLK_PERIOD;
    localparam integer MAX_FRAMES = 256 + STREAM_FRAMES + 16;

    logic       clk;
    logic       rst;
    logic       start;
    logic [7:0] data_in;

    wire        line;                 // tx -> rx
    wire        busy;
    wire  [7:0] rx_data;
    wire        rx_valid;
    wire        framing_error;

    integer errors        = 0;
    integer frames_sent   = 0;
    integer frames_rx     = 0;
    integer framing_count = 0;

    logic [7:0] exp_q[$];
    logic [7:0] exp_data;
    logic [7:0] b;

    // DUTs
    uart_tx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) u_tx (
        .clk    (clk),
        .rst    (rst),
        .start  (start),
        .data_in(data_in),
        .tx     (line),
        .busy   (busy)
    );

    uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT),
        .OVERSAMPLE  (OVERSAMPLE)
    ) u_rx (
        .clk          (clk),
        .rst          (rst),
        .rx           (line),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .framing_error(framing_error)
    );

    // Clock
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Waveform dump
    initial begin
        $dumpfile("uart_loopback.vcd");
        $dumpvars(0, tb_uart_loopback);
    end

    // -----------------------------------------------------------
    // Scoreboard
    // -----------------------------------------------------------
    always @(posedge clk) begin
        if (rx_valid) begin
            frames_rx++;
            if (exp_q.size() == 0) begin
                $error("Unexpected rx_valid, rx_data=%h at %0t", rx_data, $time);
                errors++;
            end
            else begin
                exp_data = exp_q.pop_front();
                if (rx_data !== exp_data) begin
                    $error("LOOPBACK MISMATCH: sent=%h received=%h", exp_data, rx_data);
                    errors++;
                end
                else if (VERBOSE) begin
                    $display("PASS: sent=%h received=%h", exp_data, rx_data);
                end
            end
        end

        if (framing_error) begin
            framing_count++;
            $error("Framing error in loopback at %0t", $time);
            errors++;
        end
    end

    // -----------------------------------------------------------
    // Driver tasks
    // -----------------------------------------------------------

    // One byte, normal handshake: one-clock start pulse, wait for completion
    task automatic send_byte(input logic [7:0] data);
        begin
            exp_q.push_back(data);
            frames_sent++;

            @(negedge clk);
            data_in = data;
            start   = 1'b1;
            @(negedge clk);
            start = 1'b0;

            wait (busy == 1'b0);
            @(negedge clk);
        end
    endtask

    // n random bytes with start held high: frames go out back-to-back
    task automatic send_stream(input integer n);
        logic [7:0] d;
        begin
            d = $urandom_range(0, 255);
            exp_q.push_back(d);
            frames_sent++;

            @(negedge clk);
            data_in = d;
            start   = 1'b1;

            for (int k = 1; k < n; k++) begin
                @(posedge busy);              // previous frame accepted
                @(negedge clk);
                d = $urandom_range(0, 255);
                exp_q.push_back(d);
                frames_sent++;
                data_in = d;                  // start stays high
            end

            @(posedge busy);                  // last frame accepted
            @(negedge clk);
            start = 1'b0;

            wait (busy == 1'b0);
            @(negedge clk);
        end
    endtask

    // -----------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------
    initial begin
        rst     = 1'b1;
        start   = 1'b0;
        data_in = 8'h00;

        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        $display("--------------------------------");
        $display("UART LOOPBACK VERIFICATION STARTED");
        $display("CLKS_PER_BIT=%0d OVERSAMPLE=%0d FULL_SWEEP=%0d",
                 CLKS_PER_BIT, OVERSAMPLE, FULL_SWEEP);
        $display("--------------------------------");

        // Part 1: single frames
        if (FULL_SWEEP) begin
            for (int d = 0; d < 256; d++) begin
                b = d;
                send_byte(b);
            end
        end
        else begin
            send_byte(8'h00);
            send_byte(8'hFF);
            send_byte(8'h55);
            send_byte(8'hAA);
            send_byte(8'hA5);
        end
        $display("Part 1 done: %0d frames sent, %0d received", frames_sent, frames_rx);

        // Part 2: back-to-back stream
        send_stream(STREAM_FRAMES);
        $display("Part 2 done: %0d frames sent, %0d received", frames_sent, frames_rx);

        // Let the last frame settle
        repeat (CLKS_PER_BIT * 4) @(negedge clk);

        $display("--------------------------------");
        if (errors == 0 && frames_rx == frames_sent &&
            exp_q.size() == 0 && framing_count == 0)
            $display("UART LOOPBACK VERIFICATION PASSED");
        else
            $display("UART LOOPBACK VERIFICATION FAILED");
        $display("Frames sent     = %0d", frames_sent);
        $display("Frames received = %0d", frames_rx);
        $display("Framing errors  = %0d", framing_count);
        $display("Errors          = %0d", errors);
        $display("--------------------------------");

        $finish;
    end

    // Timeout watchdog (12 bit times per frame is generous)
    initial begin
        #(BIT_TIME * 12 * MAX_FRAMES);
        $fatal(1, "UART LOOPBACK SIMULATION TIMEOUT");
    end

endmodule
