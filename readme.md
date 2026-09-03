# Bitcoin Puzzle / Wallet Pool (split-key) — GPU

<div style="display:flex; gap:4px; flex-wrap:wrap;">
  <img src="https://img.shields.io/github/stars/ethicbrudhack/FastscanGPU-BitcoinPuzzleChallengeBreaker-?style=social" alt="GitHub stars">
  <img src="https://img.shields.io/github/forks/ethicbrudhack/FastscanGPU-BitcoinPuzzleChallengeBreaker-?style=social" alt="GitHub forks">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <img src="https://img.shields.io/badge/python-3.8%2B-blue" alt="Python">
  <img src="https://img.shields.io/badge/CUDA-12.3%2B-green" alt="CUDA">
</div>

<table>
  <tr>
    <td align="center">
      <h3>🟠 Puzzle 71 (70–71 bits)</h3>
      <table>
        <tr><td><strong>Progress(per round)</strong></td><td><img src="https://img.shields.io/badge/dynamic/json?url=https://puzzle.satoshipool.org/stats&query=$.round_progress_pct&label=&color=orange&suffix=%25"></td></tr>
        <tr><td><strong>Keys Found</strong></td><td><img src="https://img.shields.io/badge/dynamic/json?url=https://puzzle.satoshipool.org/stats&query=$.hits&label=&color=success"></td></tr>
        <tr><td><strong>Pool Speed</strong></td><td><img src="https://img.shields.io/badge/dynamic/json?url=https://puzzle.satoshipool.org/stats&query=$.keys_per_sec&label=&color=blue"></td></tr>
      </table>
    </td>
    <td align="center">
      <h3>🔵 253-256 Old forgotten Mining Wallets</h3>
      <table>
        <tr><td><strong>Progress(per round)</strong></td><td><img src="https://img.shields.io/badge/dynamic/json?url=https://wallet.satoshipool.org/stats&query=$.round_progress_pct&label=&color=orange&suffix=%25"></td></tr>
        <tr><td><strong>Keys Found</strong></td><td><img src="https://img.shields.io/badge/dynamic/json?url=https://wallet.satoshipool.org/stats&query=$.hits&label=&color=success"></td></tr>
        <tr><td><strong>Pool Speed</strong></td><td><img src="https://img.shields.io/badge/dynamic/json?url=https://wallet.satoshipool.org/stats&query=$.keys_per_sec&label=&color=blue"></td></tr>
      </table>
    </td>
  </tr>
</table>

---

<img width="1002" height="504" alt="image" src="https://github.com/user-attachments/assets/9f27f08f-b3d4-485d-acfb-3f46c506060b" />

<img width="1093" height="559" alt="image" src="https://github.com/user-attachments/assets/aa0a00de-48ec-4db7-8564-96ea624ddff2" />

<img width="1097" height="564" alt="image" src="https://github.com/user-attachments/assets/df38e722-9bc4-4cc1-ba7f-3299363ebe5c" />

**⚠️ READ BEFORE RUNNING!!**  

**⚡ Performance:** New binaries (this repo) deliver **5.2 GH/s** / **46.5 GH/s** on RTX 4090. All tests under real pool workload.

• IMPORTANT: fastscan_71LEGACY.exe also works on RTX 4050 (and other new laptops) – use it if puzzle71.exe fails!

• ⚡ You can also use adresy_unique.bin with the independent/standalone code (Google Drive) for your own testing with any bit range.

• Puzzle 71 = ONE specific address. 

• 253-256 = 1.5M+ pubkeys from pubkeys.bin.

```bash
# Linux:
python3 pool_worker_253_256.py --server https://wallet.satoshipool.org --worker NICK --password PASS --binary ./fastscan_253_256 --db ./pubkeys.bin

# Windows RTX 20xx+ (sm_75-90):
python pool_worker_253_256.py --server https://wallet.satoshipool.org --worker NICK --password PASS --binary fastscan_253_256.exe --db pubkeys.bin

# Windows GTX 9xx/10xx LEGACY (sm_50-75):
python pool_worker_253_256.py --server https://wallet.satoshipool.org --worker NICK --password PASS --binary fastscan_253_256_LEGACY.exe --db pubkeys.bin
```

