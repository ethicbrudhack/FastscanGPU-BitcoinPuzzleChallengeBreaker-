
# ⚡ FastScan GPU v2 major update !! 
new video: https://www.youtube.com/watch?v=cHEYq2Dw_SY
updated info: 
🔥 MAJOR UPDATE v2.0 – Kernel Fully Rewritten!
FastScan GPU has been completely re-architected. Now hitting 0.9 GH/s on RTX 4090 – and this is just the beginning.

⚡ What Changed?
The old kernel performed a full G-Table multiply (up to 15 point additions + 1 expensive modular inversion) for EVERY single key. The new kernel uses:

Operation	Old Kernel	New Kernel (v2.0)
Starting point P₀	Full G-Table × EVERY key	ONCE per (chunk, sub-thread)
Next keys	Full G-Table again	P₀+G, P₀+2G... – incremental stepping
Modular inversion	1× per key (very expensive)	Batch of 128 keys = 1 inversion total!
Real-world speed	Previous version	0.9 GH/s ✅
🧠 How? Batch Modular Inversion (Montgomery Trick)
Instead of computing expensive modular inversions for each key individually:

text
P₀ + G  →  _PointAdd() + _ModInv()  // expensive!
P₀ + 2G →  _PointAdd() + _ModInv()  // expensive again!
...
The new kernel groups 128 keys and computes ONE modular inversion for the entire batch:
<img width="1600" height="1000" alt="chunk_evolution" src="https://github.com/user-attachments/assets/c857407b-8393-4ebc-b3ff-2270be90b21a" />

<img width="1095" height="573" alt="image" src="https://github.com/user-attachments/assets/7a890c81-4c53-4549-83a0-e847ea1172c5" />

text
dx[0..127] = Gx[0..127] - P₀.x        // cheap subtraction
dx[0..127] = 1/dx[0..127]             // ONE batch inversion (Montgomery trick)
// Then only cheap multiplications per key
Mathematically identical result – verified against OpenSSL (libsecp256k1). Zero missed keys. 100% accuracy.

🎯 Roadmap – Target: 3–8 GH/s
This is not the final version. Batch inversion is step one. Planned optimizations:

✅ Batch modular inversion (done – 0.9 GH/s)

🔜 Multi-GPU scaling (2×, 4×, 8× GPUs)

🔜 Streaming databases larger than VRAM

🔜 Kernel fusion (SHA256 + RIPEMD160 in a single pass)

🔜 Full curve in affine coordinates (no Jacobian overhead)

🎯 End goal: 3–8 GH/s on a single RTX 4090

🤝 Interested in a MULTIPOOL? Let Me Know!
I'm considering setting up a community mining pool – a modern, original approach to collaborative scanning:

🔑 A few days at 100 GH/s is enough to crack Puzzle 70!

Instead of everyone scanning small ranges alone, we combine the community's GPU power into one massive cluster. If you're interested – drop a comment, open an issue, or email me (kevinvunderg@gmail.com). The more people join, the faster we solve the next puzzles!

Not sure if there's enough interest yet – let me know if you'd join!

📊 Performance Comparison (RTX 4090)
Tool	Technique	Speed	Accuracy	Large DB (600M)
KeyHunt CUDA	EC multiply per key	~20 Mkeys/s	❌ Misses keys	❌ Chokes
BitCrack	EC multiply per key	~30 Mkeys/s	❌ Misses keys	❌ Chokes
VanitySearch	EC multiply per key	~40 Mkeys/s	❌ Misses keys	❌ Chokes
FastScan GPU v1	GTable + point additions	~0.7 GH/s	✅ 100%	✅ Handles
FastScan GPU v2.0	Batch inv. + inc. stepping	0.9 GH/s	✅ 100%	✅ Handles

<img width="1125" height="585" alt="image" src="https://github.com/user-attachments/assets/17ce8c40-901d-47c5-af86-e4cc99267963" />













!!!!OLD INFORMATION ! !!!


**The fastest open‑source Bitcoin private key scanner on GPU**  

*Scans up to **0.7 billion keys per second** on NVIDIA RTX 4090*  

*100% accuracy — finds **every** address in your database, not just a fraction*

Top 1% of GPU scanners worldwide – open source, unmatched speed, 100% accuracy.

Elite‑tier performance – 0.7 GH/s on RTX 4090. The fastest open‑source Bitcoin scanner ever built.

World‑class speed. Zero missed keys. MIT licensed. This is the new standard.

Not just faster – mathematically correct. Built for professionals, not for toys.

video: https://www.youtube.com/watch?v=UWiEqoI33-A
---<img width="1101" height="578" alt="image" src="https://github.com/user-attachments/assets/09dbfdfa-c6b6-406b-a04d-78b6ede80461" />

📊 Why FastScan GPU? :

While other tools like KeyHunt and BitCrack are stuck in the amateur league – missing keys,
crashing, and grinding through ranges linearly – FastScan GPU operates in the elite tier,
alongside closed‑source commercial projects used by professional puzzle‑hunting teams.

