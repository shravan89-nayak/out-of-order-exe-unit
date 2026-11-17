/**
 * ooo_exec.sv — Out-of-Order Execution Unit (Top Level)
 * ─────────────────────────────────────────────────────────────────────────────
 * Integrates: reservation_station, reorder_buffer, ALU, RAT, and ARF.
 * Implements Tomasulo's algorithm for operations: ADD SUB AND OR MUL(2cy).
 * ─────────────────────────────────────────────────────────────────────────────
 */
// Added sample code to get you started. Feel free to modify as needed!

module ooo_exec #(
  parameter int RS_SIZE  = 8,
  parameter int ROB_SIZE = 8,
  parameter int REGS     = 8
)(
  input  logic        clk,
  input  logic        rst_n,

  // ── Issue interface ───────────────────────────────────────────────────────
  input  logic        issue_valid,
  input  logic [2:0]  issue_op,     // 000=ADD 001=SUB 010=AND 011=OR 100=MUL
  input  logic [2:0]  issue_rs1,
  input  logic [2:0]  issue_rs2,
  input  logic [2:0]  issue_rd,
  output logic        issue_ready,

  // ── Commit (in-order) ─────────────────────────────────────────────────────
  output logic        commit_valid,
  output logic [2:0]  commit_rd,
  output logic [31:0] commit_data,

  // ── Architectural register file (post-commit) ──────────────────────────────
  output logic [31:0] arch_reg [0:7]
);

  localparam int ROB_TAG_W = $clog2(ROB_SIZE);

  // ── ARF and RAT ───────────────────────────────────────────────────────────
  logic [31:0] arf [0:REGS-1];
  logic [ROB_TAG_W-1:0] rat [0:REGS-1];
  logic rat_pending [0:REGS-1];

  genvar gi;
  generate for (gi=0;gi<8;gi++) assign arch_reg[gi] = arf[gi]; endgenerate

  // ── RS instance ───────────────────────────────────────────────────────────
  logic        rs_free;
  logic [$clog2(RS_SIZE)-1:0] rs_free_idx;
  logic        dispatch_valid, dispatch_ack;
  logic [$clog2(RS_SIZE)-1:0] dispatch_idx;
  logic [2:0]  dispatch_op;
  logic [31:0] dispatch_vj, dispatch_vk;
  logic [ROB_TAG_W-1:0] dispatch_dest;
  logic        issue_rs_en;
  logic [$clog2(RS_SIZE)-1:0] issue_rs_idx;
  logic [31:0] issue_vj, issue_vk;
  logic        issue_qj_ready, issue_qk_ready;
  logic [ROB_TAG_W-1:0] issue_qj_tag, issue_qk_tag;
  logic [ROB_TAG_W-1:0] issue_dest;
  logic        cdb_valid;
  logic [ROB_TAG_W-1:0] cdb_tag;
  logic [31:0] cdb_data;

  reservation_station #(.RS_SIZE(RS_SIZE),.ROB_TAG_W(ROB_TAG_W)) u_rs (
    .clk(clk),.rst_n(rst_n),
    .issue_en(issue_rs_en),.issue_idx(issue_rs_idx),
    .issue_op(issue_op),.issue_vj(issue_vj),.issue_qj_ready(issue_qj_ready),
    .issue_qj(issue_qj_tag),.issue_vk(issue_vk),.issue_qk_ready(issue_qk_ready),
    .issue_qk(issue_qk_tag),.issue_dest(issue_dest),
    .cdb_valid(cdb_valid),.cdb_tag(cdb_tag),.cdb_data(cdb_data),
    .rs_free(rs_free),.rs_free_idx(rs_free_idx),
    .dispatch_valid(dispatch_valid),.dispatch_idx(dispatch_idx),
    .dispatch_op(dispatch_op),.dispatch_vj(dispatch_vj),.dispatch_vk(dispatch_vk),
    .dispatch_dest(dispatch_dest),
    .dispatch_ack(dispatch_ack),.dispatch_free_idx(dispatch_idx)
  );

  // ── ROB instance ──────────────────────────────────────────────────────────
  logic        rob_full, rob_commit_valid, rob_commit_ack;
  logic [ROB_TAG_W-1:0] rob_alloc_tag, rob_commit_tag;
  logic [2:0]  rob_commit_rd;
  logic [31:0] rob_commit_data;
  logic [ROB_TAG_W-1:0] rob_lookup_tag;
  logic        rob_lookup_done;
  logic [31:0] rob_lookup_data;

  reorder_buffer #(.ROB_SIZE(ROB_SIZE),.ROB_TAG_W(ROB_TAG_W)) u_rob (
    .clk(clk),.rst_n(rst_n),
    .alloc_en(issue_rs_en),.alloc_rd(issue_rd),.alloc_tag(rob_alloc_tag),.full(rob_full),
    .write_en(cdb_valid),.write_tag(cdb_tag),.write_data(cdb_data),
    .commit_valid(rob_commit_valid),.commit_tag(rob_commit_tag),
    .commit_rd(rob_commit_rd),.commit_data(rob_commit_data),.commit_ack(rob_commit_ack),
    .lookup_tag(rob_lookup_tag),.lookup_done(rob_lookup_done),.lookup_data(rob_lookup_data)
  );

  // ── Issue combinational ───────────────────────────────────────────────────
  assign issue_ready    = rs_free && !rob_full;
  assign issue_rs_en    = issue_valid && issue_ready;
  assign issue_rs_idx   = rs_free_idx;
  assign issue_dest     = rob_alloc_tag;

  // Operand lookup: check RAT then ARF
  assign issue_qj_ready = !rat_pending[issue_rs1] || (rat_pending[issue_rs1] && rob_lookup_done);
  assign rob_lookup_tag = rat[issue_rs1];  // Lookup rs1 by default (simplified)
  assign issue_vj       = rat_pending[issue_rs1]
                          ? (rob_lookup_done ? rob_lookup_data : 32'd0)
                          : arf[issue_rs1];
  assign issue_qj_tag   = rat[issue_rs1];

  // rs2 lookup (simplified: reuse same lookup port, assume no simultaneous conflict)
  assign issue_qk_ready = !rat_pending[issue_rs2];
  assign issue_vk       = rat_pending[issue_rs2] ? 32'd0 : arf[issue_rs2];
  assign issue_qk_tag   = rat[issue_rs2];

  // ── Execution pipeline ────────────────────────────────────────────────────
  logic        ex_busy;
  logic [1:0]  ex_latency;
  logic [31:0] ex_result;
  logic [ROB_TAG_W-1:0] ex_dest;

  assign dispatch_ack = dispatch_valid && !ex_busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_busy<=0; ex_latency<=0; ex_result<=0; ex_dest<=0;
      cdb_valid<=0; cdb_tag<=0; cdb_data<=0;
      commit_valid<=0; commit_rd<=0; commit_data<=0;
      rob_commit_ack<=0;
      for (int i=0;i<REGS;i++) begin arf[i]<='0; rat[i]<='0; rat_pending[i]<=0; end
    end else begin
      cdb_valid<=0; commit_valid<=0; rob_commit_ack<=0;

      // RAT update on issue
      if (issue_rs_en) begin
        rat[issue_rd]         <= rob_alloc_tag;
        rat_pending[issue_rd] <= 1;
      end

      // Execute
      if (!ex_busy && dispatch_valid) begin
        ex_busy    <= 1;
        ex_dest    <= dispatch_dest;
        ex_latency <= (dispatch_op==3'b100) ? 2'd2 : 2'd1;
        case (dispatch_op)
          3'b000: ex_result <= dispatch_vj + dispatch_vk;
          3'b001: ex_result <= dispatch_vj - dispatch_vk;
          3'b010: ex_result <= dispatch_vj & dispatch_vk;
          3'b011: ex_result <= dispatch_vj | dispatch_vk;
          3'b100: ex_result <= dispatch_vj * dispatch_vk;
          default: ex_result <= '0;
        endcase
      end else if (ex_busy) begin
        ex_latency <= ex_latency - 1;
        if (ex_latency == 1) begin
          ex_busy   <= 0;
          cdb_valid <= 1;
          cdb_tag   <= ex_dest;
          cdb_data  <= ex_result;
        end
      end

      // Commit
      if (rob_commit_valid) begin
        arf[rob_commit_rd]         <= rob_commit_data;
        if (rat_pending[rob_commit_rd] && rat[rob_commit_rd]==rob_commit_tag)
          rat_pending[rob_commit_rd] <= 0;
        commit_valid <= 1;
        commit_rd    <= rob_commit_rd;
        commit_data  <= rob_commit_data;
        rob_commit_ack <= 1;
      end
    end
  end

endmodule