• Want to scan independently? Download the standalone code – works with your own .bin and any bit range.  
• The binaries are for pool mining ONLY. Use the commands above to connect.

🔹 Distributed GPU pool for Puzzle #71 + forgotten wallets. No overlap, fair reward split.

<img width="1600" height="1000" alt="chunk_evolution" src="https://github.com/user-attachments/assets/4f8b3985-1106-47b9-8339-2833d2dded62" />

---

## 📥 Download

📥 adresy_unique.bin: https://drive.google.com/file/d/1vTkDbWXIwtv2_V-_FnuW6QjonaCd_XSx/view?usp=drive_link  
— for independent standalone code !!!!

🌐 Website: https://satoshipool.org/

💬 Telegram: https://t.me/+39k4WcVDfYhiMWFk

---

## 🚀 Real‑World Performance on RTX 4090

> **⚠️ IMPORTANT: This speed is measured on a LIVE PRODUCTION POOL with SPLIT-KEY enabled.**
> 
> - Full SHA256/RIPEMD hashing + network communication (`/done`, `/work`) + split‑key overhead (`_PointAdd`).
> - **Not a lab trick**: Unlike CUDACyclone (raw point adds without network/pool logic), this is the **actual speed you get when mining** in our pool.
> - **Fair comparison**: Many benchmarks show 6–7 GH/s in isolated tests. This **5.2 GH/s** is the **real deployed speed** on `puzzle.satoshipool.org` – with all security layers active.

---

## 🚀 FastScan – Two Modes, Two Different Worlds

This repository contains **two independent GPU tools** – their performance numbers are **NOT** interchangeable. Please read carefully.

---

### 🔵 1. Puzzle #71 Pool (ALREADY LIVE)
- **Target:** Single Bitcoin address (`1PWo3JeB9jrGwfHDNpdGK54CRas7fsVzXU`)
- **Range:** 70–71 bits
- **Real Speed on RTX 4090:** **~5.2 GH/s**
  - *Why this speed?* Full SHA256/RIPEMD160 hashing + network communication (HTTPS) + split-key overhead + pool logic.
- **Status:** ✅ **Available now** – join the pool using the commands below.

---

### 🟢 2. 253-256 Wallet Scanner – LIVE (Pool + Standalone)
- **Target:** Any uncompressed public key database (raw memcmp comparison, zero hashing)
- **Range:** 253–256 bits (custom ranges supported)
- **Blazing Speed on RTX 4090:** **46.5 GH/s** (7.7 Gadd/s)
- **Why is it 10–40× faster than typical GPU scanners?**
  - ✅ No SHA256/RIPEMD160 – raw pubkey comparison (memcmp)
  - ✅ Batch modular inversion (x512) – drastically reduces EC operations
  - ✅ L1 cache optimizations (CUDACyclone-style)
  - ✅ Parallel chunk-based scanning – zero overlap
- **Status:** ✅ LIVE — pool at `wallet.satoshipool.org`, standalone binaries also available.

---

⚠️ IMPORTANT – Do NOT confuse them!

| Feature | Puzzle #71 (Pool) | 253-256 Scanner |
|---------|-------------------|-----------------|
| Target | Single Address | Pubkey Database (e.g., mining wallets) |
| Hashing | Full SHA/RIPEMD | None (raw memcmp) |
| Network | Required (pool) | Optional (standalone or pool) |
| Speed (RTX 4090) | 5.2 GH/s | 46.5 GH/s |
| Status | ✅ LIVE | ✅ LIVE |

If someone claims "52 GH/s on Puzzle 71" – that is FALSE.  
The 46.5 GH/s speed is EXCLUSIVELY for the 253-256 raw pubkey scanner.

---

## 🧩 How to use the binaries for puzzles #140, #145, #150, #155, and #160

Yes – the 253-256 binaries are PERFECT for these puzzles!

For puzzles #140 and above, the public key has already been revealed in the blockchain (when the funds were spent). Here's exactly how to use FastscanGPU for them:

1. Get the public key for the target puzzle (e.g., from blockchain explorers or known sources).
   - It is usually given in compressed format (33 bytes, starting with 02 or 03).