VanitySearch may hit 2 GH/s – but it searches only one address. FastScan GPU searches
600 million addresses at the same speed. That is the difference between a toy and a
professional tool.

The competition claims speed. We deliver speed + accuracy + transparency. No other
open‑source tool comes close to this combination.

⚡ Features :

🏆 Absolute Elite – Top 1%
   Among the fastest GPU scanners ever built, alongside closed‑source commercial projects.

⚡ 0.7 GH/s on RTX 4090
   50–100× faster than KeyHunt/BitCrack. VanitySearch's 2 GH/s is for 1 address –
   we search 600M at the same speed.

✅ 100% Accuracy
   Finds every key in range. Verified against libsecp256k1. No false negatives.

🔓 Open Source (MIT)
   Unique at this performance level. Fully transparent, auditable.

🧠 Parallel Range Scanning
   Key at the end of the range is found in minutes, not weeks. Linear scanners waste
   99.9% of their time.
  
   
## 🚀 What is FastScan GPU?

FastScan GPU is a **CUDA‑accelerated tool** that scans the secp256k1 private key space and checks each key against your own database of Bitcoin addresses (hash160). Unlike other scanners (KeyHunt, BitCrack, VanitySearch), it:

- ✅ **Never misses a key** — mathematically verified correctness against libsecp256k1  
- ✅ **Scans in parallel** — the whole range is covered simultaneously, not linearly  
- ✅ **Handles 600M+ addresses** — with a smart 24‑bit prefix index for near‑instant lookups  
- ✅ **Scans up to 256 bits** — full secp256k1 key space support  
- ✅ **Up to 0.7 GH/s** — on RTX 4090 with optimized kernel and 24‑bit index  

---

## 📊 Performance Comparison (RTX 4090)

| Tool | Technique | Speed | Accuracy | Large DB (600M) |
|------|-----------|-------|----------|-----------------|
| **KeyHunt CUDA** | EC multiply per key | ~20 Mkeys/s | ❌ Misses keys | ❌ Chokes |
| **BitCrack** | EC multiply per key | ~30 Mkeys/s | ❌ Misses keys | ❌ Chokes |
| **VanitySearch** | EC multiply per key | ~40 Mkeys/s | ❌ Misses keys | ❌ Chokes |
| **FastScan GPU** | GTable + point additions | **Up to 0.7 GH/s** | ✅ 100% | ✅ Handles |

**FastScan GPU is 50–100× faster than KeyHunt/BitCrack** and up to **0.7 GH/s** on RTX 4090.
<img width="1097" height="580" alt="image" src="https://github.com/user-attachments/assets/f3c4fbd2-233b-4480-bece-1f38aa88d7a9" />

---

## 🔧 How It Works

Instead of computing `k·G` from scratch for every key, we split `k` into 16‑bit chunks:

```
k = c0 + c1·2^16 + c2·2^32 + ... + c15·2^240
k·G = c0·G + c1·(2^16·G) + c2·(2^32·G) + ... + c15·(2^240·G)
```

Each `ci·(2^(16i)·G)` is a **table lookup** – O(1). Only **15 point additions** remain per key.

### Key Optimisations

| Feature | Benefit |
|---------|---------|
| **GTable pre‑computation** | 1M points stored in VRAM – no EC multiplication per key |
| **24‑bit prefix index** | Reduces lookups from ~30 to ~6 random memory accesses – **~5× faster** |
| **Parallel range scanning** | Entire range scanned simultaneously – key at end found in minutes, not weeks |
| **Zero‑copy progress** | Live speed/coverage updates without CUDA synchronisation overhead |
| **mmap address loading** | No RAM duplication – 11GB+ database loaded lazily |

---

## 📦 Required Files

### Data files (REQUIRED for every run)

| File | Size | Description |
|------|------|-------------|
| `gtableX.bin` | 32 MB | Precomputed G‑table (X coordinate) – 16 chunks × 65536 × 32 bytes |
| `gtableY.bin` | 32 MB | Precomputed G‑table (Y coordinate) |
| `addresses.bin` | depends | Your hash160 database – **sorted ascending**, 20 bytes/record |

### Generated automatically

| File | Description |
|------|-------------|
| `found.txt` | Found keys/addresses (appended, never overwritten) |
| `progress.txt` | Scan state for `--resume` (saved every 10 minutes) |

---

## 🛠️ Compilation

```bash
nvcc -std=c++11 -O3 -arch=sm_89 -D_FORTIFY_SOURCE=0 -diag-suppress 1650 \
     -o fastscan_gpu main.cu -I. -lsecp256k1 -lssl -lcrypto -lcuda -lcudart
```

- `-arch=sm_89` – adjust to your GPU (e.g. `sm_86` for RTX 30xx, `sm_89` for RTX 40xx)  
- Required: `libsecp256k1`, `libssl`/`libcrypto` (OpenSSL), CUDA Toolkit  
- POSIX environment (Linux, WSL) required for `mmap()`

