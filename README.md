# Bitcoin Puzzle / Wallet Pool (split-key) — GPU
Please report any bugs or issues, preferably via the Telegram server; the 253–256-bit server will be launched next month.
> **PL:** Rozproszony pool GPU do szukania kluczy Bitcoin: **Puzzle #71** (jeden adres,
> mały zakres) oraz **zapomniane portfele** (baza tysięcy adresów, duży zakres).
> Serwer rozdaje rozłączne segmenty pracy (zero dubli), workerzy liczą na GPU,
> a nagroda dzielona jest wg wkładu.
>
> **EN:** Distributed GPU pool for finding Bitcoin keys: **Puzzle #71** (single address,
> small range) and **forgotten wallets** (a database of thousands of addresses, large
> range). The server hands out disjoint work segments (no overlap), workers compute on
> the GPU, and the reward is split by contribution.
<img width="1600" height="1000" alt="chunk_evolution" src="https://github.com/user-attachments/assets/4f8b3985-1106-47b9-8339-2833d2dded62" />

---
##🧩 Download links: 
```
```
adresy_unique.bin: https://drive.google.com/file/d/1vTkDbWXIwtv2_V-_FnuW6QjonaCd_XSx/view?usp=drive_link



Gtable: https://drive.google.com/file/d/1IggsvXIFmHWjiw4Rh-bKAKwWJ0OYxL9l/view?usp=drive_link


Independent FastscanGPU Code: https://drive.google.com/file/d/1i-fn8DL8AvYbocCLn_HIZSuetUfCA-eE/view?usp=drive_link

````

Telegram: https://t.me/+39k4WcVDfYhiMWFk
yt video: https://www.youtube.com/watch?v=xV7tdUcGEhg

`
`
## ⚠️ Uczciwa nota o split-key / Honest note about split-key

**PL — przeczytaj zanim dołączysz:**
- Ten pool używa **split-key**. Worker znajduje tylko **połowę klucza** (`share d`).
  Pełny klucz składa **operator poola**, który zna sekret `s`.
- **To NIE jest kryptograficzna gwarancja podziału nagrody.** W chwili trafienia
- W praktyce oznacza to, że **podział nagrody opiera się na ZAUFANIU do operatora**
  (tak samo jak w innych poolach typu „kto znajdzie, ma klucz”).
- Dołączając, akceptujesz ten model świadomie.

**EN — read before joining:**
- This pool uses **split-key**. A worker only finds **half of the key** (`share d`).
  The full key is assembled by the **pool operator**, who knows the
  secret `s`.
- In practice the reward split **relies on TRUST in the operator** (as in other pools:
  "whoever finds it holds the key").
- By joining you accept this model knowingly.

---

## 💰 Podział nagrody / Reward split

| | PL | EN |
|---|---|---|
| **40%** | znalazca | finder |
| **55%** | reszta kopaczy wg wkładu | rest of miners by contribution |
| **5%** | operator | operator |

---
### 🔐 Rejestracja / Registration

**PL:** Zanim uruchomisz workera, musisz **zarejestrować się na stronie**:
👉 **https://fastscangpu.duckdns.org/**

Podczas rejestracji podajesz:
- **Nick** – wyświetlany w rankingu,
- **Adres Bitcoin** – na który trafi nagroda (NIE MOŻNA GO PÓŹNIEJ ZMIENIĆ!),
- **Hasło** – używane do logowania na stronie i do uruchomienia workera.

**EN:** Before you run the worker, you must **register on the website**:
👉 **https://fastscangpu.duckdns.org/**

During registration you provide:
- **Nick** – displayed in the leaderboard,
- **Bitcoin address** – where the reward will be sent (CANNOT BE CHANGED LATER!),
- **Password** – used to log in to the website and to run the worker.
---
example:
python3 pool_worker.py --server https://fastscangpu.duckdns.org --worker SatoshiHunter --password mojeHaslo123 --binary ./fastscan or ./fastscan.exe
---
## 🚀 Jak dołączyć (kopacz) / How to join (miner)

**Wymagania / Requirements:** karta NVIDIA (CUDA), Python 3, binarka `fastscan`
i pliki `gtableX.bin`, `gtableY.bin` w tym samym katalogu.