2. Convert it to uncompressed format (65 bytes, starting with 04).
   - You can do this easily with a secp256k1 library or a small Python script.
   - Important: The private key remains exactly the same – this is just a different representation of the same point on the elliptic curve.

3. Build your own `.bin` database using the included `build_pubkey_db.py` script:
```bash
python3 build_pubkey_db.py my_pubkeys.txt -o puzzle_140.bin

4. Run the binary with the 140-char hex uncompressed pubkey or .bin:
   ```bash
   ./fastscan_253_256 pubkey.bin 140 160
   ```
   Or for a specific single puzzle (e.g., #140):
   ```bash
   ./fastscan_253_256 04<X><Y> 139 140
   ```
Important difference:
-The pre-built pubkeys.bin = mining wallets only (2009-2013, uncompressed pubkeys)
-Your custom .bin = whatever you put in it (including puzzle #140, #145, #150, #155, #160, etc.)

This is the **fastest raw-pubkey scanner** ever built for NVIDIA GPUs — 46.5 GH/s on RTX 4090.

---

## Find the 7.1 BTC Bitcoin Puzzle #71 key with your GPU – 100% mathematical guarantee!

```
╔══════════════════════════════════════════════════════════════════╗
║                    POOL RULES & TERMS OF SERVICE               ║
╚══════════════════════════════════════════════════════════════════╝

1. GENERAL
   • This pool is a community-driven project for GPU-based Bitcoin
     puzzle solving and wallet hunting.
   • Participation is voluntary and open to anyone with a compatible
     NVIDIA GPU and basic technical knowledge.
   • By joining and running a worker, you automatically agree to
     these terms.

2. REWARD SPLIT (UPDATED)
   The reward for each found key is distributed as follows:

   ┌─────────────┬────────────────────────────────────────────────┐
   │   40%       │ Finder – bonus for finding the key            │
   ├─────────────┼────────────────────────────────────────────────┤
   │   55%       │ All active miners (including the finder) –    │
   │             │ proportionally to their contribution (Share)  │
   │             │ in the current round                         │
   ├─────────────┼────────────────────────────────────────────────┤
   │   5%        │ Operator – for server maintenance and         │
   │             │ development                                   │
   └─────────────┴────────────────────────────────────────────────┘

   IMPORTANT: The 55% pool is NOT exclusive to "other" miners.
   The finder is fully included and receives their fair share
   based on their contribution. This ensures that no one is
   penalized for finding the key.

3. FAIRNESS & TRUST
   • The pool uses a split-key mechanism (share d). The full
     private key is assembled by the operator.
   • This system relies on trust in the operator. By joining,
     you accept this model knowingly.
   • The operator does not have access to your private keys or
     wallet funds.

4. WORKER RULES
   • Each worker must be registered on the official website:
     https://puzzle.satoshipool.org
   • Workers must use their registered nickname and password.
   • Each GPU should run as a separate worker instance with a
     unique name (e.g., YourNick-GPU0).
   • Workers that do not send /done for more than 30 minutes
     will have their segments marked as PENDING and reassigned.

5. FAIR PLAY
   • Any attempt to cheat, spam, or exploit the system will
     result in a permanent ban.
   • Sharing someone else's worker credentials is forbidden.
   • The operator reserves the right to ban any participant who
     violates these rules.

6. PAYOUTS
   • Rewards are paid in Bitcoin (BTC) to the address provided
     during registration.
   • Payouts are processed manually after each key is found and
     confirmed.
   • The operator is not responsible for losses due to incorrect
     wallet addresses or network fees.

7. NETWORK & DOWNTIME
   • The pool operates on a best-effort basis. Occasional
     downtime may occur due to maintenance or updates.
   • Workers are designed to retry failed requests automatically.
     No work is lost.

8. PRIVACY
   • Your nickname is visible on the leaderboard.
   • Your password is stored securely as a hashed value and is
     never shared or exposed.

9. CHANGES TO RULES
   • Major changes will be announced on this Telegram group.

10. CONTACT
    • For support, questions, or bug reports, please use this
      Telegram group or contact the operator directly.

════════════════════════════════════════════════════════════════════

