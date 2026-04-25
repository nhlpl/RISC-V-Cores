// sv1_top.v
// SV‑1 "Silicon Mirror" – RISC‑V KV‑Cache Accelerator Chiplet
// 32 δ‑cores + custom extensions (Zkva, Zgsm), 128 MiB scratchpad, 128 MiB L2,
// HBM3e interface, CXL 3.0 host interface, DMAC for paging.

module sv1_top (
    // Clock & reset
    input  wire        clk_main,
    input  wire        rst_n,

    // CXL 3.0 Host Interface (simplified – PCIe‑like)
    input  wire [63:0] cxl_rx_data,
    input  wire        cxl_rx_valid,
    output wire        cxl_rx_ready,
    output wire [63:0] cxl_tx_data,
    output wire        cxl_tx_valid,
    input  wire        cxl_tx_ready,

    // HBM3e Interface (simplified – AXI-like)
    output wire [31:0] hbm_awaddr,
    output wire [7:0]  hbm_awlen,
    output wire        hbm_awvalid,
    input  wire        hbm_awready,
    output wire [511:0] hbm_wdata,
    output wire [63:0]  hbm_wstrb,
    output wire        hbm_wvalid,
    input  wire        hbm_wready,
    input  wire [511:0] hbm_rdata,
    input  wire        hbm_rvalid,
    output wire        hbm_rready,
    input  wire [31:0] hbm_araddr,
    input  wire [7:0]  hbm_arlen,
    input  wire        hbm_arvalid,
    output wire        hbm_arready,

    // UCIe die‑to‑die links (to other chiplets)
    input  wire [31:0] ucie_rx_data,
    input  wire        ucie_rx_valid,
    output wire        ucie_rx_ready,
    output wire [31:0] ucie_tx_data,
    output wire        ucie_tx_valid,
    input  wire        ucie_tx_ready,

    // Status LEDs / debug
    output wire [31:0] status_leds
);

    // --------------------------------------------------------------
    // Parameters
    // --------------------------------------------------------------
    localparam NUM_CORES = 32;
    localparam SCRATCHPAD_SIZE_BYTES = 4 * 1024 * 1024;   // 4 MiB per core
    localparam L2_SIZE_BYTES = 128 * 1024 * 1024;         // 128 MiB
    localparam HBM_CHANNELS = 2;                          // two HBM stacks

    // --------------------------------------------------------------
    // Wires
    // --------------------------------------------------------------
    // Host CXL decoder → command/response queues
    wire        host_cmd_valid;
    wire [63:0] host_cmd;
    wire        host_cmd_ready;
    wire        host_resp_valid;
    wire [63:0] host_resp;
    wire        host_resp_ready;

    // DMAC to memory hierarchy
    wire        dmac_req;
    wire [31:0] dmac_addr;
    wire        dmac_wr;
    wire [511:0] dmac_wdata;
    wire        dmac_rd;
    wire [511:0] dmac_rdata;
    wire        dmac_rvalid;

    // Core cluster interfaces (each core has its own ports)
    wire [NUM_CORES-1:0] core_scratchpad_req;
    wire [31:0] core_scratchpad_addr [0:NUM_CORES-1];
    wire [255:0] core_scratchpad_wdata [0:NUM_CORES-1];
    wire        core_scratchpad_we [0:NUM_CORES-1];
    wire [255:0] core_scratchpad_rdata [0:NUM_CORES-1];
    wire        core_scratchpad_rvalid [0:NUM_CORES-1];

    wire [NUM_CORES-1:0] core_l2_req;
    wire [31:0] core_l2_addr [0:NUM_CORES-1];
    wire [511:0] core_l2_wdata [0:NUM_CORES-1];
    wire        core_l2_we [0:NUM_CORES-1];
    wire [511:0] core_l2_rdata [0:NUM_CORES-1];
    wire        core_l2_rvalid [0:NUM_CORES-1];

    // DMAC to HBM controller
    wire        hbm_req;
    wire        hbm_wr;
    wire [31:0] hbm_addr;
    wire [511:0] hbm_wdata;
    wire        hbm_rd;
    wire [511:0] hbm_rdata;
    wire        hbm_rvalid;

    // --------------------------------------------------------------
    // 1. Host Interface (CXL 3.0 Type 2) – simplified as AXI Stream
    // --------------------------------------------------------------
    cxl_host_iface host_iface (
        .clk(clk_main), .rst_n(rst_n),
        .cxl_rx_data(cxl_rx_data), .cxl_rx_valid(cxl_rx_valid), .cxl_rx_ready(cxl_rx_ready),
        .cxl_tx_data(cxl_tx_data), .cxl_tx_valid(cxl_tx_valid), .cxl_tx_ready(cxl_tx_ready),
        .cmd_valid(host_cmd_valid), .cmd_data(host_cmd), .cmd_ready(host_cmd_ready),
        .resp_valid(host_resp_valid), .resp_data(host_resp), .resp_ready(host_resp_ready)
    );

    // --------------------------------------------------------------
    // 2. Command Decoder & DMAC Scheduler
    // --------------------------------------------------------------
    // Parses host commands (store/fetch/compact) and spawns DMAC transfers.
    // Also manages LRU‑φ paging table.
    kv_dmac dmac (
        .clk(clk_main), .rst_n(rst_n),
        .cmd_valid(host_cmd_valid), .cmd(host_cmd), .cmd_ready(host_cmd_ready),
        .resp_valid(host_resp_valid), .resp(host_resp), .resp_ready(host_resp_ready),
        // Memory interface (to L2 and HBM)
        .mem_req(hbm_req), .mem_wr(hbm_wr), .mem_addr(hbm_addr),
        .mem_wdata(hbm_wdata), .mem_rd(hbm_rd), .mem_rdata(hbm_rdata), .mem_rvalid(hbm_rvalid),
        // Scratchpad & L2 access for cores (bypass)
        .scratchpad_req(scratchpad_req), .scratchpad_addr(scratchpad_addr),
        .scratchpad_wdata(scratchpad_wdata), .scratchpad_we(scratchpad_we),
        .scratchpad_rdata(scratchpad_rdata), .scratchpad_rvalid(scratchpad_rvalid),
        .l2_req(l2_req), .l2_addr(l2_addr), .l2_wdata(l2_wdata),
        .l2_we(l2_we), .l2_rdata(l2_rdata), .l2_rvalid(l2_rvalid)
    );

    // --------------------------------------------------------------
    // 3. δ‑Core Cluster (32 RISC‑V cores with custom extensions)
    // --------------------------------------------------------------
    generate
        genvar i;
        for (i = 0; i < NUM_CORES; i = i + 1) begin : core_gen
            delta_core #(
                .CORE_ID(i),
                .SCRATCHPAD_SIZE(SCRATCHPAD_SIZE_BYTES)
            ) delta_core_inst (
                .clk(clk_main), .rst_n(rst_n),
                // Scratchpad port (TCM)
                .scratchpad_req(core_scratchpad_req[i]),
                .scratchpad_addr(core_scratchpad_addr[i]),
                .scratchpad_wdata(core_scratchpad_wdata[i]),
                .scratchpad_we(core_scratchpad_we[i]),
                .scratchpad_rdata(core_scratchpad_rdata[i]),
                .scratchpad_rvalid(core_scratchpad_rvalid[i]),
                // L2 cache port (for spills, warmup)
                .l2_req(core_l2_req[i]),
                .l2_addr(core_l2_addr[i]),
                .l2_wdata(core_l2_wdata[i]),
                .l2_we(core_l2_we[i]),
                .l2_rdata(core_l2_rdata[i]),
                .l2_rvalid(core_l2_rvalid[i]),
                // DMAC control (for pre‑warm)
                .dmac_control()   // optional
            );
        end
    endgenerate

    // --------------------------------------------------------------
    // 4. Per‑Core Scratchpad Memory (4 MiB each, banked SRAM)
    // --------------------------------------------------------------
    // For brevity, we instantiate a generic banked memory that serves all cores.
    // In reality, each core gets its own dedicated 4 MiB scratchpad.
    // Here we combine them into a single addressable array.
    wire [NUM_CORES-1:0] scratchpad_req;
    wire [31:0] scratchpad_addr;
    wire [255:0] scratchpad_wdata;
    wire        scratchpad_we;
    wire [255:0] scratchpad_rdata;
    wire        scratchpad_rvalid;

    // Crossbar to route core requests to scratchpad banks (simplified: direct mapping)
    scratchpad_crossbar #(
        .NUM_CORES(NUM_CORES),
        .BANK_SIZE(SCRATCHPAD_SIZE_BYTES / 64)   // 64 banks of 64 bytes each
    ) scratchpad_xbar (
        .clk(clk_main), .rst_n(rst_n),
        .core_req(core_scratchpad_req),
        .core_addr(core_scratchpad_addr),
        .core_wdata(core_scratchpad_wdata),
        .core_we(core_scratchpad_we),
        .core_rdata(core_scratchpad_rdata),
        .core_rvalid(core_scratchpad_rvalid),
        .mem_req(scratchpad_req),
        .mem_addr(scratchpad_addr),
        .mem_wdata(scratchpad_wdata),
        .mem_we(scratchpad_we),
        .mem_rdata(scratchpad_rdata),
        .mem_rvalid(scratchpad_rvalid)
    );

    // The actual SRAM array for all scratchpads
    sram_banked #(
        .NUM_BANKS(64),
        .BANK_DEPTH(SCRATCHPAD_SIZE_BYTES / 64 / 64), // 64 banks × 64‑byte lines → total 4 MiB
        .WORD_WIDTH(256)
    ) scratchpad_mem (
        .clk(clk_main),
        .addr(scratchpad_addr),
        .we(scratchpad_we),
        .wdata(scratchpad_wdata),
        .re(scratchpad_req),
        .rdata(scratchpad_rdata),
        .rvalid(scratchpad_rvalid)
    );

    // --------------------------------------------------------------
    // 5. Shared L2 Cache (128 MiB, 42‑way)
    // --------------------------------------------------------------
    wire l2_req;
    wire [31:0] l2_addr;
    wire [511:0] l2_wdata;
    wire        l2_we;
    wire [511:0] l2_rdata;
    wire        l2_rvalid;

    l2_surreal_cache #(
        .SIZE_BYTES(L2_SIZE_BYTES),
        .WAYS(42)
    ) l2_cache (
        .clk(clk_main), .rst_n(rst_n),
        .core_req(l2_req), .core_addr(l2_addr), .core_wdata(l2_wdata), .core_we(l2_we),
        .core_rdata(l2_rdata), .core_rvalid(l2_rvalid),
        .dmac_req(dmac_req), .dmac_addr(dmac_addr), .dmac_wr(dmac_wr), .dmac_wdata(dmac_wdata),
        .dmac_rd(dmac_rd), .dmac_rdata(dmac_rdata), .dmac_rvalid(dmac_rvalid),
        .hbm_req(hbm_req), .hbm_wr(hbm_wr), .hbm_addr(hbm_addr), .hbm_wdata(hbm_wdata),
        .hbm_rd(hbm_rd), .hbm_rdata(hbm_rdata), .hbm_rvalid(hbm_rvalid)
    );

    // --------------------------------------------------------------
    // 6. HBM Controller (AXI to HBM3e PHY)
    // --------------------------------------------------------------
    hbm_controller #(
        .CHANNELS(HBM_CHANNELS)
    ) hbm_ctrl (
        .clk(clk_main), .rst_n(rst_n),
        // AXI from L2/DMAC
        .awaddr(hbm_awaddr), .awlen(hbm_awlen), .awvalid(hbm_awvalid), .awready(hbm_awready),
        .wdata(hbm_wdata), .wstrb(hbm_wstrb), .wvalid(hbm_wvalid), .wready(hbm_wready),
        .rdata(hbm_rdata), .rvalid(hbm_rvalid), .rready(hbm_rready),
        .araddr(hbm_araddr), .arlen(hbm_arlen), .arvalid(hbm_arvalid), .arready(hbm_arready),
        // PHY side (to actual HBM stacks)
        .phy_*   // omitted
    );

    // --------------------------------------------------------------
    // 7. UCIe Die‑to‑Die Links (for multi‑chiplet coherence)
    // --------------------------------------------------------------
    ucie_link ucie (
        .clk(clk_main), .rst_n(rst_n),
        .rx_data(uci
