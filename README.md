# Bitcoin Puzzle / Wallet Pool (split-key) — GPU
![GitHub stars](https://img.shields.io/github/stars/ethicbrudhack/FastscanGPU-BitcoinPuzzleChallengeBreaker-?style=social)
![GitHub forks](https://img.shields.io/github/forks/ethicbrudhack/FastscanGPU-BitcoinPuzzleChallengeBreaker-?style=social)
![License](https://img.shields.io/badge/license-MIT-green)
![Python](https://img.shields.io/badge/python-3.8%2B-blue)
![CUDA](https://img.shields.io/badge/CUDA-12.3%2B-green)
> > 
>READ BEFORE RUNNING!!: ⚠⚠⚠If anyone has the following problem!: the scanner scans much faster than it should! then you probably didn't include all the files in the folder you're running from!! VERY IMPORTANT, THEN IT WILL NOT SCAN ANY KEY!⚠⚠⚠
> >
> > ## 📊 Live Stats

![Puzzle 71 Progress](https://img.shields.io/badge/dynamic/json?url=https://fastscangpu.duckdns.org/stats&query=$.round_progress_pct&label=Progress&color=orange&suffix=%25)
![Keys Found](https://img.shields.io/badge/dynamic/json?url=https://fastscangpu.duckdns.org/stats&query=$.hits&label=Keys%20Found&color=success)
![Pool Speed](https://img.shields.io/badge/dynamic/json?url=https://fastscangpu.duckdns.org/stats&query=$.keys_per_sec&label=Speed&color=blue&suffix=%20Gkeys/s)
> > 
> **EN:** Distributed GPU pool for finding Bitcoin keys: **Puzzle #71** (single address,
> small range) and **forgotten wallets** (a database of thousands of addresses, large
> range). The server hands out disjoint work segments (no overlap), workers compute on
> the GPU, and the reward is split by contribution.
> 
<img width="1600" height="1000" alt="chunk_evolution" src="https://github.com/user-attachments/assets/4f8b3985-1106-47b9-8339-2833d2dded62" />

---
##📥 Download: 
```
```
📥adresy_unique.bin: https://drive.google.com/file/d/1vTkDbWXIwtv2_V-_FnuW6QjonaCd_XSx/view?usp=drive_link



📥Gtable: https://drive.google.com/file/d/1IggsvXIFmHWjiw4Rh-bKAKwWJ0OYxL9l/view?usp=drive_link


📥Independent FastscanGPU Code: https://drive.google.com/file/d/1i-fn8DL8AvYbocCLn_HIZSuetUfCA-eE/view?usp=drive_link


🌐 Website: https://fastscangpu.duckdns.org/


💬 Telegram https://t.me/+39k4WcVDfYhiMWFk




````

Find the 7.1 BTC Bitcoin Puzzle #71 key with your GPU – 100% mathematical guarantee!
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
     https://fastscangpu.duckdns.org
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
   • Your nickname is visible on the
     leaderboard.
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

## ⚠️ Honest note about split-key


**EN — read before joining:**
- This pool uses **split-key**. A worker only finds **half of the key** (`share d`).
  The full key is assembled by the **pool operator**, who knows the
  secret `s`.
- In practice the reward split **relies on TRUST in the operator** (as in other pools:
  "whoever finds it holds the key").
- By joining you accept this model knowingly.

---

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


╔══════════════════════════════════════════════════════════════════╗
║                    REGISTRATION & SETUP                        ║
╚══════════════════════════════════════════════════════════════════╝

🔐 REGISTRATION

Before you run the worker, you MUST register on the website:
👉 https://fastscangpu.duckdns.org/

During registration you provide:
  • Nick – displayed in the leaderboard
  • Bitcoin address – where the reward will be sent
    (CANNOT BE CHANGED LATER!)
  • Password – used to log in to the website and to run the worker

────────────────────────────────────────────────────────────────────

📌 EXAMPLE COMMAND

python3 pool_worker.py \
  --server https://fastscangpu.duckdns.org \
  --worker SatoshiHunter \
  --password YourPassword \
  --binary ./fastscan

(Use ./fastscan on Linux or fastscan.exe on Windows)

────────────────────────────────────────────────────────────────────

🖥️ MULTI-GPU SETUP

To use multiple GPUs simultaneously, run a SEPARATE worker instance
for each GPU. Each worker connects independently and receives its
own unique work segments — no duplicate work, no wasted effort.

REQUIREMENTS:
  • Each worker instance must use a DIFFERENT --worker nickname
  • Example: YourNick-GPU0, YourNick-GPU1, YourNick-GPU2, etc.

────────────────────────────────────────────────────────────────────

🐧 LINUX / WSL

# Terminal 1 – GPU 0
CUDA_VISIBLE_DEVICES=0 python3 pool_worker.py \
  --server https://fastscangpu.duckdns.org \
  --worker YourNick-GPU0 \
  --password YourPassword \
  --binary ./fastscan \
  --db ./adresy_unique.bin

# Terminal 2 – GPU 1
CUDA_VISIBLE_DEVICES=1 python3 pool_worker.py \
  --server https://fastscangpu.duckdns.org \
  --worker YourNick-GPU1 \
  --password YourPassword \
  --binary ./fastscan \
  --db ./adresy_unique.bin

# ... repeat for each additional GPU

────────────────────────────────────────────────────────────────────

🪟 WINDOWS (cmd.exe)

:: Terminal 1 – GPU 0
set CUDA_VISIBLE_DEVICES=0
python pool_worker.py --server https://fastscangpu.duckdns.org --worker YourNick-GPU0 --password YourPassword --binary fastscan.exe --db adresy_unique.bin

:: Terminal 2 – GPU 1
set CUDA_VISIBLE_DEVICES=1
python pool_worker.py --server https://fastscangpu.duckdns.org --worker YourNick-GPU1 --password YourPassword --binary fastscan.exe --db adresy_unique.bin

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

🚀 253-256 BIT SERVER – HOW TO JOIN

LINUX:
python3 pool_worker.py \
  --server http://91.98.41.38:8082 \
  --worker YourNick \
  --password YourPassword \
  --binary ./fastscan \
  --db ./adresy_unique.bin

WINDOWS:
python pool_worker.py \
  --server http://91.98.41.38:8082 \
  --worker YourNick \
  --password YourPassword \
  --binary fastscan.exe \
  --db ./adresy_unique.bin

════════════════════════════════════════════════════════════════════
---
---
╔══════════════════════════════════════════════════════════════════╗
║                    HOW TO JOIN (MINER)                         ║
╚══════════════════════════════════════════════════════════════════╝

REQUIREMENTS:
  • NVIDIA GPU with CUDA support
  • Python 3
  • fastscan binary
  • gtableX.bin and gtableY.bin in the same directory

────────────────────────────────────────────────────────────────────

🐧 LINUX

python3 pool_worker.py \
  --server https://fastscangpu.duckdns.org \
  --worker YOUR_NICK \
  --password YOUR_PASSWORD \
  --binary ./fastscan

────────────────────────────────────────────────────────────────────

🪟 WINDOWS (cmd / PowerShell)

python pool_worker.py \
  --server https://fastscangpu.duckdns.org \
  --worker YOUR_NICK \
  --password YOUR_PASSWORD \
  --binary fastscan.exe

────────────────────────────────────────────────────────────────────

📌 EXAMPLE

python3 pool_worker.py \
  --server https://fastscangpu.duckdns.org \
  --worker SatoshiHunter \
  --password YourPassword123 \
  --binary ./fastscan

(Use ./fastscan on Linux or fastscan.exe on Windows)

────────────────────────────────────────────────────────────────────

⚙️ HOW IT WORKS

  • The server tells the worker WHAT to scan and within WHAT RANGE
    (the mode is selected by the operator).
  • In WALLETS mode, add the local address database:
    --db adresy_unique.bin
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
  --db adresy_unique.bin \
  --start-bit 253 --end-bit 256

════════════════════════════════════════════════════════════════════

---

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

┌─────────────────────────┬──────────────────────────────────────┐
│ File                    │ Description                         │
├─────────────────────────┼──────────────────────────────────────┤
│ fastscan (Linux)        │ Universal GPU binary for Linux      │
│                         │ (all cards)                         │
├─────────────────────────┼──────────────────────────────────────┤
│ fastscan.exe (Windows)  │ GPU binary for newer cards          │
│                         │ (RTX 20xx, 30xx, 40xx, 50xx+)      │
├─────────────────────────┼──────────────────────────────────────┤
│ fastscan_legacy.exe     │ GPU binary for older cards          │
│ (Windows)               │ (GTX 9xx, GTX 10xx)                 │
├─────────────────────────┼──────────────────────────────────────┤
│ libcrypto-3-x64.dll     │ OpenSSL library (cryptography)      │
│ (Windows)               │                                      │
├─────────────────────────┼──────────────────────────────────────┤
│ libssl-3-x64.dll        │ OpenSSL library (TLS/SSL)           │
│ (Windows)               │                                      │
├─────────────────────────┼──────────────────────────────────────┤
│ libsecp256k1.dll        │ Bitcoin elliptic curve library      │
│ (Windows)               │                                      │
├─────────────────────────┼──────────────────────────────────────┤
│ mman.dll (Windows)      │ mmap implementation for Windows     │
├─────────────────────────┼──────────────────────────────────────┤
│ gtableX.bin             │ Mathematical tables (point G)       │
│                         │ – REQUIRED                          │
├─────────────────────────┼──────────────────────────────────────┤
│ gtableY.bin             │ Mathematical tables (point G)       │
│                         │ – REQUIRED                          │
├─────────────────────────┼──────────────────────────────────────┤
│ gtable_compX.bin        │ Tables for compressed addresses     │
├─────────────────────────┼──────────────────────────────────────┤
│ gtable_compY.bin        │ Tables for compressed addresses     │
├─────────────────────────┼──────────────────────────────────────┤
│ pool_worker.py          │ Python coordinator                  │
│                         │ (connects to the server)            │
└─────────────────────────┴──────────────────────────────────────┘

════════════════════════════════════════════════════════════════════

---
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

The project offers TWO BINARY VERSIONS on Windows and ONE UNIVERSAL
BINARY on Linux.

────────────────────────────────────────────────────────────────────

🪟 WINDOWS

┌─────────────────────────┬──────────────────────────────────────┐
│ Version                 │ Description                         │
├─────────────────────────┼──────────────────────────────────────┤
│ fastscan_legacy.exe     │ For older cards (GTX 9xx, GTX 10xx) │
│                         │ – CUDA 12.3                        │
├─────────────────────────┼──────────────────────────────────────┤
│ fastscan.exe            │ For newer cards (RTX 20xx, 30xx,   │
│                         │ 40xx, 50xx+) – CUDA 13.3           │
└─────────────────────────┴──────────────────────────────────────┘

────────────────────────────────────────────────────────────────────

🏛️ fastscan_legacy.exe – OLDER CARDS (CUDA 12.3)

┌───────────────┬───────────────────────────────┬─────────────────┐
│ Architecture  │ GPU Cards                     │ Compute Cap.    │
├───────────────┼───────────────────────────────┼─────────────────┤
│ Maxwell       │ GTX 9xx (960, 970, 980, Ti)   │ 5.0 / 5.2       │
│ Pascal        │ GTX 10xx (1050–1080 Ti)       │ 6.0 / 6.1       │
│ Turing        │ GTX 16xx / RTX 20xx           │ 7.5             │
└───────────────┴───────────────────────────────┴─────────────────┘

────────────────────────────────────────────────────────────────────

⚡ fastscan.exe – NEWER CARDS (CUDA 13.3)

┌───────────────┬───────────────────────────────┬─────────────────┐
│ Architecture  │ GPU Cards                     │ Compute Cap.    │
├───────────────┼───────────────────────────────┼─────────────────┤
│ Turing        │ GTX 16xx / RTX 20xx           │ 7.5             │
│ Ampere        │ RTX 30xx (3060–3090 Ti)       │ 8.0 / 8.6       │
│ Ada           │ RTX 40xx (4060–4090)          │ 8.9             │
│ Blackwell     │ RTX 50xx and newer (PTX/JIT)  │ 9.0+ (auto)     │
└───────────────┴───────────────────────────────┴─────────────────┘

────────────────────────────────────────────────────────────────────

🐧 LINUX – ONE UNIVERSAL BINARY (Fat Binary)

Supports all cards from GTX 9xx to RTX 50xx and beyond via PTX/JIT.

┌───────────────┬───────────────────────────────┬─────────────────┐
│ Architecture  │ GPU Cards                     │ Compute Cap.    │
├───────────────┼───────────────────────────────┼─────────────────┤
│ Maxwell       │ GTX 9xx (960, 970, 980, Ti)   │ 5.2             │
│ Pascal        │ GTX 10xx (1050–1080 Ti)       │ 6.1             │
│ Turing        │ GTX 16xx / RTX 20xx           │ 7.5             │
│ Ampere        │ RTX 30xx (3060–3090 Ti)       │ 8.6             │
│ Ada           │ RTX 40xx (4060–4090)          │ 8.9             │
│ Blackwell     │ RTX 50xx and newer (PTX/JIT)  │ 9.0+ (auto)     │
└───────────────┴───────────────────────────────┴─────────────────┘

────────────────────────────────────────────────────────────────────

🎯 WHICH BINARY TO USE?

┌───────────────────────────────┬───────────────┬───────────────┐
│ Your GPU                     │ Windows       │ Linux         │
├───────────────────────────────┼───────────────┼───────────────┤
│ GTX 750, GTX 9xx             │ legacy        │ ./fastscan    │
│ GTX 10xx (Pascal)            │ legacy        │ ./fastscan    │
│ GTX 16xx / RTX 20xx (Turing) │ BOTH work     │ ./fastscan    │
│ RTX 30xx (Ampere)            │ fastscan.exe  │ ./fastscan    │
│ RTX 40xx (Ada)               │ fastscan.exe  │ ./fastscan    │
│ RTX 50xx (Blackwell) + newer │ fastscan.exe  │ ./fastscan    │
└───────────────────────────────┴───────────────┴───────────────┘

────────────────────────────────────────────────────────────────────

🔧 HOW TO CHECK YOUR GPU

WINDOWS:
  • Task Manager → Performance tab → GPU
  • Or in CMD: nvidia-smi

LINUX:
  nvidia-smi
  lspci | grep -i nvidia

────────────────────────────────────────────────────────────────────

⚠️ DISCLAIMER

Educational / hobby project.
Searching Bitcoin puzzle keys is legal.
Searching for other people's in-use wallets is NOT.
Use responsibly.

════════════════════════════════════════════════════════════════════
*other people's in-use wallets is not. Use responsibly.*