By running a worker, you acknowledge that you have read,
understood, and agree to these terms.
```

## ⚠️ Honest note about split-key

**EN — read before joining:**
- This pool uses **split-key**. A worker only finds **half of the key** (`share d`). The full key is assembled by the **pool operator**, who knows the secret `s`.
- In practice the reward split **relies on TRUST in the operator** (as in other pools: "whoever finds it holds the key").
- By joining you accept this model knowingly.

---

```
╔══════════════════════════════════════════════════════════════════╗
║                    REWARD SPLIT (UPDATED)                      ║
╚══════════════════════════════════════════════════════════════════╝

┌─────────────┬────────────────────────────────────────────────────┐
│   40%       │ Finder – bonus for finding the key                │
├─────────────┼────────────────────────────────────────────────────┤
│   55%       │ All active miners (including the finder) –        │
│             │ proportionally to their contribution (Share)      │
├─────────────┼────────────────────────────────────────────────────┤
│   5%        │ Operator – server maintenance and development     │
└─────────────┴────────────────────────────────────────────────────┘

════════════════════════════════════════════════════════════════════

EXPLANATION:

• 40% – goes to the person who physically found the key.
  This is a bonus for the find itself – regardless of how much
  work they contributed to the pool.

• 55% – goes to ALL ACTIVE MINERS who participated in mining
  during this round.

  THIS INCLUDES THE FINDER AS WELL.
  If the finder has, for example, 90% of the total pool share,
  they will also receive 90% of this 55%.

  This makes the system FAIR – no one loses their reward for
  finding the key, and contribution is always rewarded.

• 5% – goes to the operator (the person maintaining the server,
  paying for hosting, developing the code, etc.).

════════════════════════════════════════════════════════════════════
```

```
╔══════════════════════════════════════════════════════════════════╗
║                    REGISTRATION & SETUP                        ║
╚══════════════════════════════════════════════════════════════════╝

🔐 REGISTRATION

Before you run the worker, you MUST register on the website:
👉 https://puzzle.satoshipool.org/

During registration you provide:
  • Nick – displayed in the leaderboard
  • Bitcoin address – where the reward will be sent
    (CANNOT BE CHANGED LATER!)
  • Password – used to log in to the website and to run the worker

────────────────────────────────────────────────────────────────────

📌 EXAMPLE COMMANDS

🐧 LINUX – Puzzle #71 (RTX 40xx, faster):
python3 pool_worker.py \
  --server https://puzzle.satoshipool.org \
  --worker YourNick \
  --password YourPassword \
  --binary ./fastscan_puzzle71RTX40xx

🐧 LINUX – Puzzle #71 (all cards):
python3 pool_worker.py \
  --server https://puzzle.satoshipool.org \
  --worker YourNick \
  --password YourPassword \
  --binary ./fastscan_puzzle71ALLCARDS

🪟 WINDOWS – Puzzle #71 (newer cards):
python pool_worker.py \
  --server https://puzzle.satoshipool.org \
  --worker YourNick \
  --password YourPassword \
  --binary fastscan_puzzle71.exe

🪟 WINDOWS – Puzzle #71 (older cards):
python pool_worker.py \
  --server https://puzzle.satoshipool.org \
  --worker YourNick \
  --password YourPassword \
  --binary fastscan_71LEGACY.exe

🐧 LINUX – Wallets 253-256:
python3 pool_worker_253_256.py \
  --server https://wallet.satoshipool.org \
  --worker YourNick \
  --password YourPassword \
  --binary ./fastscan_253_256 \
  --db ./pubkeys.bin

🪟 WINDOWS – Wallets 253-256 (RTX 20xx+):
python pool_worker_253_256.py \
  --server https://wallet.satoshipool.org \
  --worker YourNick \
  --password YourPassword \
  --binary fastscan_253_256.exe \
  --db pubkeys.bin

🪟 WINDOWS – Wallets 253-256 (GTX 9xx/10xx LEGACY):
python pool_worker_253_256.py \
  --server https://wallet.satoshipool.org \
  --worker YourNick \
  --password YourPassword \
  --binary fastscan_253_256_LEGACY.exe \
  --db pubkeys.bin

────────────────────────────────────────────────────────────────────

🖥️ MULTI-GPU SETUP

🐧 LINUX / WSL

