# FastScan 253-256 — Standalone Edition

**The fastest public Bitcoin private key scanner in existence.**  
Achieves **~49 Gkeys/s** on RTX 4090 (raw pubkey memcmp, zero hashing).

This is the **standalone version** of the same GPU engine used in the [satoshipool.org](https://satoshipool.org) 253-256 pool.  
It scans uncompressed public keys directly from a `.bin` database (or a single pubkey) using pure `memcmp` comparison — **no SHA256, no RIPEMD160** in the hot path.

<img width="1090" height="553" alt="image" src="https://github.com/user-attachments/assets/b8ebe765-dc3e-43ae-91cc-c84531925797" />

<img width="1087" height="513" alt="image" src="https://github.com/user-attachments/assets/0137d38e-a790-43b4-8b9f-7584bc0617c0" />
<img width="1587" height="814" alt="image" src="https://github.com/user-attachments/assets/91391664-6cd3-4d79-9a4e-aaf4b7b46f6c" />


---
===================================
REQUIREMENTS - UBUNTU / LINUX
===================================

Required:
- Ubuntu 20.04 / 22.04 / 24.04 (64-bit recommended)
- NVIDIA GPU with CUDA support
- Latest NVIDIA proprietary driver
- CUDA Toolkit (matching the GPU and driver version)
- GCC / G++ compiler
- Make or CMake (depending on build setup)
- OpenSSL development libraries
- libsecp256k1 development libraries
- Required memory mapping libraries (mman or equivalent)

Recommended packages:

sudo apt update

sudo apt install build-essential gcc g++ make cmake git \
libssl-dev libsecp256k1-dev

Notes:
- CUDA Toolkit must be installed separately from NVIDIA's official repository.
- The CUDA path may need to be adjusted depending on the installation.
- Users must modify include/library paths in the compile command to match their own system.
- CUDA architecture flags (-gencode) should match the user's GPU.
- Compilation depends on the user's system configuration.

- For older NVIDIA GPUs:
- Older CUDA versions may be required.
- Some legacy architectures may need additional compiler flags.

For newer NVIDIA GPUs:
- Use a CUDA version compatible with the GPU generation.
- Enable the correct compute capability (sm_xx) during compilation.

 ================================================================
REQUIREMENTS - WINDOWS
================================================================

Required:
- Windows 10 / Windows 11 (64-bit)
- NVIDIA GPU with CUDA support
- Latest NVIDIA GPU driver
- CUDA Toolkit (compatible with the GPU architecture)
- Visual Studio 2022
- MSVC C++ compiler toolchain
- "Desktop development with C++" workload installed in Visual Studio
- Windows SDK
- vcpkg package manager
- OpenSSL libraries
- libsecp256k1 library
- mman library

Recommended:
- Git (for downloading dependencies)
- CMake (if building dependencies manually)

Notes:
- Run compilation commands from cmd.exe or Developer Command Prompt.
- Users must change all paths in the compile command to match their own installation directories.
- CUDA architecture flags (-gencode) must match the user's GPU model.
- Different GPU generations may require different CUDA Toolkit versions.
- Compilation depends on the user's system configuration.

 ================================================================
IMPORTANT
================================================================

This project does not include preconfigured build paths.
Users must adjust all CUDA, compiler, include and library paths
according to their own system installation.

The provided commands are examples only.
## 🔥 Why is it 10× faster than typical GPU scanners?

| Feature | Traditional scanners | This scanner |
|---------|---------------------|--------------|
| Hashing | SHA256 + RIPEMD160 per key | **None** (raw pubkey memcmp) |
| EC operations | Per-key modular inverse | **Batch Montgomery inversion** (x40 keys per inversion) |
| Memory access | Random lookups | **24-bit prefix index** + L1/L2 bitmaps |
| Endomorphism | Usually unused | **GLV ×3** + negated Y ×2 = **6 keys per point addition** |
| Multi-GPU | Manual setup | **Auto-detect all GPUs** with `--gpu=all` |

**Result:** ~8.3 Gadd/s → ~49 Gkeys/s effective on RTX 4090.

---

## 📁 Required Files

All files must be in the same directory.

### Source Files (to compile)

| File | Description |
|------|-------------|
| `main_253_256_standalone.cu` | Main CUDA program (kernel + CPU driver) |
| `GPUSecp.h` | EC configuration constants |
| `GPUMath.h` | 256-bit modular arithmetic |
| `GPUHash.h` | SHA256/RIPEMD160 (only used for address conversion, not in hot path) |
| `GPUGroup.h` | Precomputed G-point tables (Gx[], Gy[]) |

### Data Files (REQUIRED)

| File | Size | Description |
|------|------|-------------|
| `gtableX.bin` | 32 MB | Precomputed G-point X coordinates (16 chunks × 65536 points × 32 bytes) |
| `gtableY.bin` | 32 MB | Precomputed G-point Y coordinates |
| `pubkeys.bin` (your DB) | variable | **65-byte uncompressed pubkeys** (04 \|\| X(32B) \|\| Y(32B)) — **must be sorted by X** |

> **💡 Pre-built files:**  
> You can download ready-to-use `gtableX.bin`, `gtableY.bin`, and `pubkeys.bin` from the repository folder **`253_256_files`**.  
> If you prefer to generate your own, use `generate_gtable.cpp` (see section below).

### Auto-Generated Files

| File | Description |
|------|-------------|
| `found.txt` | Found keys (appended, never overwritten) |
| `progress.txt` | Scan state for `--resume` (saved every 10 minutes). In multi‑GPU mode, each GPU saves its own file: `progress_gpu0.txt`, `progress_gpu1.txt`, etc. |

---

## 🔧 Compilation

Use this command **exactly** — adjust only the architecture flag and batch size if needed:

```bash
nvcc -O3 -arch=sm_86 -D_FORTIFY_SOURCE=0 -DGRP_SIZE=1024 -o fastscan_253_256standalone main_253_256_standalone.cu -lssl -lcrypto -lsecp256k1
```

### Compilation Flags

| Flag | Purpose | Tuning Advice |
|------|---------|---------------|
| `-arch=sm_XX` | GPU architecture | Find yours: `nvidia-smi` → Compute Capability. Common: `sm_86` (RTX 30xx), `sm_89` (RTX 40xx), `sm_90` (RTX 50xx), `sm_75` (RTX 20xx), `sm_61` (GTX 10xx). |
| `-D_FORTIFY_SOURCE=0` | Disable fortification (required) | Always keep this. |
| `-DGRP_SIZE=1024` | G‑table size (fixed) | Always 1024. |
| `-DGROUP_BATCH=N` | Batch size for Montgomery inversion | **Default is 40** (set in code). Override with `-DGROUP_BATCH=16` for older GPUs or `-DGROUP_BATCH=64` for newer ones. Experiment for best performance. |

### Example Compilation Commands

**RTX 4090 (best speed):**
```bash
nvcc -O3 -arch=sm_89 -D_FORTIFY_SOURCE=0 -DGRP_SIZE=1024 -DGROUP_BATCH=40 -o fastscan_253_256standalone main_253_256_standalone.cu -lssl -lcrypto -lsecp256k1
```

**GTX 1080 (older card):**
```bash
nvcc -O3 -arch=sm_61 -D_FORTIFY_SOURCE=0 -DGRP_SIZE=1024 -DGROUP_BATCH=16 -o fastscan_253_256standalone main_253_256_standalone.cu -lssl -lcrypto -lsecp256k1
```

---

## 🚀 Running the Program

```bash
./fastscan_253_256standalone <pubkeys.bin | PUBKEY_HEX> <start_bit> <end_bit> [--gpu=N|all] [--resume] [--split-gpu]
```

| Argument | Description |
|----------|-------------|
| `pubkeys.bin` | Path to your 65-byte pubkey database (sorted by X) |
| `PUBKEY_HEX` | Single uncompressed pubkey (130 hex chars, starts with `04`) |
| `start_bit` | Starting bit (e.g., `253`) |
| `end_bit` | Ending bit (e.g., `256`) — range = `[2^start, 2^end - 1]` |
| `--gpu=N` | Use specific GPU (e.g., `--gpu=0`). |
| `--gpu=all` | **Use ALL available GPUs.** |
| `--resume` | Resume from `progress.txt` (or `progress_gpuN.txt` in multi‑GPU mode) |
| `--split-gpu` | When used together with --gpu=all, divides the search range equally across all GPUs.|

> **⚠️ IMPORTANT:** By default, the program uses **only GPU 0**. To use all GPUs, you **must** pass `--gpu=all`.

---

### Examples

```bash
# Scan database with ALL GPUs (each GPU scans the full range)
./fastscan_253_256standalone pubkeys.bin 253 256 --gpu=all

# Scan database with ALL GPUs and split the range equally
./fastscan_253_256standalone pubkeys.bin 253 256 --gpu=all --split-gpu

# Scan with a single specific GPU
./fastscan_253_256standalone pubkeys.bin 253 256 --gpu=0

# Test with a single known pubkey (44-45 bits) — uses ALL GPUs
./fastscan_253_256standalone 046ecabd2d22... 44 45 --gpu=all

# Resume interrupted scan with ALL GPUs
./fastscan_253_256standalone pubkeys.bin 253 256 --resume --gpu=all

# Resume interrupted split scan
./fastscan_253_256standalone pubkeys.bin 253 256 --resume --gpu=all --split-gpu
```

---

## 🖥️ Multi-GPU Usage

### Use all GPUs (default behavior)

```bash
./fastscan_253_256standalone pubkeys.bin 253 256 --gpu=all
```

By default, every GPU scans the **full key range independently**.

This mode is useful for:

- benchmarking
- testing
- verifying reproducibility

### Split the range across all GPUs

```bash
./fastscan_253_256standalone pubkeys.bin 253 256 --gpu=all --split-gpu
```

When `--split-gpu` is enabled, the standalone version automatically divides the key range equally across all detected GPUs.

Example (4 GPUs):

```
GPU 0 → first 25% of the range
GPU 1 → second 25%
GPU 2 → third 25%
GPU 3 → fourth 25%
```

Benefits:

- no duplicated work
- nearly linear scaling
- no manual range calculation

### Use a specific GPU

```bash
./fastscan_253_256standalone pubkeys.bin 253 256 --gpu=2
```

### Resume

Each GPU stores its own progress file.

- GPU 0 → `progress.txt`
- GPU 1 → `progress_gpu1.txt`
- GPU 2 → `progress_gpu2.txt`
- ...

This allows split scans to resume correctly without conflicts.

---

## 📦 Building Your Own Pubkey Database

Use the provided **`build_pubkey_db.py`** script to create your own `.bin` file from text files containing hex uncompressed pubkeys.

### Input format

- One pubkey per line
- Each line must be **130 hex characters** (65 bytes)
- Must start with `04` (uncompressed format)

### Usage

```bash
# Single file
python3 build_pubkey_db.py pubkeys.txt -o mydb.bin

# Multiple files (merges, deduplicates, sorts by X)
python3 build_pubkey_db.py part1.txt part2.txt part3.txt -o pubkeys.bin

# Default output is pubkeys.bin
python3 build_pubkey_db.py my_pubkeys.txt
```

The script will:

- Read all lines from all input files
- Remove duplicates (using a `set()`)
- **Sort by X coordinate** (bytes 1–33) — **REQUIRED** for the GPU binary search
- Write 65-byte binary records to the output file

### Example output

```
[PL] part1.txt: loaded 1284 pubkeys.
[PL] part2.txt: loaded 35621 pubkeys.
[PL] Removed 12 duplicates (36905 -> 36893).
============================================================
[PL] Written: pubkeys.bin
[PL] Records: 36893 pubkeys (2.29 MB)
============================================================
Use with fastscan_253_256:
   ./fastscan_253_256 pubkeys.bin 253 256
```

> **💡 You can download a pre-built `pubkeys.bin` with 357k+ records from the `253_256_files` folder in this repository.**

---

## 🔧 Generating G‑Tables Yourself

If you don't want to download pre‑built tables from the `253_256_files` folder, you can generate them using the included **`generate_gtable.cpp`**:

### Linux (Ubuntu/Debian)

```bash
sudo apt install -y g++ libssl-dev
g++ -O3 -o generate_gtable generate_gtable.cpp -lcrypto
./generate_gtable
```

### Windows (MSYS2)

```bash
pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-openssl
g++ -O3 -o generate_gtable.exe generate_gtable.cpp -lcrypto
./generate_gtable.exe
```

### Output (4 files, 32 MB each in current directory)

- `gtableX.bin` — uncompressed X coordinates
- `gtableY.bin` — uncompressed Y coordinates
- `gtable_compX.bin` — compressed X (for other tools, not used here)
- `gtable_compY.bin` — compressed parity (not used here)

---

## 🧠 How Scanning Works (Multi-Round with DEDUP)

The program divides the key range into chunks and processes them in **rounds**:

1. **Round 1:** Divides the range into `3563` chunks and scans all of them.
2. **Round 2:** Doubles the number of chunks (→ `7126`) and scans only **odd-indexed** chunks (1, 3, 5…).
3. **Round N:** Continues doubling chunks, scanning only odd indices each time.

**Why?** This guarantees:

- **100% coverage** (Round 1 covers everything)
- **Zero overlap** between rounds (DEDUP via `grid_mult=2, grid_off=1`)
- **No wasted work** — each key is checked at most once across all rounds

### Mathematical Guarantee

Because the stride is always a power of two (enforced by the code), and the number of chunks is even, the odd-indexed chunks in round `r+1` exactly fill the gaps between chunks in round `r` that were "left behind" by the doubling.

**Result:** The scan becomes progressively denser over time, approaching 100% of the range without ever duplicating work.

---

## 🔬 Performance Features

### 1. Batch Montgomery Inversion (`GROUP_BATCH=40`)

Instead of computing a modular inverse per key (expensive), we invert **40 keys at once** using the Montgomery trick:

```
One _ModInv → 1 / (dx[0] * dx[1] * ... * dx[n-1])
Backward pass → 1/dx[i] for all i
```

**Result:** ~40× fewer expensive inversions → massive speedup.

### 2. 24‑Bit Prefix Index

Built from the first 3 bytes of X coordinates:

- Index size: **128 MB** (`16,777,217 × 8 bytes`)
- Reduces binary search from `log2(N)` random accesses to a tiny bucket (typically <100 records)
- Built once at startup (~3–5 seconds for 357k records)

### 3. Endomorphism (GLV) + Negation (`USE_ENDO=1`)

From each computed point `(qx, qy)`, the kernel checks **6 variants**:

| Variant | Type |
|---------|------|
| `qx, qy` | Original key `k` |
| `qx, -qy` | Negated key `n-k` |
| `β·qx, qy` | Lambda key `λ·k` |
| `β·qx, -qy` | Negated lambda `n-λ·k` |
| `β²·qx, qy` | Lambda² key `λ²·k` |
| `β²·qx, -qy` | Negated lambda² `n-λ²·k` |

**Result:** 6 keys checked per point addition — free performance.

### 4. L1/L2 Bitmaps (optional)

32‑bit Bloom‑style filters:

- L1: **8 MB** (top 32 bits → first 21 bits)
- L2: **512 MB** (top 32 bits → full 27 bits)

These are loaded on GPU and used as a **pre‑filter** before touching the main database.

### 5. MMap (memory‑mapped file)

The database (`pubkeys.bin`) is **never fully loaded into RAM**:

- Mapped with `mmap(PROT_READ, MAP_SHARED)`
- OS handles paging — only needed data is loaded
- **Result:** Startup is instantaneous, RAM usage is minimal.

---

## 📊 Real‑World Benchmark (RTX 4090)

| Test | Speed |
|------|-------|
| Point additions (raw) | **8.3 Gadd/s** |
| Effective keys (×6 endo) | **~49 Gkeys/s** |
| 45‑bit key search | **8 rounds, ~3 minutes** |

### Example run (44‑45 bits, found in round 8)

```
Round 1 | 49.6 Gkeys/s | 0 hits
Round 2 | 48.5 Gkeys/s | 0 hits
Round 3 | 48.9 Gkeys/s | 0 hits
Round 4 | 49.2 Gkeys/s | 0 hits
Round 5 | 48.9 Gkeys/s | 0 hits
Round 6 | 48.6 Gkeys/s | 0 hits
Round 7 | 48.7 Gkeys/s | 0 hits
Round 8 | 49.0 Gkeys/s | 1 hit!

KEY: 0000000000000000000000000000000000000000000000000000122fca143c05
TYPE: UNCOMPRESSED (k)
ADDR: 1D5PzK3eHjj5YxRenRGL7vxu1osU8wLU9x
```

---

## 📄 Output Format (`found.txt`)

```
KEY: 0000000000000000000000000000000000000000000000000000122fca143c05
TYPE: UNCOMPRESSED
ADDR: 1D5PzK3eHjj5YxRenRGL7vxu1osU8wLU9x
---
```

- `KEY`: Full private key (32 bytes, hex)
- `TYPE`: `UNCOMPRESSED` (all keys from pubkey DB are uncompressed)
- `ADDR`: Corresponding Bitcoin address

**Note:** If the same key matches via endomorphism (`λ·k`, `λ²·k`, or their negations), the `KEY` is automatically reconstructed to the actual private key `k` before output.

---

## 🔄 Resume Support

The program writes `progress.txt` every 10 minutes and at the end of each round:

```
round_idx
start_bit
end_bit
launch
total_found
```

In multi‑GPU mode, each GPU writes its own file:
- GPU 0 → `progress.txt`
- GPU 1 → `progress_gpu1.txt`
- GPU 2 → `progress_gpu2.txt`
- etc.

**To resume:**

```bash
# Single GPU
./fastscan_253_256standalone pubkeys.bin 253 256 --resume


# All GPUs (full-range mode)
./fastscan_253_256standalone pubkeys.bin 253 256 --resume --gpu=all

# All GPUs (split mode)
./fastscan_253_256standalone pubkeys.bin 253 256 --resume --gpu=all --split-gpu
```

The `start_bit` and `end_bit` from the command line are **ignored** — the saved state takes priority.

---

## 🎯 Why Use the Standalone Version?

| Feature | Standalone | Pool Version |
|---------|------------|--------------|
| Auto‑multi‑GPU | ✅ Yes (with `--gpu=all`) | ✅ Yes |
| DEDUP / no overlap | ✅ Yes | ✅ Yes |
| Speed | **~49 Gkeys/s** | **~49 Gkeys/s** |
| Range | **Any** (e.g., 44‑45, 253‑256) | Fixed by operator |
| Runs forever | ✅ Yes (infinite rounds) | ✅ 24/7 with `--pool-persistent` |
| Work distribution | ✅ --split-gpu divides range locally
Default: full-range per GPU | ✅ Server splits work among all miners |
| Found keys | Local `found.txt` | Auto‑reported to server |
| Reward | Solo | **40% finder + 55% proportional + 5% operator** |

> *The standalone version runs **until it exhausts all rounds** (practically never for large ranges) or until you Ctrl+C. It does not automatically start over — it's designed for tests and single runs.
### GPUs are scanning the same keys

If all GPUs are processing the same range, start the program with:

```bash
./fastscan_253_256standalone pubkeys.bin 253 256 --gpu=all --split-gpu
```

Without `--split-gpu`, every GPU scans the entire range independently.
---

## ⚠️ Troubleshooting

### "GPU allocation failed"

- Your VRAM is insufficient to hold the database + G‑tables + index.
- Solution: Use a smaller database or add `--gpu=0` to limit VRAM usage.

### "Invalid bin file"

- Your `pubkeys.bin` is not a multiple of 65 bytes.
- Each record must be exactly: `0x04 || X(32B) || Y(32B)`.

### Program doesn't start on Windows

- Use **WSL2** or **MSYS2** — this code uses POSIX `mmap()` and `madvise()`.

---

## 🧪 Testing with a Known Key

To verify the program works:

```bash
# Use the public key from block 1 (private key = 1)
./fastscan_253_256standalone 0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8 0 1 --gpu=all

# Should find KEY: 0000...0001 at ADDR: 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH
```

---

## 🔗 Join the Pool!

This standalone version is **the exact same engine** used in the live pool at:

👉 **[https://wallet.satoshipool.org](https://wallet.satoshipool.org)**

**Why join?**

- **No range management** — the server handles it automatically.
- **Fair split** — 40% finder + 55% proportional + 5% operator.
- **24/7 mining** — the pool runs continuously, you just keep your worker online.
- **Automatic reporting** — found keys are sent to the server instantly.

**To join:**

```bash
python3 pool_worker_253_256.py \
  --server https://wallet.satoshipool.org \
  --worker YourNick \
  --password YourPassword \
  --binary ./fastscan_253_256 \
  --db ./pubkeys.bin
```

---

## 📄 License

This is an **educational / research** tool.

- Searching Bitcoin puzzle keys is **legal**.
- Searching for other people's in-use wallets is **not**.
- Use responsibly.

---

**Built with ❤️ for the crypto research community.**
