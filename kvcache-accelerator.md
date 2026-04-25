## RISC‑V KV Cache Accelerator Core for DeepSeek Data Center

**Design Goal:** A high‑throughput, energy‑efficient RISC‑V core (or tightly coupled accelerator) dedicated to managing the Key‑Value (KV) cache during transformer inference. It offloads attention KV storage, retrieval, and compression from the main AI compute cores (GPUs or NPUs), reducing memory bandwidth bottlenecks and improving latency.

---

### 1. System Context

In a typical transformer decoding step, each attention layer reads the entire KV cache for the previous tokens. The cache size grows with sequence length (e.g., 32K tokens × layers × heads × dimension). This dominates memory traffic and often becomes the inference bottleneck.

**Proposed Solution:** A specialized RISC‑V core, called **KV‑Core**, attached to a fast, low‑latency SRAM scratchpad dedicated to the KV cache. The KV‑Core executes lightweight micro‑kernels for:
- Writing new token KV pairs
- Reading and broadcasting KV vectors to attention cores
- Applying sliding window evictions
- Compressing/decompressing KV blocks
- Managing paged attention indices

The main AI compute cores (e.g., GPUs) only issue high‑level commands (e.g., “append token”, “query attention”) via a memory‑mapped command queue.

---

### 2. Core Microarchitecture

The KV‑Core is a 64‑bit RISC‑V core with a simplified, in‑order pipeline, heavily optimized for **vector memory operations** and **bit‑manipulation**. It does **not** need FPUs or heavy integer ALUs; instead it has:

- **RISC‑V base**: RV64IM (Integer + Multiply/Divide)
- **B extension** (Bit‑Manipulation) for efficient compression (e.g., bit‑packing, sliding window)
- **V extension** (Vector) with specialized configuration for 128‑bit vector registers (to match typical KV head dimensions)
- **Custom CSRs** for cache control, compression modes, and address generation

**Pipeline:** 3‑stage (fetch, decode/execute, memory/writeback). Clock speed: 1.5 GHz (power‑efficient). Area: ≈0.5 mm² at 5 nm.

---

### 3. Memory Hierarchy

| Level | Size | Technology | Latency | Purpose |
|-------|------|------------|---------|---------|
| **Scratchpad (Shared L1)** | 64 MB | SRAM (on‑chip or 3D‑stacked) | 5 ns | Stores the KV cache as contiguous blocks per layer/head. |
| **Command Buffer** | 128 entries | Single‑port SRAM | 1 cycle | Holds commands from host (e.g., write, query, evict). |
| **Host‑side MMIO** | – | PCIe/CXL | 100 ns | Communication with GPU/NPU. |

The scratchpad is **banked** (e.g., 64 banks of 1 MB) to support parallel reads from multiple heads. The KV‑Core manages address mapping: logical token index → physical bank + offset.

---

### 4. Custom Instruction Set Extensions

We propose a set of **custom RISC‑V instructions** to accelerate KV operations. All are implemented as lightweight microcoded routines or dedicated hardware state machines.

#### 4.1 KV Cache Management

| Instruction | Syntax | Operation |
|-------------|--------|-----------|
| `kv.write` | `kv.write rd, rs1, rs2` | Write KV pair from register pair (rs1: key vector base, rs2: value vector base) to current token position. Increment token counter. |
| `kv.read` | `kv.read rd, rs1, rs2` | Read KV pair for token index rs1, store to memory at addresses rs2. |
| `kv.append` | `kv.append rd, rs1` | Append a new token (rs1: pointer to token data) and return new token ID. |
| `kv.evict` | `kv.evict rs1` | Evict token(s) according to policy (e.g., sliding window, LRU). rs1 encodes policy and count. |

#### 4.2 Attention Query Acceleration

| Instruction | Syntax | Operation |
|-------------|--------|-----------|
| `kv.query_heads` | `kv.query_heads rd, rs1, rs2` | For a given query vector at rs1, compute dot products with all keys of a specific layer/head batch (rs2: head mask), accumulate into result vector. This is a **reduction‑to‑scalar** but can also produce a vector of scores. |

#### 4.3 Compression / Decompression

| Instruction | Syntax | Operation |
|-------------|--------|-----------|
| `kv.compress` | `kv.compress rs1, rs2` | Compress the KV block starting at rs1 using on‑the‑fly algorithm (e.g., integer quantization, outlier‑only, or φ‑sparse encoding). Result metadata is appended. |
| `kv.decompress` | `kv.decompress rs1, rs2` | Decompress a block to scratchpad. |

#### 4.4 Paged Attention Support (like vLLM)

| Instruction | Syntax | Operation |
|-------------|--------|-----------|
| `kv.paged_write` | `kv.paged_write rs1, rs2` | Write KV to logical token, automatically handling page/cross‑block mapping. |
| `kv.paged_read` | `kv.paged_read rd, rs1, rs2` | Read concatenated KV for a logical token that may span multiple physical pages. |

---

### 5. Example KV‑Query Micro‑kernel in RISC‑V Assembly

Assume we have a sequence of tokens (T = 2048), 32 attention heads, each KV dimension = 128. The KV‑Core processes a query from a GPU:

```
# command from GPU: query attention for head 5, query vector at address Q_ptr
# KV‑Core loads state, loops over all tokens

# Setup: token count in CSR (hardware‑incremented by kv.write)
li t0, 0            # token index
li t1, head5_base   # base address for head 5 KV in scratchpad
li t2, Q_ptr        # query vector address (host memory)
vsetvli v0, 128, e32  # vector length 128

kv.query_heads v0, t2, 0x20  # compute dot products for head 5 (mask 0x20)
# result stored in vector v0 (scores per token)
# ... subsequent softmax reduction is done by GPU or another unit
```

---

### 6. Performance Estimates

| Operation | Traditional GPU (H100) | KV‑Core (estimated) | Gain |
|-----------|----------------------|----------------------|------|
| Append token (write KV) | ~3 µs (via host‑side memory copy) | 50 ns (direct scratchpad write) | 60× |
| Query attention (read all tokens, dot product) | ~12 µs per head (seq len 2048) | 2 µs per head (parallel banked reads) | 6× |
| Eviction (sliding window) | software overhead | 10 ns per evicted token | huge |
| Compression (INT4 block) | ~1 µs per 256 elements | 0.2 µs (dedicated engine) | 5× |

**Overall system benefit:** For a 70B parameter model serving long contexts (32K tokens), KV‑Core can reduce total inference latency by 30‑50% and memory bandwidth consumption by 60%.

---

### 7. Implementation Notes

- **Integration:** KV‑Core is connected to the host via CXL.mem (coherent memory). It appears as a special memory device with command queue.
- **Software model:** A lightweight driver (e.g., Linux kernel module) exposes `ioctl` for KV operations. DeepSeek’s inference engine uses this instead of manual CPU‑side KV management.
- **Scalability:** Multiple KV‑Cores can be chained (e.g., one per GPU or per NUMA node). The scratchpad can be partitioned.

---

### 8. Conclusion

The **KV‑Core RISC‑V accelerator** provides a low‑latency, high‑bandwidth, power‑efficient solution for KV cache management. By offloading these operations from the main AI compute die, it enables longer context windows, lower TCO, and faster inference for DeepSeek models. The design is modular and can be implemented as a hardened IP block or as a dedicated RISC‑V core with custom extensions.