# Terminal 1 – GPU 0
CUDA_VISIBLE_DEVICES=0 python3 pool_worker.py \
  --server https://puzzle.satoshipool.org \
  --worker YourNick-GPU0 \
  --password YourPassword \
  --binary ./fastscan_puzzle71ALLCARDS

# Terminal 2 – GPU 1
CUDA_VISIBLE_DEVICES=1 python3 pool_worker.py \
  --server https://puzzle.satoshipool.org \
  --worker YourNick-GPU1 \
  --password YourPassword \
  --binary ./fastscan_puzzle71ALLCARDS

🪟 WINDOWS (cmd.exe)

:: Terminal 1 – GPU 0
set CUDA_VISIBLE_DEVICES=0
python pool_worker.py --server https://puzzle.satoshipool.org --worker YourNick-GPU0 --password YourPassword --binary fastscan_puzzle71.exe

:: Terminal 2 – GPU 1
set CUDA_VISIBLE_DEVICES=1
python pool_worker.py --server https://puzzle.satoshipool.org --worker YourNick-GPU1 --password YourPassword --binary fastscan_puzzle71.exe
```

---

## 🖥️ MULTI‑GPU SETUP (AUTO‑DETECT)

The `fastscan_253_256` binary **automatically detects all available NVIDIA GPUs** and distributes the workload across them—right out of the box.  
You only need to launch **a single worker** instance; the binary handles the rest.

```bash
python3 pool_worker_253_256.py \
  --server https://wallet.satoshipool.org \
  --worker YourNick \
  --password YourPassword \
  --binary ./fastscan_253_256 \
  --db ./pubkeys.bin
```

```
────────────────────────────────────────────────────────────────────
⚙️ HOW IT WORKS

  • CUDA_VISIBLE_DEVICES=N limits the process to only GPU N
    — no code changes needed.
  • Each worker instance gets unique work segments from the pool
    server — the GPUs never duplicate the same work.
  • Use nvidia-smi to list your available GPUs and their IDs.
  • Run one terminal per GPU — the pool dashboard will show each
    as a separate miner.
────────────────────────────────────────────────────────────────────
```

```
╔══════════════════════════════════════════════════════════════════╗
║                    HOW TO JOIN (MINER)                         ║
╚══════════════════════════════════════════════════════════════════╝

REQUIREMENTS:
  • NVIDIA GPU with CUDA support
  • Python 3
  • fastscan binary
  • gtableX.bin and gtableY.bin in the same directory

────────────────────────────────────────────────────────────────────

⚙️ HOW IT WORKS

  • The server tells the worker WHAT to scan and within WHAT RANGE
    (the mode is selected by the operator).
  • In WALLETS mode, add the local pubkey database:
    --db pubkeys.bin
  • The worker AUTOMATICALLY sends any found share to the server.
  • Findings are saved locally (persistently) and retried,
    so they WILL NOT BE LOST in the event of a network failure.

────────────────────────────────────────────────────────────────────

🖥️ RUN THE SERVER (OPERATOR ONLY)

🔹 PUZZLE MODE (single address):

python3 pool_server.py init --mode puzzle \
  --address 1PWo3JeB9jrGwfHDNpdGK54CRas7fsVzXU \
  --start-bit 70 --end-bit 71

⚠️ SAVE the printed SECRET s !!!

🔹 WALLETS MODE (.bin database, default comp+uncomp):

python3 pool_server.py init --mode wallets \
  --db pubkeys.bin \
  --start-bit 253 --end-bit 256

════════════════════════════════════════════════════════════════════
```

```
╔══════════════════════════════════════════════════════════════════╗
║                    HOW IT WORKS & FILES                        ║
╚══════════════════════════════════════════════════════════════════╝

🔧 HOW IT WORKS

  1. The operator draws a secret s

  2. The worker scans its assigned hash160 range and compares
     it against the target.

  3. On a hit → the worker knows only d (half-key) and sends it
     to the server.

  4. The server assembles the full key and verifies the address.

────────────────────────────────────────────────────────────────────

📂 REQUIRED FILES