```bash
# PL: Linux / EN: Linux
python3 pool_worker.py \
  --server https://fastscangpu.duckdns.org \
  --worker TWOJ_NICK \
  --binary ./fastscan
  --password TWOJE_HASLO
# PL: Windows (cmd/PowerShell) / EN: Windows (cmd/PowerShell)
python pool_worker.py \
  --server https://fastscangpu.duckdns.org \
  --worker TWOJ_NICK \
  --password YOUR_PASSWORD
  --binary fastscan.exe
```
example : python3 pool_worker.py --server https://fastscangpu.duckdns.org --worker SatoshiHunter --password mojeHaslo123 --binary ./fastscan or ./fastscan.exe

- Serwer sam mówi workerowi **co** i **w jakim zakresie** skanować (tryb wybiera operator).
- W trybie **wallets** dodaj lokalną bazę adresów: `--db adresy_unique.bin`.
- Worker **sam** wysyła znaleziony `share` na serwer. Znaleziska są zapisywane
  lokalnie (trwale) i ponawiane, więc **nie przepadną przy awarii sieci**.

- The server tells the worker **what** to scan and **within what range** (the mode is selected by the operator).
- In **wallets** mode, add the local address database: `--db adresy_unique.bin`.
- The worker **automatically** sends any found `share` to the server. Findings are saved
  locally (persistently) and retried, so **they will not be lost in the event of a network failure**.

## 🖥️ Uruchomienie serwera (operator) / Run the server (operator)

