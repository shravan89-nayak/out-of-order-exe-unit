/**
 * reorder_buffer.sv — Reorder Buffer (ROB)
 * ─────────────────────────────────────────────────────────────────────────────
 * A circular buffer maintaining in-program-order retirement of instructions.
 * Instructions enter at the tail and retire from the head — always in order,
 * regardless of when they actually executed.
 *
 * This is what enables precise exceptions: any instruction that faults causes
 * all later instructions to be squashed from the ROB tail without ever
 * committing their results to architectural state.
 * ─────────────────────────────────────────────────────────────────────────────
 */

module reorder_buffer #(
  parameter int ROB_SIZE   = 8,
  parameter int ROB_TAG_W  = 3   // Must equal $clog2(ROB_SIZE)
)(
  input  logic        clk,
  input  logic        rst_n,

  // ── Allocate port (called at issue) ──────────────────────────────────────
  input  logic        alloc_en,
  input  logic [2:0]  alloc_rd,         // Architectural destination register
  output logic [ROB_TAG_W-1:0] alloc_tag, // Assigned ROB tag
  output logic        full,

  // ── Write result (called on CDB broadcast) ────────────────────────────────
  input  logic        write_en,
  input  logic [ROB_TAG_W-1:0] write_tag,
  input  logic [31:0] write_data,

  // ── Commit port (retire head of ROB) ─────────────────────────────────────
  output logic        commit_valid,
  output logic [ROB_TAG_W-1:0] commit_tag,
  output logic [2:0]  commit_rd,
  output logic [31:0] commit_data,
  input  logic        commit_ack,       // Pulse to advance ROB head

  // ── Lookup: read ROB entry (for issue-time operand capture) ───────────────
  input  logic [ROB_TAG_W-1:0] lookup_tag,
  output logic        lookup_done,
  output logic [31:0] lookup_data
);

  typedef struct packed {
    logic        busy;
    logic        done;
    logic [2:0]  rd;
    logic [31:0] value;
  } rob_entry_t;

  rob_entry_t entries [0:ROB_SIZE-1];

  logic [ROB_TAG_W-1:0] head, tail;
  logic empty;

  assign full         = ((tail + 1) % ROB_SIZE) == head && entries[tail].busy;
  assign empty        = !entries[head].busy;
  assign alloc_tag    = tail;
  assign commit_valid = !empty && entries[head].done;
  assign commit_tag   = head;
  assign commit_rd    = entries[head].rd;
  assign commit_data  = entries[head].value;
  assign lookup_done  = entries[lookup_tag].done;
  assign lookup_data  = entries[lookup_tag].value;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head <= '0; tail <= '0;
      for (int i=0;i<ROB_SIZE;i++) entries[i] <= '0;
    end else begin
      // Allocate at tail
      if (alloc_en && !full) begin
        entries[tail].busy  <= 1;
        entries[tail].done  <= 0;
        entries[tail].rd    <= alloc_rd;
        entries[tail].value <= '0;
        tail <= ROB_TAG_W'((tail + 1) % ROB_SIZE);
      end

      // Write result from CDB
      if (write_en) begin
        entries[write_tag].done  <= 1;
        entries[write_tag].value <= write_data;
      end

      // Commit head
      if (commit_ack && commit_valid) begin
        entries[head].busy <= 0;
        head <= ROB_TAG_W'((head + 1) % ROB_SIZE);
      end
    end
  end

endmodule