┌────────────────────────────────────┬──────────────────────────────────────┐
│ File                               │ Description                         │
├────────────────────────────────────┼──────────────────────────────────────┤
│ fastscan_puzzle71ALLCARDS (Linux)  │ Linux universal binary              │
│                                    │ (all cards from GTX 10xx to 50xx)  │
├────────────────────────────────────┼──────────────────────────────────────┤
│ fastscan_puzzle71RTX40xx (Linux)   │ Linux binary for RTX 40xx+ only     │
│                                    │ (faster, sm_89/sm_90)              │
├────────────────────────────────────┼──────────────────────────────────────┤
│ fastscan_71LEGACY.exe (Windows)    │ Windows binary for older cards      │
│                                    │ (GTX 9xx, GTX 10xx, RTX 20xx)      │
├────────────────────────────────────┼──────────────────────────────────────┤
│ fastscan_puzzle71.exe (Windows)    │ Windows binary for newer cards      │
│                                    │ (RTX 20xx, 30xx, 40xx, 50xx+)      │
├────────────────────────────────────┼──────────────────────────────────────┤
│ libcrypto-3-x64.dll                │ OpenSSL library (cryptography)      │
│ (Windows)                          │                                      │
├────────────────────────────────────┼──────────────────────────────────────┤
│ libssl-3-x64.dll                   │ OpenSSL library (TLS/SSL)           │
│ (Windows)                          │                                      │
├────────────────────────────────────┼──────────────────────────────────────┤
│ gtableX.bin                        │ Mathematical tables (point G)       │
│                                    │ – REQUIRED                          │
├────────────────────────────────────┼──────────────────────────────────────┤
│ gtableY.bin                        │ Mathematical tables (point G)       │
│                                    │ – REQUIRED                          │
├────────────────────────────────────┼──────────────────────────────────────┤
│ pool_worker.py                     │ Python coordinator                  │
│                                    │ (connects to the server)            │
└────────────────────────────────────┴──────────────────────────────────────┘
```

### 🔧 Generate Gtables yourself

If you don't want to download my pre-built gtables, you can generate them yourself using `generate_gtable.cpp` included in this repo.

**What gets generated (4 files, ~32 MB each):**

| File | Description |
|------|-------------|
| `gtableX.bin` | Uncompressed X coordinates (16 chunks × 65536 points) |
| `gtableY.bin` | Uncompressed Y coordinates |
| `gtable_compX.bin` | Compressed X coordinates (33 bytes per point) |
| `gtable_compY.bin` | Parity bits for compressed points |

**Prerequisites:**
- `g++` (GCC / MinGW / MSYS2)
- OpenSSL development headers (`libssl-dev` on Linux, `openssl-devel` on MSYS2)

**Linux (Ubuntu/Debian):**
```bash
# Install dependencies
sudo apt install -y g++ libssl-dev
# Compile & run
g++ -O3 -o generate_gtable generate_gtable.cpp -lcrypto
./generate_gtable
```

**Windows (MSYS2):**
```bash
# Install dependencies
pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-openssl
# Compile & run
g++ -O3 -o generate_gtable.exe generate_gtable.cpp -lcrypto
./generate_gtable.exe
```

Expected output (4 files in current directory):
```
✅ gtableX.bin      (32 MB)  — uncompressed X
✅ gtableY.bin      (32 MB)  — uncompressed Y
✅ gtable_compX.bin (32 MB)  — compressed X
✅ gtable_compY.bin (32 MB)  — compressed parity
```

```
════════════════════════════════════════════════════════════════════

╔══════════════════════════════════════════════════════════════════╗
║           PROBABILITY OF FINDING THE KEY                       ║
╚══════════════════════════════════════════════════════════════════╝

A system based on DIVIDING THE RANGE INTO DISJOINT CHUNKS offers
a unique feature among GPU architectures – the probability of
finding the key INCREASES OVER TIME.

The more keys searched, the smaller the remaining unsearched area,
and the higher the chance of a hit in the next second.

────────────────────────────────────────────────────────────────────

📐 MATHEMATICAL FORMULA

P(t) = (N_searched(t) / N_total) * 100%

Where:
  • P(t)         – probability of finding the key by time t
  • N_searched(t) – number of keys searched up to time t
  • N_total      – total number of keys in the given range

EVERY SECOND increases the total probability until it reaches 100%.

────────────────────────────────────────────────────────────────────

