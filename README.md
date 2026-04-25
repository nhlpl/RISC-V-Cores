**Codon 304: The φ‑Core Blueprint**  
*In which the Ring‑7 Mk IV distills the architecture of each RISC‑V core into a **forge‑ready blueprint** – a specification that guides implementation, verification, and integration. These blueprints are the **osteoderm schematics** for your GitHub repository.*

---

## 1. TinyΦ – Ultra‑Lightweight RV32I Core

### 1.1 Top‑Level Interface
```verilog
module tinyφ (
    input  wire        clk,
    input  wire        rst_n,
    // Instruction memory interface (Wishbone)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,
    output wire        imem_cyc,
    input  wire        imem_ack,
    // Data memory interface (Wishbone)
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_data_wr,
    input  wire [31:0] dmem_data_rd,
    output wire [3:0]  dmem_sel,
    output wire        dmem_we,
    output wire        dmem_cyc,
    input  wire        dmem_ack,
    // External interrupt
    input  wire        irq
);
```

### 1.2 Pipeline (2‑stage: Fetch / Execute)
- **Fetch**: `pc` register, `imem` request, `pc_next = pc + 4` (or branch target).
- **Execute**: ALU, branch resolution, register file writeback.

### 1.3 Register File
- 32 × 32‑bit registers, two read ports, one write port (synchronous write).
- `x0` hardwired to zero.

### 1.4 Instruction Set
- **Base**: RV32I (all except FENCE, ECALL/EBREAK minimal).
- **M** extension (mul/div – multi‑cycle, not pipelined).
- **C** extension (optional, compressed 16‑bit instructions).

### 1.5 Control Logic
- Branch taken: `{beq, bne, blt, bge, bltu, bgeu}` compare registers, set `pc`.
- Jump: `jal`, `jalr` with computed target.

### 1.6 Memory Access
- `lw`, `sw` – aligned only (byte/halfword optional for small area).
- Data memory interface uses `dmem_sel` for byte strobes.

### 1.7 Verification Blueprint
- **Tests**: RISC‑V Architectural Test Suite (`riscv-tests/isa/rv32ui`).
- **Fuzzing**: Random instruction generator with Spike comparison.
- **Coverage**: Branch, ALU opcode, load/store address ranges.

---

## 2. MonoΦ – 5‑Stage In‑Order Core (RV32IMFC)

### 2.1 Pipeline Stages
| Stage | Logic |
|-------|-------|
| Fetch (F) | Instruction fetch from I‑cache |
| Decode (D) | Decode, read register file |
| Execute (E) | ALU, branch resolution, address generation |
| Memory (M) | Data cache access (load/store) |
| Writeback (W) | Write result to register file |

### 2.2 Hazard Resolution
- **Forwarding**: from E, M, W to E (ALU input mux).
- **Load‑use stall**: insert bubble if instruction in D loads and next uses result.

### 2.3 Branch Predictor
- Static always‑not‑taken; flush pipeline on branch mispredict.
- Optional: 2‑bit saturating counter (BTB) for future upgrade.

### 2.4 Caches
- **I‑cache**: 8KB, direct‑mapped, 32‑byte line.
- **D‑cache**: 8KB, write‑through, 32‑byte line (write‑back optional).

### 2.5 CSRs (Machine Mode)
- `mcycle`, `minstret`, `mstatus`, `mtvec`, `mepc`, `mcause`.
- Trap handling: synchronous (ecall, illegal instruction) and asynchronous (interrupts).

### 2.6 Verification Blueprint
- **Tests**: Full RISC‑V Formal compliance tests (riscv‑formal).
- **Random instruction sequences** (short, 1k instructions) with Spike.
- **Cache coherence**: Run multi‑core only in isolation; for this core, single‑core only.

---

## 3. DualΦ – Dual‑Issue Out‑of‑Order Core (RV64IMAFD)

### 3.1 Microarchitecture Overview
- **Fetch**: 4 instructions per cycle from I‑cache.
- **Decode**: Map to two issue slots (Slot0: ALU/BRU, Slot1: MUL/DIV/LSU).
- **Rename**: 32‑entry physical register file (renames 32 logical to 64 physical).
- **Issue queue**: 16 entries, wake‑on‑operand‑ready.
- **ROB (Reorder Buffer)**: 32 entries, commits in order.

### 3.2 Execution Units
- ALU, BRU (branch), IMULDIV (integer multiply/divide), FPU (F/D).
- LSU (load/store) with address generation.

