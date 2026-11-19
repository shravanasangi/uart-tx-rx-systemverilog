`timescale 1ns/1ps

// ============================================================
// tb_uart_rx.sv  -  self-checking testbench for uart_rx
//
//  The testbench drives the rx line bit by bit, so it can create
//  frames a real uart_tx never produces (bad stop bit, glitches,
//  a stuck-low line, off-speed bits).
//
//  T1  directed + walking-ones + random bytes
//  T2  back-to-back frames (zero idle between frames)
//  T3  false starts: short low pulses must be ignored
//  T4  framing error, recovery, and a long break
//  T5  sender clock +-3 % off the receiver clock
//  T6  reset in the middle of a frame
//
//  CLKS_PER_BIT must be >= OVERSAMPLE (64 -> 4 clocks per tick).
//  Vivado: set as simulation top, then "run all".
// ============================================================
module tb_uart_rx;

    parameter integer CLKS_PER_BIT = 64;
    parameter integer OVERSAMPLE   = 16;
    parameter integer CLK_PERIOD   = 10;     // ns

    localparam integer BIT_TIME = CLKS_PER_BIT * CLK_PERIOD;

    logic       clk;
    logic       rst;
    logic       rx;
    wire  [7:0] rx_data;
    wire        rx_valid;
    wire        framing_error;

    integer errors        = 0;
    integer valid_count   = 0;
    integer framing_count = 0;
    integer v0, f0;                          // counters before a test
    integer cur_bit_clks  = CLKS_PER_BIT;    // bit width the driver uses

    logic [7:0] exp_q[$];
    logic [7:0] exp_data;
    logic [7:0] pat;

    // DUT
    uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT),
        .OVERSAMPLE  (OVERSAMPLE)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .rx           (rx),
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
        $dumpfile("uart_rx.vcd");
        $dumpvars(0, tb_uart_rx);
    end

    // -----------------------------------------------------------
    // Scoreboard: every rx_valid must match the next expected byte
    // -----------------------------------------------------------
    always @(posedge clk) begin
        if (rx_valid) begin
            valid_count++;
            if (exp_q.size() == 0) begin
                $error("Unexpected rx_valid, rx_data=%h at %0t", rx_data, $time);
                errors++;
            end
            else begin
                exp_data = exp_q.pop_front();
                if (rx_data !== exp_data) begin
                    $error("DATA MISMATCH: Expected=%h Actual=%h", exp_data, rx_data);
                    errors++;
                end
                else begin
                    $display("PASS: received %h", rx_data);
                end
            end
        end
        if (framing_error)
            framing_count++;
    end

    // -----------------------------------------------------------
    // Driver tasks (all rx changes happen on negedge clk, so there
    // is no race with the DUT sampling on posedge clk)
    // -----------------------------------------------------------
    task automatic drive_bit(input logic b);
        begin
            rx = b;
            repeat (cur_bit_clks) @(negedge clk);
        end
    endtask

    task automatic idle(input integer n_clks);
        begin
            rx = 1'b1;
            repeat (n_clks) @(negedge clk);
        end
    endtask

    // start bit + 8 data bits (LSB first) + stop bit at the given level
    task automatic send_frame(input logic [7:0] data, input logic stop_level);
        begin
            drive_bit(1'b0);
            for (int i = 0; i < 8; i++)
                drive_bit(data[i]);
            drive_bit(stop_level);
        end
    endtask

    // good frame followed by two idle bit times
    task automatic send_good(input logic [7:0] data);
        begin
            exp_q.push_back(data);
            send_frame(data, 1'b1);
            idle(CLKS_PER_BIT * 2);
        end
    endtask

    // low pulse of n_clks, then idle: should be ignored when < half a bit
    task automatic glitch(input integer n_clks);
        begin
            rx = 1'b0;
            repeat (n_clks) @(negedge clk);
            idle(CLKS_PER_BIT * 2);
        end
    endtask

    // check how many valid / framing pulses a test produced
    task automatic expect_delta(input string name,
                                input integer exp_valid,
                                input integer exp_framing);
        begin
            if ((valid_count - v0) != exp_valid ||
                (framing_count - f0) != exp_framing) begin
                $error("%s: expected valid+%0d framing+%0d, got valid+%0d framing+%0d",
                       name, exp_valid, exp_framing,
                       valid_count - v0, framing_count - f0);
                errors++;
            end
            else begin
                $display("PASS: %s", name);
            end
            v0 = valid_count;
            f0 = framing_count;
        end
    endtask

    // -----------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------
    initial begin
        rst = 1'b1;
        rx  = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);

        v0 = valid_count;
        f0 = framing_count;

        $display("--------------------------------");
        $display("UART RX VERIFICATION STARTED");
        $display("--------------------------------");

        // ---------- T1: good frames ----------
        send_good(8'h00);
        send_good(8'hFF);
        send_good(8'h55);
        send_good(8'hAA);
        send_good(8'hA5);
        send_good(8'h3C);
        send_good(8'h81);
        send_good(8'h7E);
        for (int k = 0; k < 8; k++) begin
            pat = 8'h01 << k;
            send_good(pat);
        end
        repeat (20) begin
            pat = $urandom_range(0, 255);
            send_good(pat);
        end
        expect_delta("T1 good frames (36)", 36, 0);

        // ---------- T2: back-to-back, no idle between frames ----------
        exp_q.push_back(8'hA5);
        exp_q.push_back(8'h5A);
        exp_q.push_back(8'hC3);
        send_frame(8'hA5, 1'b1);
        send_frame(8'h5A, 1'b1);
        send_frame(8'hC3, 1'b1);
        idle(CLKS_PER_BIT * 2);
        expect_delta("T2 back-to-back frames (3)", 3, 0);

        // ---------- T3: false starts must be ignored ----------
        glitch(1);                          // one clock wide
        glitch(CLKS_PER_BIT / 16);          // one oversample tick
        glitch(CLKS_PER_BIT / 4);           // quarter bit
        glitch(CLKS_PER_BIT * 3 / 8);       // just under half a bit
        expect_delta("T3 glitches ignored", 0, 0);
        send_good(8'h96);                   // receiver still works afterwards
        expect_delta("T3 frame after glitches", 1, 0);

        // ---------- T4: framing error ----------
        send_frame(8'h55, 1'b0);            // stop bit LOW
        idle(CLKS_PER_BIT * 2);
        expect_delta("T4 framing error flagged, byte discarded", 0, 1);
        send_good(8'h3C);
        expect_delta("T4 frame after framing error", 1, 0);

        // line stuck low for 30 bit times: ONE framing error, no retrigger
        rx = 1'b0;
        repeat (CLKS_PER_BIT * 30) @(negedge clk);
        idle(CLKS_PER_BIT * 3);
        expect_delta("T4 long break gives exactly one framing error", 0, 1);
        send_good(8'h81);
        expect_delta("T4 frame after break", 1, 0);

        // ---------- T5: sender clock +-3 % off ----------
        cur_bit_clks = (CLKS_PER_BIT * 97) / 100;     // sender 3 % fast
        send_good(8'h00);
        send_good(8'hFF);
        send_good(8'h55);
        send_good(8'hA5);
        send_good(8'h80);
        expect_delta("T5 sender 3% fast (5 frames)", 5, 0);

        cur_bit_clks = (CLKS_PER_BIT * 103) / 100;    // sender 3 % slow
        send_good(8'h00);
        send_good(8'hFF);
        send_good(8'h55);
        send_good(8'hA5);
        send_good(8'h01);
        expect_delta("T5 sender 3% slow (5 frames)", 5, 0);
        cur_bit_clks = CLKS_PER_BIT;

        // ---------- T6: reset in the middle of a frame ----------
        drive_bit(1'b0);                    // start
        drive_bit(1'b1);                    // d0
        drive_bit(1'b0);                    // d1
        drive_bit(1'b1);                    // d2
        rx  = 1'b1;                         // line goes idle ...
        rst = 1'b1;                         // ... and the receiver is reset
        repeat (2) @(negedge clk);
        rst = 1'b0;
        idle(CLKS_PER_BIT * 12);
        expect_delta("T6 reset mid-frame: no output", 0, 0);
        send_good(8'hE1);
        expect_delta("T6 frame after reset", 1, 0);

        // ---------- Summary ----------
        idle(CLKS_PER_BIT * 2);
        $display("--------------------------------");
        if (errors == 0 && exp_q.size() == 0)
            $display("UART RX VERIFICATION PASSED");
        else
            $display("UART RX VERIFICATION FAILED");
        $display("Valid frames    = %0d", valid_count);
        $display("Framing errors  = %0d", framing_count);
        $display("Errors          = %0d", errors);
        $display("--------------------------------");

        $finish;
    end

    // Timeout watchdog
    initial begin
        #(BIT_TIME * 2000);
        $fatal(1, "UART RX SIMULATION TIMEOUT");
    end

endmodule