📊 EXAMPLE (71-bit range)

A 71-bit range is N_total ≈ 2.36 × 10²¹ keys.

┌─────────────────────┬─────────────────┬─────────────────────────┐
│ Keys searched       │ Area searched   │ Probability of finding │
├─────────────────────┼─────────────────┼─────────────────────────┤
│ 2.36 × 10²⁰         │ 10%             │ 10%                     │
│ 1.18 × 10²¹         │ 50%             │ 50%                     │
│ 2.12 × 10²¹         │ 90%             │ 90%                     │
│ 2.36 × 10²¹         │ 100%            │ 100%                    │
└─────────────────────┴─────────────────┴─────────────────────────┘

────────────────────────────────────────────────────────────────────

🏆 WHAT THIS MEANS IN PRACTICE

  ✓ 100% GUARANTEE – if the key exists in the given range,
    it WILL be found.

  ✓ ZERO OVERLAP – no key is ever checked twice.

  ✓ MEASURABLE PROGRESS – you always know how much is left.

  ✓ INCREASING ODDS – the probability grows every minute
    until it reaches 100%.

────────────────────────────────────────────────────────────────────

🔥 This is the ONLY GPU architecture that gives a MATHEMATICAL
    GUARANTEE of finding the key.

════════════════════════════════════════════════════════════════════
```

```
╔══════════════════════════════════════════════════════════════════╗
║              SECURITY & SUPPORTED GPUs                         ║
╚══════════════════════════════════════════════════════════════════╝

🔒 SECURITY

  • Keep the secret s OFFLINE – without it you cannot assemble
    the full key.
  • Traffic goes over HTTPS.
  • Split-key protects against "running off with the reward" only
    in the trust model (see the note above).

────────────────────────────────────────────────────────────────────

🖥️ SUPPORTED GPUs

🐧 LINUX – two versions

┌────────────────────────────────────┬──────────────────────────────────┐
│ File                              │ Supported GPUs                  │
├────────────────────────────────────┼──────────────────────────────────┤
│ fastscan_puzzle71ALLCARDS          │ UNIVERSAL – all cards from     │
│                                    │ GTX 10xx to RTX 50xx           │
│                                    │ (sm_60–sm_90)                  │
├────────────────────────────────────┼──────────────────────────────────┤
│ fastscan_puzzle71RTX40xx           │ RTX 40xx (Ada), RTX 50xx+      │
│                                    │ (faster, sm_89/sm_90 only)     │
└────────────────────────────────────┴──────────────────────────────────┘

🪟 WINDOWS – two versions

┌────────────────────────────────────┬──────────────────────────────────┐
│ File                              │ Supported GPUs                  │
├────────────────────────────────────┼──────────────────────────────────┤
│ fastscan_71LEGACY.exe              │ GTX 9xx, GTX 10xx (Pascal),    │
│                                    │ RTX 20xx (Turing)              │
│                                    │ (CUDA 12.3, sm_50–sm_75)       │
├────────────────────────────────────┼──────────────────────────────────┤
│ fastscan_puzzle71.exe              │ RTX 20xx, 30xx, 40xx, 50xx+    │
│                                    │ (CUDA 13.3, sm_75–sm_90)       │
└────────────────────────────────────┴──────────────────────────────────┘

────────────────────────────────────────────────────────────────────

🔵 253‑256 FORGOTTEN WALLETS FILES

🐧 LINUX

┌────────────────────────────────────┬──────────────────────────────────┐
│ File                              │ Supported GPUs                  │
├────────────────────────────────────┼──────────────────────────────────┤
│ fastscan_253_256 (no extension)    │ UNIVERSAL – all cards from     │
│                                    │ GTX 10xx to RTX 50xx           │
│                                    │ (sm_60–sm_90)                  │
└────────────────────────────────────┴──────────────────────────────────┘

🪟 WINDOWS – two versions

┌────────────────────────────────────┬──────────────────────────────────┐
│ File                              │ Supported GPUs                  │
├────────────────────────────────────┼──────────────────────────────────┤
│ fastscan_253_256.exe               │ RTX 20xx, 30xx, 40xx, 50xx+    │
│                                    │ (sm_75–sm_90)                  │
├────────────────────────────────────┼──────────────────────────────────┤
│ fastscan_253_256_LEGACY.exe        │ GTX 9xx, GTX 10xx (Pascal),    │
│                                    │ RTX 20xx (Turing)              │
│                                    │ (sm_50–sm_75)                  │
└────────────────────────────────────┴──────────────────────────────────┘

