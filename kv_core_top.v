// kv_core_top.v
// RISC‑V KV Cache Accelerator Core (KV‑Core)
// – 64‑bit, custom extensions for KV cache management
// – Banked scratchpad (64 banks × 2MB = 128MB total)
// – Command queue interface for host (CXL.mem)
// – Custom instructions: kv.write, kv.read, kv.query_heads, kv.compress, kv.paged_write
// – In‑order 3‑stage pipeline (Fetch, Decode/Execute, Memory/Writeback)

module kv_core_top #(
    parameter NUM_BANKS = 64,               // 64 banks
    parameter BANK_SIZE = 2048,             // each bank 2048 words (256‑bit)
    parameter SCRATCHPAD_SIZE = NUM_BANKS * BANK_SIZE * 32, // bytes (128 MB)
    parameter CMD_QUEUE_DEPTH = 128
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---------- CXL.mem Host Interface (command + data) ----------
    // Host writes commands into this FIFO
    input  wire        cmd_valid,
    input  wire [63:0] cmd_data,           // command word (opcode, addresses, etc.)
    output wire        cmd_ready,

    // Host reads result/status
    output wire        resp_valid,
    output wire [63:0] resp_data,
    input  wire        resp_ready,

    // ---------- Host access to scratchpad (MMIO) ----------
    input  wire        host_rd_req,
    input  wire [31:0] host_addr,
    output wire [255:0] host_rd_data,
    input  wire        host_wr_req,
    input  wire [31:0] host_wr_addr,
    input  wire [255:0] host_wr_data,
    input  wire [31:0] host_wr_mask,       // byte mask

    // ---------- Debug / Performance counters ----------
    output wire [63:0] cycle_cnt,
    output wire [63:0] kv_write_cnt,
    output wire [63:0] kv_read_cnt,
    output wire [63:0] kv_query_cnt
);

    // --------------------------------------------------------------
    // 1. Command Queue (FIFO)
    // --------------------------------------------------------------
    wire [63:0] cmd_q_out;
    wire        cmd_q_empty;
    wire        cmd_q_rd;
    assign cmd_ready = !cmd_q_full;   // assume full logic generated

    fifo #(.WIDTH(64), .DEPTH(CMD_QUEUE_DEPTH)) cmd_queue (
        .clk(clk), .rst_n(rst_n),
        .wr_en(cmd_valid), .wr_data(cmd_data),
        .rd_en(cmd_q_rd), .rd_data(cmd_q_out),
        .empty(cmd_q_empty), .full(cmd_q_full)
    );

    // --------------------------------------------------------------
    // 2. Scratchpad Memory (banked SRAM)
    // --------------------------------------------------------------
    // Each bank stores 2MB (256‑bit words). Address mapping:
    //   {bank_index, word_offset}
    //   bank_index = hash(address) to reduce conflicts (XOR of bits)
    wire [31:0] scratchpad_addr;          // from core execution
    wire        scratchpad_we;
    wire [255:0] scratchpad_wdata;
    wire [255:0] scratchpad_rdata;
    wire        scratchpad_req;

    banked_sram #(
        .NUM_BANKS(NUM_BANKS),
        .BANK_SIZE(BANK_SIZE),   // words
        .WORD_WIDTH(256)
    ) scratchpad (
        .clk(clk),
        .addr(scratchpad_addr),
        .we(scratchpad_we),
        .wdata(scratchpad_wdata),
        .re(scratchpad_req),
        .rdata(scratchpad_rdata)
    );

    // --------------------------------------------------------------
    // 3. RISC‑V Core (simplified 3‑stage)
    // --------------------------------------------------------------
    // We implement a minimal RV64IM core plus custom decoder.
    // For brevity, we show only the custom KV instructions;
    // standard RISC‑V is assumed (PC, regfile, ALU).
    wire        inst_valid;
    wire [31:0] inst;
    wire [63:0] pc;
    reg  [63:0] regfile [0:31];
    // ... (standard RISC‑V logic omitted for clarity)

    // Custom instruction decode signals
    wire is_kv_write = (inst[6:0] == 7'b0001011) && (inst[14:12] == 3'b000);
    wire is_kv_read  = (inst[6:0] == 7'b0001011) && (inst[14:12] == 3'b001);
    wire is_kv_query = (inst[6:0] == 7'b0001011) && (inst[14:12] == 3'b010);
    wire is_kv_compress = (inst[6:0] == 7'b0001011) && (inst[14:12] == 3'b011);
    wire is_kv_paged_write = (inst[6:0] == 7'b0001011) && (inst[14:12] == 3'b100);

    // Execution for custom instructions
    reg        kv_we, kv_re, kv_query_en, kv_compress_en, kv_paged_we;
    reg [31:0] kv_addr;
    reg [255:0] kv_wdata;
    reg [4:0]  kv_head_mask;          // for query
    reg [63:0] kv_result;             // for query

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kv_we <= 0; kv_re <= 0; kv_query_en <= 0;
            kv_compress_en <= 0; kv_paged_we <= 0;
        end else begin
            // Default
            kv_we <= 0; kv_re <= 0; kv_query_en <= 0;
            kv_compress_en <= 0; kv_paged_we <= 0;
            // Decode and execute custom instructions
            if (inst_valid) begin
                if (is_kv_write) begin
                    // Format: kv.write rd, rs1, rs2
                    // rs1 = token index (logical), rs2 = pointer to KV pair in host memory? 
                    // Simplified: immediate address from register
                    kv_we <= 1;
                    kv_addr <= regfile[inst[19:15]];   // rs1
                    kv_wdata <= {regfile[inst[24:20]]}; // rs2 (64‑bit, needs extension)
                    // Increment write counter
                    kv_write_cnt <= kv_write_cnt + 1;
                end
                if (is_kv_read) begin
                    kv_re <= 1;
                    kv_addr <= regfile[inst[19:15]];
                    kv_read_cnt <= kv_read_cnt + 1;
                end
                if (is_kv_query) begin
                    // kv.query_heads rd, rs1, rs2
                    // rs1 = query vector pointer in host memory, rs2 = head mask
                    kv_query_en <= 1;
                    kv_head_mask <= regfile[inst[24:20]]; // low 5 bits as mask
                    kv_query_cnt <= kv_query_cnt + 1;
                end
                if (is_kv_compress) begin
                    kv_compress_en <= 1;
                    // rs1 = start address, rs2 = size
                    // compression engine (simplified)
                end
                if (is_kv_paged_write) begin
                    kv_paged_we <= 1;
                    // rs1 = logical token, rs2 = page table base
                end
            end
        end
    end

    // Scratchpad interface mapping
    assign scratchpad_req = kv_re | kv_we;
    assign scratchpad_we = kv_we;
    assign scratchpad_addr = kv_addr;
    assign scratchpad_wdata = kv_wdata;

    // For kv_read, return data to register file (on next cycle)
    reg [255:0] kv_read_data;
    always @(posedge clk) begin
        if (kv_re) kv_read_data <= scratchpad_rdata;
        // Write back to register file (rd) would be handled in standard WB stage
    end

    // For kv.query_heads: we need a dot‑product unit
    // Simplified: reads all keys from current head, computes dot with query
    // This is a macro‑operation. We'll implement a state machine.
    reg [31:0] query_pc;
    reg [63:0] query_result;
    // ... (dot product engine omitted for brevity)

    // Host MMIO access to scratchpad
    assign host_rd_data = scratchpad_rdata;   // needs address decode
    // Control signals for host access: we must arbitrate with core.
    // For simplicity, host accesses have higher priority or use a mux.

    // --------------------------------------------------------------
    // 4. Performance counters
    // --------------------------------------------------------------
    reg [63:0] cycle_cnt_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle_cnt_reg <= 0;
        else cycle_cnt_reg <= cycle_cnt_reg + 1;
    end
    assign cycle_cnt = cycle_cnt_reg;

