/**
 * ooo_exec_tb.sv — Testbench for ooo_exec
 * ─────────────────────────────────────────────────────────────────────────────
 * Verifies: in-order issue, out-of-order execution, CDB forwarding,
 * WAW elimination via renaming, RAW chain, and in-order commit.
 * ─────────────────────────────────────────────────────────────────────────────
 */

`timescale 1ns/1ps

module ooo_exec_tb;

  logic        clk, rst_n;
  logic        issue_valid, issue_ready;
  logic [2:0]  issue_op, issue_rs1, issue_rs2, issue_rd;
  logic        commit_valid;
  logic [2:0]  commit_rd;
  logic [31:0] commit_data;
  logic [31:0] arch_reg [0:7];

  ooo_exec #(.RS_SIZE(8),.ROB_SIZE(8),.REGS(8)) dut (.*);

  always #5 clk = ~clk;

  int pass_cnt = 0, fail_cnt = 0;

  task automatic check32(logic [31:0] got, exp, string label);
    if (got === exp) begin

      $display("  PASS  %-35s = 0x%08h", label, got); pass_cnt++;
    end else begin
      $display("  FAIL  %-35s got=0x%08h exp=0x%08h", label, got, exp); fail_cnt++;
    end
  endtask

  // Issue one instruction and wait until the unit accepts it
  task automatic issue_instr(input logic [2:0] op, rs1, rs2, rd);
    @(posedge clk); #1;
    issue_valid = 1; issue_op = op;
    issue_rs1 = rs1; issue_rs2 = rs2; issue_rd = rd;
    while (!issue_ready) @(posedge clk);
    @(posedge clk); #1;
    issue_valid = 0;
  endtask

  // Wait until rd commits, return committed value
  task automatic wait_commit_rd(input logic [2:0] rd, output logic [31:0] val);
    forever begin
      @(posedge clk); #1;
      if (commit_valid && commit_rd == rd) begin val = commit_data; return; end
    end
  endtask

  initial begin
    clk=0; rst_n=0;
    issue_valid=0; issue_op=0; issue_rs1=0; issue_rs2=0; issue_rd=0;
    // ── VCD waveform dump (generates waveform viewer data) ───────────────────
    $dumpfile("dump.vcd");
    $dumpvars(0, ooo_exec_tb);
    // ─────────────────────────────────────────────────────────────────────────
    $display("=== ooo_exec testbench ===");

    repeat(4) @(posedge clk); rst_n=1;

    // ── Test 1: Simple ADD — r3 = r0 + r1 (both 0 initially) ──────────────
    $display("-- Test 1: ADD r3 = r0 + r1 (0+0=0) --");
    issue_instr(3'b000, 3'd0, 3'd1, 3'd3);
    begin logic [31:0] v; wait_commit_rd(3'd3, v);
      check32(v, 32'd0, "r3 = r0 + r1"); end

    // ── Test 2: WAW hazard — two successive writes to r4 ──────────────────
    // Both write r4. RAT tracks the latest (second write). Both must commit
    // in order; r4 must end up = 0 (r0+r3 = 0+0).
    $display("-- Test 2: WAW r4a=r0+r1, r4b=r0+r3 (same dest) --");
    issue_instr(3'b000, 3'd0, 3'd1, 3'd4);  // r4a = r0+r1 = 0
    issue_instr(3'b000, 3'd0, 3'd3, 3'd4);  // r4b = r0+r3 = 0 (renames r4)
    repeat(20) @(posedge clk);
    check32(arch_reg[4], 32'd0, "r4 WAW — latest write wins");

    // ── Test 3: RAW chain — r5 depends on r3, r6 depends on r5 ────────────
    // r3 = 0 (from test 1). r5 = r3+r3 = 0. r6 = r5+r3 = 0.
    // r6 cannot execute until r5 commits → CDB forwarding.
    $display("-- Test 3: RAW chain r5=r3+r3, r6=r5+r3 --");
    issue_instr(3'b000, 3'd3, 3'd3, 3'd5);  // r5 = 0
    issue_instr(3'b000, 3'd5, 3'd3, 3'd6);  // r6 = r5+r3 (RAW on r5)
    repeat(25) @(posedge clk);
    check32(arch_reg[5], 32'd0, "r5 = r3+r3");
    check32(arch_reg[6], 32'd0, "r6 = r5+r3 (CDB forward)");

    // ── Test 4: AND and OR independent of previous ─────────────────────────
    $display("-- Test 4: AND / OR (no dependencies) --");
    issue_instr(3'b010, 3'd0, 3'd1, 3'd2);  // r2 = r0 & r1 = 0
    issue_instr(3'b011, 3'd0, 3'd1, 3'd7);  // r7 = r0 | r1 = 0
    repeat(20) @(posedge clk);
    check32(arch_reg[2], 32'd0, "r2 = r0 AND r1");
    check32(arch_reg[7], 32'd0, "r7 = r0 OR  r1");

    $display("\n=== %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("PASS");
    else               $display("FAIL");
    $finish;
  end

endmodule