```bash
# PL: tryb puzzle (jeden adres) / EN: puzzle mode (single address)
python3 pool_server.py init --mode puzzle \
  --address 1PWo3JeB9jrGwfHDNpdGK54CRas7fsVzXU --start-bit 70 --end-bit 71
# !!! ZAPISZ wypisany SECRET s / SAVE the printed SECRET s !!!

# PL: tryb wallets (baza .bin, domyslnie comp+uncomp) / EN: wallets mode (.bin DB, default comp+uncomp)
python3 pool_server.py init --mode wallets \
  --db adresy_unique.bin --start-bit 253 --end-bit 256



---

## 🧩 Jak to działa / How it works

1. **PL:** Operator losuje sekret `s` 
   **EN:** The operator draws a secret `s` 
2. **PL:** Worker skanuje przydzielony zakres hash160 z celem. **EN:** The worker scans its assigned range
   and comparing hash160 against the target.
3. **PL:** Trafienie → worker zna tylko `d` (pół-klucz), wysyła go na serwer.
   **EN:** On a hit → the worker knows only `d` (half-key) and sends it to the server.
4. **PL:** Serwer składa pełny klucz i weryfikuje adres.
   **EN:** The server assembles the full key and verifies the address.

---

## 📂 Pliki / Files

| Plik / File | Opis (PL) | Description (EN) |
| :--- | :--- | :--- |
| `fastscan` (Linux) | Uniwersalna binarka GPU na Linux (wszystkie karty) | Universal GPU binary for Linux (all cards) |
| `fastscan.exe` (Windows) | Binarka GPU dla nowszych kart (RTX 20xx, 30xx, 40xx, 50xx+) | GPU binary for newer cards (RTX 20xx, 30xx, 40xx, 50xx+) |
| `fastscan_legacy.exe` (Windows) | Binarka GPU dla starszych kart (GTX 9xx, GTX 10xx) | GPU binary for older cards (GTX 9xx, GTX 10xx) |
| `libcrypto-3-x64.dll` (Windows) | Biblioteka OpenSSL (kryptografia) | OpenSSL library (cryptography) |
| `libssl-3-x64.dll` (Windows) | Biblioteka OpenSSL (TLS/SSL) | OpenSSL library (TLS/SSL) |
| `libsecp256k1.dll` (Windows) | Biblioteka krzywej eliptycznej Bitcoin | Bitcoin elliptic curve library |
| `mman.dll` (Windows) | Implementacja mmap dla Windows | mmap implementation for Windows |
| `gtableX.bin` | Tablice matematyczne (punkt G) – wymagane | Mathematical tables (point G) – required |
| `gtableY.bin` | Tablice matematyczne (punkt G) – wymagane | Mathematical tables (point G) – required |
| `gtable_compX.bin` | Tablice dla skompresowanych adresów | Tables for compressed addresses |
| `gtable_compY.bin` | Tablice dla skompresowanych adresów | Tables for compressed addresses |
| `pool_worker.py` | Python koordynator (łączy z serwerem) | Python coordinator (connects to server) |

---
## 📈 Prawdopodobieństwo znalezienia klucza / Probability of finding the key

**PL:** System oparty na **podziale zakresu na rozłączne chunki** daje unikalną wśród architektur GPU cechę – **prawdopodobieństwo znalezienia klucza rośnie w czasie**.

Im więcej kluczy przeszukanych, tym mniejszy pozostaje nieprzeszukany obszar, a szansa na trafienie w kolejnej sekundzie jest coraz większa.

### 📐 Wzór matematyczny

Prawdopodobieństwo, że klucz znajduje się w już przeszukanym obszarze:
P(t) = (N_przeszukane(t) / N_całkowity) * 100%

gdzie:
- `P(t)` – prawdopodobieństwo znalezienia klucza do chwili `t`,
- `N_przeszukane(t)` – liczba kluczy przeszukanych do chwili `t`,
- `N_całkowity` – całkowita liczba kluczy w zadanym zakresie.

**Każda sekunda zwiększa całkowite prawdopodobieństwo** aż do osiągnięcia 100%.

### 📊 Przykład (zakres 71-bit)

Zakres 71-bitowy to `N_całkowity ≈ 2.36 × 10²¹` kluczy.

| Przeszukane klucze | Przeszukany obszar | Prawdopodobieństwo znalezienia |
|-------------------|-------------------|-------------------------------|
| `2.36 × 10²⁰` | 10% | 10% |
| `1.18 × 10²¹` | 50% | 50% |
| `2.12 × 10²¹` | 90% | 90% |
| `2.36 × 10²¹` | 100% | **100%**|

### 🏆 Co to oznacza w praktyce?

- **100% gwarancja** – jeśli klucz istnieje w zadanym zakresie, zostanie znaleziony.
- **Zero nakładek** – żaden klucz nie jest sprawdzany dwukrotnie.
- **Mierzalny postęp** – w każdej chwili wiadomo, ile zostało do przeszukania.
- **Rosnące szanse** – prawdopodobieństwo rośnie z każdą minutą, aż do 100%.

**To jedyna architektura GPU, która daje matematyczną gwarancję znalezienia klucza.**

---

**EN:** A system based on **dividing the range into disjoint chunks** offers a unique feature among GPU architectures – **the probability of finding the key increases over time**.

The more keys searched, the smaller the remaining unsearched area, and the higher the chance of a hit in the next second.

### 📐 Mathematical formula

The probability that the key is in the already searched area:
P(t) = (N_searched(t) / N_total) * 100%

Where:
- `P(t)` – probability of finding the key by time `t`,
- `N_searched(t)` – number of keys searched up to time `t`,
- `N_total` – total number of keys in the given range.

**Every second increases the total probability** until it reaches 100%.

### 📊 Example (71-bit range)

A 71-bit range is `N_total ≈ 2.36 × 10²¹` keys.

| Keys searched | Area searched | Probability of finding |
|---------------|---------------|------------------------|
| `2.36 × 10²⁰` | 10% | 10% |
| `1.18 × 10²¹` | 50% | 50% |
| `2.12 × 10²¹` | 90% | 90% |
| `2.36 × 10²¹` | 100% | **100%**|

### 🏆 What this means in practice:

- **100% guarantee** – if the key exists in the given range, it will be found.
- **Zero overlap** – no key is ever checked twice.
- **Measurable progress** – you always know how much is left.
- **Increasing odds** – the probability grows every minute until it reaches 100%.

**This is the only GPU architecture that gives a mathematical guarantee of finding the key.**



## 🔒 Bezpieczeństwo / Security

- **PL:** Sekret `s` trzymaj offline (bez niego nie złożysz klucza). Ruch idzie przez
  HTTPS. Split-key chroni przed „ucieczką z nagrodą” tylko w modelu zaufania (patrz nota wyżej).
- **EN:** Keep the secret `s` offline (without it you cannot assemble the key). Traffic
  goes over HTTPS. Split-key protects against "running off with the reward" only in the
  trust model (see the note above).

---
## 🖥️ Wspierane karty GPU / Supported GPUs

**PL:** Projekt oferuje **dwie wersje binarne** na Windows oraz **jedną uniwersalną binarkę** na Linux.

**EN:** The project offers **two binary versions** on Windows and **one universal binary** on Linux.

---

### 🪟 Windows

| Wersja | Opis |
| :--- | :--- |
| **`fastscan_legacy.exe`** | Dla starszych kart (GTX 9xx, GTX 10xx) – CUDA 12.3 |
| **`fastscan.exe`** | Dla nowszych kart (RTX 20xx, 30xx, 40xx, 50xx+) – CUDA 13.3 |

---

#### 🏛️ `fastscan_legacy.exe` – starsze karty (CUDA 12.3)

| Architektura | Karty GPU | Compute Capability |
| :--- | :--- | :--- |
| **Maxwell** | GTX 9xx (np. GTX 960, 970, 980, 980 Ti) | 5.0 / 5.2 |
| **Pascal** | GTX 10xx (np. GTX 1050, 1060, 1070, 1080, 1080 Ti) | 6.0 / 6.1 |
| **Turing** | GTX 16xx (np. 1650, 1660) / RTX 20xx (np. 2060, 2070, 2080, 2080 Ti) | 7.5 |

---

#### ⚡ `fastscan.exe` – nowsze karty (CUDA 13.3)

| Architektura | Karty GPU | Compute Capability |
| :--- | :--- | :--- |
| **Turing** | GTX 16xx (np. 1650, 1660) / RTX 20xx (np. 2060, 2070, 2080, 2080 Ti) | 7.5 |
| **Ampere** | RTX 30xx (np. 3060, 3070, 3080, 3090, 3090 Ti) | 8.0 / 8.6 |
| **Ada** | RTX 40xx (np. 4060, 4070, 4080, 4090) | 8.9 |
| **Blackwell (przyszłe)** | RTX 50xx i nowsze – działają przez **PTX/JIT** | 9.0+ (automatyczne) |

---

### 🐧 Linux

**PL:** Na Linux dostępna jest **jedna uniwersalna binarka** `./fastscan` skompilowana jako **Fat Binary**, która obsługuje wszystkie karty od GTX 9xx do RTX 50xx.

**EN:** On Linux there is **one universal binary** `./fastscan` compiled as a **Fat Binary**, supporting all cards from GTX 9xx to RTX 50xx.

| Architektura | Karty GPU | Compute Capability |
| :--- | :--- | :--- |
| **Maxwell** | GTX 9xx (np. GTX 960, 970, 980, 980 Ti) | 5.2 |
| **Pascal** | GTX 10xx (np. GTX 1050, 1060, 1070, 1080, 1080 Ti) | 6.1 |
| **Turing** | GTX 16xx (np. 1650, 1660) / RTX 20xx (np. 2060, 2070, 2080, 2080 Ti) | 7.5 |
| **Ampere** | RTX 30xx (np. 3060, 3070, 3080, 3090, 3090 Ti) | 8.6 |
| **Ada** | RTX 40xx (np. 4060, 4070, 4080, 4090) | 8.9 |
| **Blackwell (przyszłe)** | RTX 50xx i nowsze – działają przez **PTX/JIT** | 9.0+ (automatyczne) |

---

### 🎯 Której binarki użyć? / Which binary to use?

| Twoja karta GPU / Your GPU | Windows | Linux |
| :--- | :--- | :--- |
| **GTX 750, GTX 9xx** | `fastscan_legacy.exe` | `./fastscan` |
| **GTX 10xx (Pascal)** | `fastscan_legacy.exe` | `./fastscan` |
| **GTX 16xx / RTX 20xx (Turing)** | Działa na **obu** wersjach | `./fastscan` |
| **RTX 30xx (Ampere)** | `fastscan.exe` | `./fastscan` |
| **RTX 40xx (Ada)** | `fastscan.exe` | `./fastscan` |
| **RTX 50xx (Blackwell) i nowsze** | `fastscan.exe` | `./fastscan` |

---

### 🔧 Jak sprawdzić swoją kartę? / How to check your card?

**Windows:**
- Menedżer zadań → zakładka "Wydajność" → GPU
- Lub w CMD: `nvidia-smi`

**Linux:**
```bash
nvidia-smi
lspci | grep -i nvidia---

*PL: Projekt edukacyjny/hobbystyczny. Szukanie kluczy do puzzli Bitcoina jest legalne;*
*szukanie cudzych portfeli w użyciu — nie. Używaj odpowiedzialnie.*
*EN: Educational/hobby project. Searching Bitcoin puzzle keys is legal; searching for*
*other people's in-use wallets is not. Use responsibly.*
