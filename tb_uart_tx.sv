`timescale 1ns/1ps

// ============================================================
// tb_uart_tx.sv  -  self-checking testbench for uart_tx
//
//  * Monitor decodes the tx line on its own (black-box check)
//  * Scoreboard: queue of expected bytes, compared in order
//  * Bit-boundary checker: tx may only change at multiples of
//    BIT_TIME from the start edge (catches wrong bit widths)
//  * Tests: directed patterns, walking ones, random bytes,
//    back-to-back frames, start while busy, reset mid-frame,
//    idle-line and busy checks
//
//  Vivado: set as simulation top, then type  "run all"  in the
//  Tcl console (the default 1000 ns run stops far too early).
// ============================================================
module tb_uart_tx;

    parameter integer CLKS_PER_BIT = 4;
    parameter integer CLK_PERIOD   = 10;     // ns

    localparam integer BIT_TIME = CLKS_PER_BIT * CLK_PERIOD;

    logic       clk;
    logic       rst;
    logic       start;
    logic [7:0] data_in;
    wire        tx;
    wire        busy;

    integer errors         = 0;
    integer frames_sent    = 0;   // frames the driver expects to see
    integer frames_checked = 0;   // frames the monitor decoded and compared

    // Scoreboard
    logic [7:0] expected_queue[$];
    logic [7:0] expected_data;
    logic [7:0] received_data;
    logic       have_expected;

    // Monitor control
    logic monitor_en    = 1'b1;
    logic frame_active  = 1'b0;
    time  frame_t0;

    // DUT
    uart_tx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) dut (
        .clk     (clk),
        .rst     (rst),
        .start   (start),
        .data_in (data_in),
        .tx      (tx),
        .busy    (busy)
    );

    // Clock
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Waveform dump
    initial begin
        $dumpfile("uart_tx.vcd");
        $dumpvars(0, tb_uart_tx);
    end

    // -----------------------------------------------------------
    // Monitor + scoreboard: decode every frame seen on tx
    // -----------------------------------------------------------
    initial begin
        forever begin
            @(negedge tx);                       // possible start bit
            if (!monitor_en) continue;           // ignore while disabled

            frame_t0     = $time;
            frame_active = 1'b1;

            have_expected = (expected_queue.size() != 0);
            if (have_expected)
                expected_data = expected_queue.pop_front();
            else begin
                $error("Unexpected UART transmission at %0t", $time);
                errors++;
            end

            received_data = 8'h00;

            // Start bit, checked at its centre
            #(BIT_TIME/2);
            if (tx !== 1'b0) begin
                $error("START BIT ERROR at %0t", $time);
                errors++;
            end

            // Eight data bits, LSB first, each at its centre
            for (int i = 0; i < 8; i++) begin
                #(BIT_TIME);
                received_data[i] = tx;
            end

            // Stop bit, checked at its centre
            #(BIT_TIME);
            if (tx !== 1'b1) begin
                $error("STOP BIT ERROR at %0t", $time);
                errors++;
            end
            frame_active = 1'b0;

            if (have_expected) begin
                frames_checked++;
                if (received_data !== expected_data) begin
                    $error("DATA MISMATCH: Expected=%h Actual=%h",
                           expected_data, received_data);
                    errors++;
                end
                else begin
                    $display("PASS: Frame %0d Expected=%h Actual=%h",
                             frames_checked, expected_data, received_data);
                end
            end
        end
    end

    // -----------------------------------------------------------
    // Bit-boundary checker: inside a frame, tx may only change at
    // exact multiples of BIT_TIME after the start edge
    // -----------------------------------------------------------
    always @(tx) begin
        if (frame_active && ((($time - frame_t0) % BIT_TIME) != 0)) begin
            $error("TX CHANGED OFF A BIT BOUNDARY at %0t", $time);
            errors++;
        end
    end

    // -----------------------------------------------------------
    // Driver tasks
    // -----------------------------------------------------------

    // Normal transfer: idle check, one-clock start pulse, wait for completion
    task automatic send_byte(input logic [7:0] data);
        begin
            expected_queue.push_back(data);
            frames_sent++;

            @(negedge clk);
            if (tx !== 1'b1 || busy !== 1'b0) begin
                $error("LINE NOT IDLE (tx=%b busy=%b) BEFORE START", tx, busy);
                errors++;
            end
            data_in = data;
            start   = 1'b1;

            @(negedge clk);
            start = 1'b0;
            if (busy !== 1'b1) begin
                $error("BUSY DID NOT RISE ONE CLOCK AFTER START");
                errors++;
            end

            wait (busy == 1'b0);     // frame finished
            @(negedge clk);
        end
    endtask

    // Back-to-back: start stays high, data_in changes while frame A is
    // in flight (also proves A's data was latched at acceptance)
    task automatic send_back_to_back(input logic [7:0] a, input logic [7:0] b);
        begin
            expected_queue.push_back(a);
            expected_queue.push_back(b);
            frames_sent += 2;

            @(negedge clk);
            data_in = a;
            start   = 1'b1;
            @(posedge busy);          // A accepted
            @(negedge clk);
            data_in = b;              // start still high
            @(posedge busy);          // B accepted after one idle clock
            @(negedge clk);
            start = 1'b0;
            wait (busy == 1'b0);
            @(negedge clk);
        end
    endtask

    // A second start pulse in the middle of a frame must be ignored
    task automatic send_start_while_busy(input logic [7:0] data);
        begin
            expected_queue.push_back(data);
            frames_sent++;

            @(negedge clk);
            data_in = data;
            start   = 1'b1;
            @(negedge clk);
            start = 1'b0;

            repeat (CLKS_PER_BIT * 3) @(negedge clk);   // mid-frame
            data_in = ~data;
            start   = 1'b1;                              // must be ignored
            @(negedge clk);
            start = 1'b0;

            wait (busy == 1'b0);
            @(negedge clk);
        end
    endtask

    // Reset in the middle of a frame: aborted frame must not be
    // expected, tx must go HIGH, busy LOW, and the next frame be clean
    task automatic reset_mid_frame();
        begin
            monitor_en = 1'b0;                 // aborted frame is not scored

            @(negedge clk);
            data_in = 8'hA5;
            start   = 1'b1;
            @(negedge clk);
            start = 1'b0;

            repeat (CLKS_PER_BIT * 4) @(negedge clk);   // inside the data bits
            rst = 1'b1;
            @(negedge clk);
            if (tx !== 1'b1 || busy !== 1'b0) begin
                $error("RESET DID NOT RETURN tx HIGH / busy LOW");
                errors++;
            end
            else begin
                $display("PASS: reset mid-frame returned tx HIGH and busy LOW");
            end
            rst = 1'b0;
            @(negedge clk);
            monitor_en = 1'b1;

            send_byte(8'h3C);                  // next frame must be clean
        end
    endtask

    // -----------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------
    logic [7:0] pat;

    initial begin
        rst     = 1'b1;
        start   = 1'b0;
        data_in = 8'h00;

        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        $display("--------------------------------");
        $display("UART TX VERIFICATION STARTED");
        $display("--------------------------------");

        // Directed patterns
        send_byte(8'h00);
        send_byte(8'hFF);
        send_byte(8'h55);
        send_byte(8'hAA);
        send_byte(8'hA5);
        send_byte(8'h3C);
        send_byte(8'h81);
        send_byte(8'h7E);

        // Walking ones: a wrong bit position shows up immediately
        for (int k = 0; k < 8; k++) begin
            pat = 8'h01 << k;
            send_byte(pat);
        end

        // Random bytes
        repeat (20) begin
            pat = $urandom_range(0, 255);
            send_byte(pat);
        end

        // Corner cases
        send_back_to_back(8'hC3, 8'h3C);
        send_start_while_busy(8'h96);
        reset_mid_frame();

        // Let the monitor finish
        wait (busy == 1'b0);
        repeat (2) @(negedge clk);

        $display("--------------------------------");
        if (errors == 0 && frames_checked == frames_sent &&
            expected_queue.size() == 0)
            $display("UART TX VERIFICATION PASSED");
        else
            $display("UART TX VERIFICATION FAILED");
        $display("Frames sent    = %0d", frames_sent);
        $display("Frames checked = %0d", frames_checked);
        $display("Errors         = %0d", errors);
        $display("--------------------------------");

        $finish;
    end

    // Timeout watchdog (scales with the bit time)
    initial begin
        #(BIT_TIME * 10 * 100);
        $fatal(1, "UART TX SIMULATION TIMEOUT");
    end

endmodule