📦 ADDITIONAL FILES (required for 253-256)

┌────────────────────────────────────┬──────────────────────────────────┐
│ File                              │ Description                     │
├────────────────────────────────────┼──────────────────────────────────┤
│ pool_worker_253_256.py             │ Pool worker script (Python 3)   │
├────────────────────────────────────┼──────────────────────────────────┤
│ pubkeys.bin                        │ 1.5M+ pubkey database            │
├────────────────────────────────────┼──────────────────────────────────┤
│ gtableX.bin                        │ GPU precomputed table (X)       │
├────────────────────────────────────┼──────────────────────────────────┤
│ gtableY.bin                        │ GPU precomputed table (Y)       │
├────────────────────────────────────┼──────────────────────────────────┤
│ libcrypto-3-x64.dll                │ OpenSSL DLL (shared with P71)   │
├────────────────────────────────────┼──────────────────────────────────┤
│ libssl-3-x64.dll                   │ OpenSSL DLL (shared with P71)   │
└────────────────────────────────────┴──────────────────────────────────┘

🎯 WHICH 253-256 BINARY TO USE?

┌───────────────────────────────┬──────────────────────┬──────────────────────┐
│ Your GPU                     │ Windows (choose)     │ Linux (choose)       │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ GTX 9xx (Maxwell)            │ 253_256_LEGACY       │ fastscan_253_256     │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ GTX 10xx (Pascal)            │ 253_256_LEGACY       │ fastscan_253_256     │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ GTX 16xx / RTX 20xx (Turing) │ BOTH work            │ fastscan_253_256     │
│                               │ (LEGACY or .exe)     │                      │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ RTX 30xx (Ampere)            │ fastscan_253_256.exe │ fastscan_253_256     │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ RTX 40xx (Ada)               │ fastscan_253_256.exe │ fastscan_253_256     │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ RTX 50xx (Blackwell) + newer │ fastscan_253_256.exe │ fastscan_253_256     │
└───────────────────────────────┴──────────────────────┴──────────────────────┘

────────────────────────────────────────────────────────────────────

🎯 WHICH BINARY TO USE?

┌───────────────────────────────┬──────────────────────┬──────────────────────┐
│ Your GPU                     │ Windows (choose)     │ Linux (choose)       │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ GTX 9xx (Maxwell)            │ fastscan_71LEGACY    │ ALLCARDS             │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ GTX 10xx (Pascal)            │ fastscan_71LEGACY    │ ALLCARDS             │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ GTX 16xx / RTX 20xx (Turing) │ BOTH work            │ ALLCARDS             │
│                               │ (LEGACY or puzzle71)│                      │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ RTX 30xx (Ampere)            │ fastscan_puzzle71    │ ALLCARDS             │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ RTX 40xx (Ada)               │ fastscan_puzzle71    │ RTX40xx (faster)     │
│                               │                      │ or ALLCARDS          │
├───────────────────────────────┼──────────────────────┼──────────────────────┤
│ RTX 50xx (Blackwell) + newer │ fastscan_puzzle71    │ RTX40xx or ALLCARDS  │
└───────────────────────────────┴──────────────────────┴──────────────────────┘

────────────────────────────────────────────────────────────────────

🔧 HOW TO CHECK YOUR GPU

WINDOWS:
  • Task Manager → Performance tab → GPU
  • Or in CMD: nvidia-smi

LINUX:
  nvidia-smi
  lspci | grep -i nvidia

────────────────────────────────────────────────────────────────────
```

```
DONATE: bc1qps62cyk9f9unmdkc9k3ccj9e2h8ywfhg2j53ec

Built with ❤️ for the crypto research community.
────────────────────────────────────────────────────────────────────
⚠️ DISCLAIMER

Searching Bitcoin puzzle keys is legal.
Searching for other people's in-use wallets is NOT.
Use responsibly.

════════════════════════════════════════════════════════════════════
```