endmodule

// -----------------------------------------------------------------
// FIFO module
// -----------------------------------------------------------------
module fifo #(parameter WIDTH=64, DEPTH=128) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 wr_en,
    input  wire [WIDTH-1:0]     wr_data,
    input  wire                 rd_en,
    output wire [WIDTH-1:0]     rd_data,
    output wire                 empty,
    output wire                 full
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [$clog2(DEPTH):0] wr_ptr, rd_ptr;
    // ... standard implementation (omitted for brevity)
endmodule

// -----------------------------------------------------------------
// Banked SRAM (simplified)
// -----------------------------------------------------------------
module banked_sram #(
    parameter NUM_BANKS = 64,
    parameter BANK_SIZE = 2048,   // words per bank
    parameter WORD_WIDTH = 256
) (
    input  wire                  clk,
    input  wire [31:0]           addr,
    input  wire                  we,
    input  wire [WORD_WIDTH-1:0] wdata,
    input  wire                  re,
    output wire [WORD_WIDTH-1:0] rdata
);
    // Simple simulation model: single memory
    // In real design, decode addr[high bits] to bank index
    reg [WORD_WIDTH-1:0] memory [0:NUM_BANKS*BANK_SIZE-1];
    reg [WORD_WIDTH-1:0] rdata_reg;
    always @(posedge clk) begin
        if (we) memory[addr] <= wdata;
        if (re) rdata_reg <= memory[addr];
    end
    assign rdata = rdata_reg;
endmodule