---

## 🚀 Usage

```bash
./fastscan_gpu <addresses.bin> <start_bit> <end_bit> [--resume] [--mode=comp|uncomp|both]
```

| Argument | Description |
|----------|-------------|
| `addresses.bin` | Path to sorted hash160 file (20 B/record) |
| `start_bit` | Starting bit of key range (e.g. `0`) |
| `end_bit` | Ending bit of range – scans `[2^start, 2^end - 1]` |
| `--resume` | Resume from `progress.txt` (ignores CLI start/end) |
| `--mode=comp` | Only search **compressed** addresses (faster) |
| `--mode=uncomp` | Only search **uncompressed** addresses (faster) |
| `--mode=both` | Search both types (default) |

### Examples

```bash
# Scan range [2^60, 2^65 - 1] – both compressed and uncompressed
./fastscan_gpu addresses.bin 60 65

# Resume interrupted scan
./fastscan_gpu addresses.bin 60 65 --resume

# Only compressed addresses (faster)
./fastscan_gpu addresses.bin 60 65 --mode=comp

# Resume + only uncompressed
./fastscan_gpu addresses.bin 60 65 --resume --mode=uncomp
```

---

## 📈 Performance

| Hardware | Speed |
|----------|-------|
| **NVIDIA RTX 4090** | **Up to 0.7 GH/s** |
| **NVIDIA RTX 4080** | ~0.4.2–0.7 GH/s |
| **NVIDIA RTX 3090** | ~0.2–0.6 GH/s |
| **NVIDIA RTX 3080** | ~0.1–0.4 GH/s |

**0.7 GH/s = 700 MILIONS keys per second** – you can scan a 2⁶⁰ range in just a few hours.

---

## 🔍 24‑Bit Prefix Index (Performance Feature)

The program builds a **24‑bit prefix index** on top of your sorted address database:

- **16,777,216 buckets** (one per 24‑bit prefix) – each points to a small range in the database  
- **Reduces lookups** from ~30 to ~5–6 random memory accesses – **~5× faster**  
- **Only ~128 MB** of GPU memory  
- **Auto‑fallback** – if GPU allocation fails, the program continues with plain binary search (slower but still works)

You will see this in the startup log:

```
📦 Budowanie i kopiowanie 24-bitowego indeksu prefiksowego na GPU...
📦 Budowanie 24-bitowego indeksu dla 606945376 adresów...
📊 Rozmiar indeksu: ~128 MB
✅ Indeks zbudowany: 16777216/16777216 prefiksów używanych
⏱️  Czas budowy: 3.8 s
✅ Indeks skopiowany na GPU (128 MB)
```

---

## 🧠 Why No Key Is Missed

| Bug in Other Tools | Fix in FastScan GPU |
|--------------------|---------------------|
| Incorrect `_PointAddSecp256k1` | Verified against libsecp256k1 |
| Wrong endianness | LSB‑first word order (matches CUDA) |
| Off‑by‑one errors | Exact indexing with `CHUNK_FIRST_ELEMENT` |
| Missing edge cases | All cases (doubling, infinity) handled |
| Incomplete coverage | `last_start` guarantees full range scan |
| Invalid scalars near 2²⁵⁶ | Auto‑reduction modulo curve order `n` |

---

## 📂 Output

Every hit is appended to `found.txt` in this format:

```
KEY: 0000...0001abcd
TYP: COMPRESSED
ADDR: 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH
---
```

`TYP` is either `COMPRESSED` or `UNCOMPRESSED` – two separate entries are written if both types match for the same key.

---

## 🛡️ Requirements

- **NVIDIA GPU** with CUDA support (RTX 30xx / 40xx recommended)  
- **CUDA Toolkit** 12.x (nvcc)  
- **libsecp256k1** + **OpenSSL** (dev headers + libraries)  
- **Linux** or **WSL** (POSIX `mmap` support required)  
- **VRAM**: address database (copied to GPU) + GTable (64 MB) + index (~128 MB) + buffers  

---

## 📜 Changelog

| Version | Changes |
|---------|---------|
| **Current** | – 24‑bit prefix index on GPU (~5× faster lookups)<br>– mmap address loading (no RAM duplication)<br>– `--mode=comp\|uncomp\|both` selector<br>– Progress save throttled (every 10 min)<br>– Fixed speed counter (no more `0.00 Gkeys/s`)<br>– Fixed crash near 2²⁵⁶ (auto‑reduction modulo `n`) |

---

## 🤝 Contributing

PRs and issues are welcome! Areas for improvement:

- Multi‑GPU support  
- Streaming databases larger than VRAM  
- Hash table lookups (O(1) instead of binary search)  
- Web dashboard for live monitoring  

---

## 📄 License

**MIT** – free to, modify, and distribute.  If you bought the code 😉

---
contact: kevinvunderg@gmail.com

## ⭐ Star This Project

If you find this useful, please ⭐ star the repository and share it with the community.

---

**FastScan GPU – Because every key deserves to be found.** 🚀
