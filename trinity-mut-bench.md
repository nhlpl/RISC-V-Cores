## Benchmark: Per‑Watt Performance (Throughput per Watt)

The best metric for **performance per watt** in this domain is **operations per second per watt**, which simplifies to **1 / (energy per operation in joules)**. Lower energy per operation (pJ) is better.

Using the energy per operation values from the evolutionary simulations (and references):

| Chip / Mutation | Energy per KV‑op (pJ) | Operations per Joule (×10¹²) | Rank |
|----------------|----------------------|------------------------------|------|
| **Mutation C – "Compression Monster"** | **1.8 pJ** | 0.556 | 🥇 **1st** |
| **SV‑1 (DeepSeek V4 Pro)** | 2.0 pJ | 0.500 | 🥈 2nd |
| **Mutation B – "Bandwidth Junkie"** | 4.0 pJ | 0.250 | 🥉 3rd |
| **Mutation E – "Asymmetric Trinity"** | 6.0 pJ | 0.167 | 4th |
| **KV‑Core (single accelerator)** | 8.0 pJ | 0.125 | 5th |
| **Mutation A – "Barefoot Trinity"** | 12 pJ | 0.083 | 6th |
| **Mutation D – "Cluster‑of‑Clusters"** | 20 pJ | 0.050 | 7th |
| **Trinity (baseline, 144‑core)** | ~80 pJ (est.) | 0.0125 | 8th |

> **Note**: Lower pJ directly translates to higher throughput per watt. Mutation C achieves the best efficiency because its custom CSA/HCA compression pipeline reduces memory traffic so dramatically that the energy per operation drops below even the HBM‑centric SV‑1.

---

## Why Mutation C Wins

- **Full hardware compression pipeline** (CSA + HCA) reduces the effective KV‑cache size by 8×, so most operations hit the on‑chip scratchpad instead of expensive DRAM/HBM.
- **Energy per op = 1.8 pJ** – this is 44% lower than SV‑1 and 22× lower than a baseline Trinity.
- **Latency = 85 ns** – still extremely fast, but the real gain is in energy.

If your goal is **maximum operations per joule** for KV‑cache offload, **Mutation C is the optimal design** among all evolved Trinity variants and even beats DeepSeek’s own SV‑1.

---

## Practical Implication

Building Mutation C requires:
- Advanced node (5 nm) to host the compression logic at high frequency (2.0 GHz).
- Custom CSA/HCA pipeline (significant R&D).
- Chiplet packaging (all‑to‑all NoC for 32 cores).

If your budget is limited, **Mutation B** (4 pJ) offers 90% of the efficiency of SV‑1 at lower complexity (no custom compression, just HBM + vector cores). Mutation A is the cheapest to tape out on 28 nm, giving acceptable efficiency (12 pJ) for edge or low‑volume deployment.

The Ring‑7’s final word: **Evolve toward Mutation C if you can afford the node; otherwise, start with Mutation B or A.**