### 3.3 Memory Subsystem
- L1 I/D caches: 32KB each, 4‑way set‑associative.
- L2 unified cache: 256KB, 8‑way, inclusive.
- MMU: SV39 for Linux.

### 3.4 Verification Blueprint
- **Formal**: Prove forwarding and rename logic with SymbiYosys (abstracted).
- **Random**: Long‑run randomised instruction sequences (millions) with reference.
- **Linux boot**: Buildroot + kernel boot in simulation.

---

## 4. VectorΦ – RVV 1.0 Vector Coprocessor

### 4.1 Architecture
- **Vector length (VLEN)**: 256 bits.
- **Element width (ELEN)**: 64 bits.
- **Vector registers (v0‑v31)**: 32 × 256 bits (8.2 KiB total).
- **Video of pipeline**:  
  VDecode → VIssue → VLane0..3 → VWriteback

### 4.2 Vector Functional Units
| Unit | Operations |
|------|------------|
| V‑ALU | integer add/sub, shift, bitwise |
| V‑FPU | FP add/mul (supported via soft float or hard FPU) |
| V‑LSU | unit‑stride, strided, indexed (gather/scatter) |
| V‑MASK | mask logic, compare, set |

### 4.3 Control
- `vsetvli`, `vsetvl` for configuration.
- Strip‑mining loop hardware (automatic element count handling).

### 4.4 Integration with Host Core
- Attached via custom coprocessor interface (e.g., `custom0/1` opcodes).
- Or as tightly coupled unit inside DualΦ (shared register renaming).

### 4.5 Verification Blueprint
- **RVV tests** from `riscv-vector-tests`.
- Random vector instruction sequences with `riscv‑isac` reference model.

---

## 5. SwarmΦ – Many‑Core Tile Cluster (32 Cores)

### 5.1 Tile Architecture
- Each tile contains: 1× TinyΦ core, 16KB private L1 I/D (shared), network router.
- 2‑D mesh topology (8×4 or 6×6 depending on count).

### 5.2 Cache Coherence (MOESI)
- **L1**: write‑through to L2 (or write‑back with state bits).
- **L2**: banked per tile, directory‑based (full‑map).
- **Protocol**: MOESI (Modified, Owned, Exclusive, Shared, Invalid).

### 5.3 Network‑on‑Chip (NoC)
- **Router**: 5‑port (N,E,S,W,local), wormhole switching, credit‑based flow control.
- **Routing**: deterministic XY.
- **Virtual channels**: 2 (request, response) to avoid deadlock.

### 5.4 Global Memory
- **Shared L3** (off‑tile) or DRAM controller via AXI.

### 5.5 Synchronisation
- Atomic operations: `amoswap`, `amoadd`, etc. (RV32A).
- Barriers: `fence` and `fence.i`.

### 5.6 Verification Blueprint
- **For each core**: same as TinyΦ.
- **Coherence tests**: Parallel read‑modify‑write, false sharing, migratory sharing.
- **NoC latency/throughput**: synthetic traffic patterns.
- **Full system**: Run matrix multiplication and parallel histogram with OpenMP.

---

## 6. Common Infrastructure & Deliverables

### 6.1 Project Structure
```
φ‑cores/
├── tinyφ/
│   ├── rtl/ (tinyφ.v, tinyφ_alu.v, ...)
│   ├── sim/ (testbench, Makefile)
│   ├── docs/
│   └── README.md
├── monoφ/ (similar)
├── dualφ/ (similar)
├── vectorφ/ (similar)
├── swarmφ/ (similar)
├── common/ (wishbone_bus, axi_lite, ram_models)
├── verification/ (shared test harness, RISC‑V tests submodule)
└── CI/ (GitHub Actions)
```

### 6.2 Synthesis and FPGA
- **Target FPGA**: Lattice iCE40 (TinyΦ), Artix‑7 (MonoΦ), Kintex/Virtex (Vector/Swarm).
- **Synthesis script**: Yosys + nextpnr or Xilinx Vivado.
- **Example constraint files**: `.pcf` or `.xdc`.

### 6.3 Verification Tooling
- **Simulators**: Verilator (fast cycle‑accurate), Icarus Verilog.
- **Formal**: SymbiYosys (for small modules).
- **Reference model**: Spike (RISC‑V ISA simulator).
- **Coverage**: `gcov` for Verilator, `cover` in Verilator.

### 6.4 Continuous Integration
- On push: run `make test` for each core (quick random tests only).
- On release: run full regression (~1M tests per core) using cloud runners.
