/**
 * reservation_station.sv — Reservation Station Array
 * ─────────────────────────────────────────────────────────────────────────────
 * Holds instructions waiting for operands. An entry is ready to execute
 * when both qj_ready and qk_ready are asserted.
 *
 * Ports:
 *   issue_*   — Writes a new entry at the given index
 *   cdb_*     — CDB broadcast: updates any entry waiting on this tag
 *   dispatch_* — Outputs the lowest-indexed ready entry each cycle
 *   free_idx  — Returns the lowest free (not busy) entry index
 * ─────────────────────────────────────────────────────────────────────────────
 */

module reservation_station #(
  parameter int RS_SIZE    = 8,
  parameter int ROB_TAG_W  = 3
)(
  input  logic        clk,
  input  logic        rst_n,

  // ── Issue port ────────────────────────────────────────────────────────────
  input  logic        issue_en,
  input  logic [$clog2(RS_SIZE)-1:0] issue_idx,
  input  logic [2:0]  issue_op,
  input  logic [31:0] issue_vj,
  input  logic        issue_qj_ready,
  input  logic [ROB_TAG_W-1:0] issue_qj,
  input  logic [31:0] issue_vk,
  input  logic        issue_qk_ready,
  input  logic [ROB_TAG_W-1:0] issue_qk,
  input  logic [ROB_TAG_W-1:0] issue_dest,

  // ── CDB broadcast ─────────────────────────────────────────────────────────
  input  logic        cdb_valid,
  input  logic [ROB_TAG_W-1:0] cdb_tag,
  input  logic [31:0] cdb_data,

  // ── Free entry query ──────────────────────────────────────────────────────
  output logic        rs_free,
  output logic [$clog2(RS_SIZE)-1:0] rs_free_idx,

  // ── Dispatch: first ready entry ───────────────────────────────────────────
  output logic        dispatch_valid,
  output logic [$clog2(RS_SIZE)-1:0] dispatch_idx,
  output logic [2:0]  dispatch_op,
  output logic [31:0] dispatch_vj,
  output logic [31:0] dispatch_vk,
  output logic [ROB_TAG_W-1:0] dispatch_dest,

  // ── Free entry after dispatch ─────────────────────────────────────────────
  input  logic        dispatch_ack,     // Pulse from execution unit to free the entry
  input  logic [$clog2(RS_SIZE)-1:0] dispatch_free_idx
);

  // ── Storage ───────────────────────────────────────────────────────────────
  logic        busy      [0:RS_SIZE-1];
  logic [2:0]  op        [0:RS_SIZE-1];
  logic [31:0] vj        [0:RS_SIZE-1];
  logic        qj_ready  [0:RS_SIZE-1];
  logic [ROB_TAG_W-1:0] qj [0:RS_SIZE-1];
  logic [31:0] vk        [0:RS_SIZE-1];
  logic        qk_ready  [0:RS_SIZE-1];
  logic [ROB_TAG_W-1:0] qk [0:RS_SIZE-1];
  logic [ROB_TAG_W-1:0] dest [0:RS_SIZE-1];

  // ── Free entry (lowest index not busy) ───────────────────────────────────
  always_comb begin
    rs_free = 1'b0; rs_free_idx = '0;
    for (int i = RS_SIZE-1; i >= 0; i--)
      if (!busy[i]) begin rs_free = 1'b1; rs_free_idx = $clog2(RS_SIZE)'(i); end
  end

  // ── Dispatch (lowest-index ready entry) ────────────────────────────────────
  always_comb begin
    dispatch_valid = 1'b0; dispatch_idx = '0;
    dispatch_op = '0; dispatch_vj = '0; dispatch_vk = '0; dispatch_dest = '0;
    for (int i = RS_SIZE-1; i >= 0; i--)
      if (busy[i] && qj_ready[i] && qk_ready[i]) begin
        dispatch_valid = 1'b1;
        dispatch_idx   = $clog2(RS_SIZE)'(i);
        dispatch_op    = op[i];
        dispatch_vj    = vj[i];
        dispatch_vk    = vk[i];
        dispatch_dest  = dest[i];
      end
  end

  // ── Sequential logic ──────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i=0;i<RS_SIZE;i++) begin
        busy[i]<=0; qj_ready[i]<=0; qk_ready[i]<=0;
      end
    end else begin
      // Issue
      if (issue_en) begin
        busy[issue_idx]     <= 1;
        op[issue_idx]       <= issue_op;
        vj[issue_idx]       <= issue_vj;
        qj_ready[issue_idx] <= issue_qj_ready;
        qj[issue_idx]       <= issue_qj;
        vk[issue_idx]       <= issue_vk;
        qk_ready[issue_idx] <= issue_qk_ready;
        qk[issue_idx]       <= issue_qk;
        dest[issue_idx]     <= issue_dest;
      end

      // CDB capture
      if (cdb_valid) begin
        for (int i=0;i<RS_SIZE;i++) begin
          if (busy[i]) begin
            if (!qj_ready[i] && qj[i]==cdb_tag) begin vj[i]<=cdb_data; qj_ready[i]<=1; end
            if (!qk_ready[i] && qk[i]==cdb_tag) begin vk[i]<=cdb_data; qk_ready[i]<=1; end
          end
        end
      end

      // Free after dispatch
      if (dispatch_ack) busy[dispatch_free_idx] <= 0;
    end
  end

endmodule
