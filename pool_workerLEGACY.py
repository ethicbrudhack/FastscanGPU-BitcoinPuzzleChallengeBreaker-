#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
# pool_worker.py - klient/worker poola / pool worker client
# ------------------------------------------------------------
# [PL] Petla: pobierz config -> pobierz segment -> uruchom binarke GPU
#      (split-key + pool) -> odczytaj SHARE z found.txt -> zglos /done (+/found).
# [EN] Loop: get config -> get segment -> run GPU binary (split-key + pool)
#      -> read SHARE from found.txt -> report /done (+/found).
#
# [PL] ODPORNOSC NA AWARIE SIECI (wazne przy TRAFIENIU):
#      Kazdy znaleziony share zapisujemy NATYCHMIAST do trwalego pliku
#      (pending_shares.jsonl) ZANIM wyslemy na serwer. Share znika z pliku
#      dopiero po potwierdzeniu serwera. Dzieki temu share NIE przepadnie
#      nawet przy padzie sieci/pradu/restartu - przy kolejnej okazji worker
#      dosle zalegle share'y (flush). Wysylka /found i /done ma retry z
#      rosnacym opoznieniem.
# [EN] NETWORK-FAILURE RESILIENCE (critical on a HIT):
#      Every found share is written to a durable file (pending_shares.jsonl)
#      BEFORE we send it to the server. A share is removed only after the
#      server confirms it. So a share is NEVER lost on network/power/restart
#      failure - the worker re-sends pending shares later (flush). /found and
#      /done use retry with increasing backoff.
#
# [PL] Czysta biblioteka standardowa Pythona - ZERO zaleznosci pip.
# [EN] Pure Python standard library - ZERO pip dependencies.
# ============================================================
import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error

# [PL] KEYS_PER_CHUNK jest teraz obliczany dynamicznie na podstawie rundy
# [EN] KEYS_PER_CHUNK is now computed dynamically based on the round
#      total_range = 2^end_bit - 2^start_bit
#      chunks_in_round = 3563 * 2^(round-1)
#      keys_per_chunk = total_range // chunks_in_round
# [PL] Stara stala (bledna) / [EN] Old constant (wrong): KEYS_PER_CHUNK = 5_000_000

# [PL] Parametry ponawiania / [EN] Retry parameters
HTTP_TIMEOUT   = 30          # [PL] timeout pojedynczej proby / [EN] single attempt timeout
DONE_RETRIES   = 5           # [PL] proby dla /done (wklad) / [EN] attempts for /done (contribution)
FOUND_RETRIES  = 12          # [PL] proby dla /found (WAZNE - trafienie!) / [EN] attempts for /found (HIT!)
BACKOFF_BASE   = 3           # [PL] sekundy, rosnie: 3,6,9... (max 60) / [EN] seconds, grows: 3,6,9... (cap 60)
BACKOFF_MAX    = 60
# [PL] Cache na DNS i konfiguracje / [EN] DNS & config cache
DNS_CACHE_TTL  = 300         # [PL] 5 min cache DNS / [EN] 5 min DNS cache
_last_dns = {}               # {host: (ip, ts)}
_cached_config = {}          # konfiguracja z serwera / server config


def _resolve_cached(host):
    """[PL] Rozwiazuje DNS z cache (5 min TTL), zeby uniknac bledow getaddrinfo.
    [EN] Resolves DNS with cache (5 min TTL) to avoid getaddrinfo errors."""
    now = time.time()
    if host in _last_dns:
        ip, ts = _last_dns[host]
        if now - ts < DNS_CACHE_TTL:
            return ip
    for attempt in range(3):
        try:
            ip = socket.gethostbyname(host)
            _last_dns[host] = (ip, now)
            return ip
        except socket.gaierror:
            if attempt < 2:
                time.sleep(1)
                continue
            if host in _last_dns:
                print(f"[PL] DNS nieudany po 3 probach, uzywam cache. [EN] DNS failed after 3 attempts, using cache.")
                return _last_dns[host][0]
            raise


def http_get(url):
    """[PL] GET z retry na bledy DNS/SSL/sieci. NIGDY nie crashuje - czeka i probuje dalej.
    [EN] GET with retry on DNS/SSL/network errors. NEVER crashes - waits and keeps retrying."""
    MAX_CONSECUTIVE = 5          # [PL] po ilu bledach czekamy 60s / [EN] after how many fails we wait 60s
    LONG_WAIT = 60               # [PL] dlugie czekanie po serii bledow / [EN] long wait after a streak of fails
    consecutive = 0
    while True:
        try:
            with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            body = e.read().decode() if e.fp else ""
            try:
                body = json.loads(body).get("error", body)
            except Exception:
                pass
            consecutive += 1
            print(f"[PL] HTTP {e.code}: {body}. "
                  f"(bladow pod rzad: {consecutive})")
            print(f"[EN] HTTP {e.code}: {body}. "
                  f"(consecutive fails: {consecutive})")
            if e.code in (429, 502, 503, 504):
                # [PL] Serwer mowi "wolniej" - czekaj dluzej.
                # [EN] Server says "slow down" - wait longer.
                wait = min(BACKOFF_BASE * (2 ** min(consecutive, 8)), BACKOFF_MAX)
            else:
                raise Exception(f"HTTP {e.code}: {body}") from None
        except (urllib.error.URLError, OSError, socket.gaierror,
                ConnectionRefusedError, TimeoutError) as e:
            consecutive += 1
            # [PL] Exponential backoff: 3, 6, 12, 24, 48, potem 60s co probe
            # [EN] Exponential backoff: 3, 6, 12, 24, 48, then 60s per attempt
            if consecutive <= MAX_CONSECUTIVE:
                wait = min(BACKOFF_BASE * (2 ** (consecutive - 1)), BACKOFF_MAX)
            else:
                wait = LONG_WAIT
                print(f"[PL] OSTRZEZENIE: {consecutive} bledow sieci pod rzad. "
                      f"Czekam {wait}s przed kolejna proba...")
                print(f"[EN] WARNING: {consecutive} consecutive network errors. "
                      f"Waiting {wait}s before next attempt...")
            print(f"[PL] Blad sieci GET (bladow pod rzad: {consecutive}): {e}. "
                  f"Ponawiam za {wait}s...")
            print(f"[EN] Network error GET (consecutive fails: {consecutive}): {e}. "
                  f"Retrying in {wait}s...")
            time.sleep(wait)


def http_post(url, obj):
    data = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
        return json.loads(r.read().decode())


def http_post_retry(url, obj, retries, label=""):
    # [PL] POST z ponawianiem. Zwraca odpowiedz (dict) albo None po wyczerpaniu prob.
    # [EN] POST with retry. Returns response (dict) or None after all attempts fail.
    for attempt in range(1, retries + 1):
        try:
            return http_post(url, obj)
        except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError,
                socket.gaierror, ConnectionRefusedError, TimeoutError) as e:
            # [PL] Exponential backoff: 3, 6, 12, 24... capped at BACKOFF_MAX
            # [EN] Exponential backoff: 3, 6, 12, 24... capped at BACKOFF_MAX
            wait = min(BACKOFF_BASE * (2 ** (attempt - 1)), BACKOFF_MAX)
            print(f"[PL] Blad wysylki {label} (proba {attempt}/{retries}): {e}. "
                  f"Ponawiam za {wait}s...")
            print(f"[EN] Send error {label} (attempt {attempt}/{retries}): {e}. "
                  f"Retrying in {wait}s...")
            if attempt < retries:
                time.sleep(wait)
    print(f"[PL] Nie udalo sie wyslac {label} po {retries} probach.  "
          f"[EN] Failed to send {label} after {retries} attempts.")
    return None


# ============================================================
# [PL] Trwaly bufor share'ow (przetrwa restart/crash) / [EN] Durable share buffer
# ============================================================
def _load_pending(path):
    # [PL] wczytaj zalegle share'y z pliku jsonl / [EN] load pending shares from jsonl
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def _save_pending(path, items):
    # [PL] zapisz cala liste (atomowo przez plik tymczasowy) / [EN] atomic full rewrite
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for it in items:
            f.write(json.dumps(it) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _append_pending(path, item):
    # [PL] dopisz JEDEN share natychmiast (fsync!) - to jest kluczowe przy trafieniu
    # [EN] append ONE share immediately (fsync!) - critical on a hit
    with open(path, "a") as f:
        f.write(json.dumps(item) + "\n")
        f.flush()
        os.fsync(f.fileno())


def flush_pending(base, worker, pending_path):
    # [PL] Sprobuj doslac WSZYSTKIE zalegle share'y. Te potwierdzone usuwamy z pliku.
    # [EN] Try to resend ALL pending shares. Confirmed ones are removed from file.
    pending = _load_pending(pending_path)
    if not pending:
        return
    print(f"[PL] Zalegle share'y do doslania: {len(pending)}  "
          f"[EN] Pending shares to resend: {len(pending)}")
    still = []
    for item in pending:
        resp = http_post_retry(f"{base}/found",
                               {"worker": worker, "share_d": item["share_d"],
                                "segment_id": item.get("segment_id")},
                               FOUND_RETRIES, label="/found (zalegly/pending)")
        if resp is None:
            still.append(item)  # [PL] nadal nie wyszlo -> zostaje / [EN] still failed -> keep
        else:
            print(f"[PL] Doslano zalegly SHARE: {item['share_d'][:16]}...  match={resp.get('match')}")
            print(f"[EN] Resent pending SHARE: {item['share_d'][:16]}...  match={resp.get('match')}")
    _save_pending(pending_path, still)


def parse_shares(found_path):
    # [PL] zwraca liste share'ow d z found.txt / [EN] returns list of shares d
    if not os.path.exists(found_path):
        return []
    shares = []
    with open(found_path) as f:
        for line in f:
            m = re.match(r"^(?:SHARE|KEY):\s*([0-9a-fA-F]+)", line.strip())
            if m:
                shares.append(m.group(1))
    return shares


def run_worker(args):
    base = args.server.rstrip("/")
    worker = args.worker

    print(f"[PL] Worker '{worker}' laczy sie z {base}")
    print(f"[EN] Worker '{worker}' connecting to {base}")

    # [PL] Trwaly plik z zaleglymi share'ami (per worker, by sie nie mieszaly).
    # [EN] Durable pending-shares file (per worker to avoid mixing).
    pending_path = args.pending or f"pending_shares_{worker}.jsonl"

    # [PL] Autoryzacja przez login/haslo (opcjonalna).
    # [EN] Password-based auth (optional).
    worker_token = None
    if args.password:
        resp = http_post_retry(f"{base}/login",
                               {"nick": worker, "pass": args.password},
                               3, label="/login (auth)")
        if resp and resp.get("ok"):
            worker_token = resp["token"]
            print(f"[PL] Autoryzacja OK (token: {worker_token[:8]}...)")
            print(f"[EN] Auth OK (token: {worker_token[:8]}...)")
        else:
            err = resp.get("error") if resp else "no response"
            print(f"[PL] Autoryzacja NIEUDANA: {err}. Worker uzyje nicka bez weryfikacji.")
            print(f"[EN] Auth FAILED: {err}. Worker will use unverified nick.")

    # [PL] Na starcie: sprobuj doslac cokolwiek zostalo z poprzedniej sesji.
    # [EN] On startup: try to resend anything left from a previous session.
    flush_pending(base, worker, pending_path)

    cfg = http_get(f"{base}/config")
    # [PL] mode: puzzle (jeden adres) lub wallets (baza .bin). Starsze serwery
    #      nie zwracaja tych pol -> bezpieczne wartosci domyslne (tryb puzzle).
    # [EN] mode: puzzle (single addr) or wallets (.bin DB). Older servers don't
    #      return these fields -> safe defaults (puzzle mode).
    mode = cfg.get("mode", "puzzle")
    scan_target = cfg.get("scan_target") or cfg.get("puzzle_addr")
    scan_mode = cfg.get("scan_mode", "comp")
    addr = cfg.get("puzzle_addr")
    sb, eb = cfg["start_bit"], cfg["end_bit"]
    sx, sy = cfg["offset_sx"], cfg["offset_sy"]
    # [PL] Przesuniety zakres (split-key fix): worker skanuje [shifted_lo, shifted_hi]
    # [EN] Shifted range (split-key fix): worker scans [shifted_lo, shifted_hi]
    shifted_lo = cfg.get("shifted_lo")
    shifted_hi = cfg.get("shifted_hi")
    # [PL] Cache konfiguracji - worker nie bedzie pobierac jej co runde
    # [EN] Config cache - worker won't re-fetch it every round
    _cached_config.update(cfg)
    last_config_ts = time.time()
    CONFIG_REFRESH = 300  # [PL] Odswiez konfig co 5 min / [EN] Refresh config every 5 min

    # [PL] W trybie wallets argv[1] to lokalny plik .bin. Kopacz moze miec inna
    #      sciezke niz nazwa z serwera -> pozwalamy nadpisac przez --db.
    # [EN] In wallets mode argv[1] is a local .bin file. The miner may store it at
    #      a different path than the server's name -> allow override via --db.
    if mode == "wallets":
        local_db = args.db or scan_target
        if not os.path.exists(local_db):
            print(f"[PL] Brak pliku bazy adresow: {local_db}")
            print(f"[EN] Address database file not found: {local_db}")
            print("[PL] Pobierz baze .bin i wskaz ja przez --db <sciezka>.")
            print("[EN] Download the .bin database and point to it with --db <path>.")
            sys.exit(1)
        arg1 = local_db
        print(f"[PL/EN] mode=wallets db={arg1} scan_mode={scan_mode} bits={sb}..{eb}")
    else:
        arg1 = scan_target
        print(f"[PL/EN] mode=puzzle puzzle={addr} scan_mode={scan_mode} bits={sb}..{eb}")

    gpu_proc = None  # [PL] GPU proces persistent / [EN] persistent GPU process (uruchamiany RAZ)

    while True:
        work_url = f"{base}/work?worker={worker}"
        if worker_token:
            work_url += f"&token={worker_token}"
        # [PL] Sprawdz czy ban / [EN] Check if banned
        seg = None
        try:
            seg = http_get(work_url)
        except Exception as e:
            print(f"[PL] Blad pobierania pracy: {e} / [EN] Error getting work: {e}")
            print("[PL] Ponawiam za 10s... / [EN] Retrying in 10s...")
            time.sleep(10)
            continue

        # [PL] Sprawdz czy serwer zwrocil bana
        # [EN] Check if server returned a ban
        if seg.get("banned"):
            print(f"[PL] ZBANOWANY przez serwer! / [EN] BANNED by server!")
            print(f"  {seg.get('error', 'No reason')}")
            print("[PL] Worker zatrzymany. / [EN] Worker stopped.")
            break

        # [PL] Co 5 min odswiez konfiguracje (np. po restarcie serwera, zmianie sekretu)
        # [EN] Every 5 min refresh config (e.g. after server restart, secret change)
        if time.time() - last_config_ts > CONFIG_REFRESH:
            try:
                cfg = http_get(f"{base}/config")
                sb, eb = cfg["start_bit"], cfg["end_bit"]
                sx, sy = cfg["offset_sx"], cfg["offset_sy"]
                mode = cfg.get("mode", "puzzle")
                scan_target = cfg.get("scan_target") or cfg.get("puzzle_addr")
                shifted_lo = cfg.get("shifted_lo")
                shifted_hi = cfg.get("shifted_hi")
                _cached_config.update(cfg)
                last_config_ts = time.time()
                print("[PL] Konfiguracja odswiezona. / [EN] Config refreshed.")
            except Exception as e:
                print(f"[PL] Nie udalo sie odswiezyc konfiguracji: {e} / [EN] Config refresh failed: {e}")

        rnd, cf, ct = seg["round"], seg["chunk_from"], seg["chunk_to"]
        sid = seg["segment_id"]
        print(f"\n[PL] Segment #{sid}: runda {rnd}, chunki [{cf},{ct})")
        print(f"[EN] Segment #{sid}: round {rnd}, chunks [{cf},{ct})")

        # wyczysc found.txt przed skanem / clear found.txt before scan
        open(args.found, "w").close()

        # --- [PL] TRYB PERSISTENT GPU: binarka uruchamiana RAZ, nie restartowana co segment ---
        # [EN] PERSISTENT GPU MODE: binary launched ONCE, not restarted per segment ---
        if gpu_proc is None:
            # Pierwszy segment: uruchom binarke z --pool-persistent
            cmd = [
                args.binary, arg1,
                "--range-lo", shifted_lo, "--range-hi", shifted_hi,
                f"--mode={scan_mode}",
                f"--splitkey-sx={sx}", f"--splitkey-sy={sy}",
                "--pool-persistent",
                f"--pool-round={rnd}", f"--pool-from={cf}", f"--pool-to={ct}",
            ]
            cmd_display = [
                args.binary, arg1,
                "--range-lo", shifted_lo[:16]+"...", "--range-hi", shifted_hi[:16]+"...",
                f"--mode={scan_mode}",
                "--splitkey-sx=---", "--splitkey-sy=---",
                "--pool-persistent",
                f"--pool-round={rnd}", f"--pool-from={cf}", f"--pool-to={ct}",
            ]
            print("[PL/EN] cmd (PERSISTENT START):", " ".join(cmd_display))
            try:
                gpu_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, encoding='utf-8', errors='replace')
            except FileNotFoundError:
                print(f"[PL] Brak binarki: {args.binary}  [EN] Binary not found: {args.binary}")
                sys.exit(1)
            t0 = time.time()
        else:
            # Kolejny segment: zapisz nowe zadanie do pool_next.txt
            with open("pool_next.txt", "w") as pnf:
                pnf.write(f"{rnd} {cf} {ct}\n")
            print("[PL/EN] (PERSISTENT) Nowe zadanie zapisane do pool_next.txt")
            cmd_display = [
                "(kontynuacja)", arg1,
                "--range-lo", shifted_lo[:16]+"...", "--range-hi", shifted_hi[:16]+"...",
                f"--pool-round={rnd}", f"--pool-from={cf}", f"--pool-to={ct}",
            ]
            print("[PL/EN] cmd:", " ".join(cmd_display))
            t0 = time.time()

        # Monitoruj stdout binarki: czekaj na zakonczenie segmentu
        segment_done = False
        while not segment_done:
            line = gpu_proc.stdout.readline()
            if not line:
                # Proces sie zakonczyl (awaria)
                rc = gpu_proc.poll()
                print(f"[PL] GPU proces zakonczyl sie (rc={rc}) - restart! / [EN] GPU process ended (rc={rc}) - restarting!")
                gpu_proc = None
                break
            print(line.rstrip())
            # Wykryj zakonczenie segmentu w trybie persistent
            if "[POOL-PERSISTENT]" in line and "przetworzone" in line:
                # Czekaj az binarka zacznie czekac na pool_next.txt
                time.sleep(0.5)
                segment_done = True
            elif "[POOL]" in line and "Koniec zadania" in line:
                # Pierwszy segment w persistent tez wysyla ta linijke
                time.sleep(0.5)
                segment_done = True

        if gpu_proc is None:
            # GPU padlo - sprobuj od nowa w nastepnej iteracji
            continue

        dt = time.time() - t0

        # --- NAJPIERW: zabezpiecz znaleziska (share'y) na dysk ---
        # [PL] KRYTYCZNE: zanim cokolwiek wyslemy, kazdy znaleziony share
        #      dopisujemy do trwalego pliku (fsync). Jesli teraz padnie siec
        #      albo prad - share PRZETRWA i doslemy go pozniej (flush).
        # [EN] CRITICAL: before sending anything, append each found share to a
        #      durable file (fsync). If the network or power dies now, the share
        #      SURVIVES and we resend it later (flush).
        shares = parse_shares(args.found)
        for d in shares:
            _append_pending(pending_path, {"share_d": d, "ts": time.time(), "segment_id": sid})
            print(f"[PL] Znaleziono SHARE - zapisano lokalnie (trwale): {d[:16]}...")
            print(f"[EN] SHARE found - saved locally (durable): {d[:16]}...")

        # --- /done : zglos wklad (z ponawianiem) ---
        # [PL] kazdy chunk to ~5M kluczy (effBlockSize GPU) / each chunk ~5M keys
        KEYS_PER_CHUNK = 5_000_000
        keys_done = (ct - cf) * KEYS_PER_CHUNK
        resp_done = http_post_retry(f"{base}/done",
                                    {"segment_id": sid, "worker": worker, "keys_done": keys_done},
                                    DONE_RETRIES, label="/done")
        if resp_done is not None:
            print(f"[PL] Segment gotowy w {dt:.1f}s, zgloszono wklad.")
            print(f"[EN] Segment done in {dt:.1f}s, contribution reported.")
        else:
            print(f"[PL] Segment gotowy w {dt:.1f}s, ale /done nie doszlo (sprobuje przy nastepnym).")
            print(f"[EN] Segment done in {dt:.1f}s, but /done failed (will retry next round).")

        # --- /found : wyslij zalegle + biezace share'y (z ponawianiem) ---
        # [PL] flush_pending obejmuje TE dopisane wyzej + wszelkie starsze.
        #      Potwierdzone znikaja z pliku, niepotwierdzone zostaja na pozniej.
        # [EN] flush_pending covers the ones appended above + any older ones.
        #      Confirmed are removed from file; unconfirmed stay for later.
        if shares:
            flush_pending(base, worker, pending_path)

        if args.once:
            print("[PL] Tryb --once: koniec.  [EN] --once mode: done.")
            break


def main():
    ap = argparse.ArgumentParser(description="Pool worker / worker poola (split-key)")
    ap.add_argument("--server", required=True, help="http://host:port")
    ap.add_argument("--worker", default="anon", help="[PL] nazwa/id workera / [EN] worker name/id")
    ap.add_argument("--binary", default="./fastscan_test", help="[PL] sciezka do binarki GPU / [EN] GPU binary path")
    ap.add_argument("--password", default=None,
                    help="[PL] haslo do logowania (opcjonalne; jesli podane, worker autoryzuje sie przez /login) / "
                         "[EN] login password (optional; if set, worker authenticates via /login)")
    ap.add_argument("--db", default=None,
                    help="[PL] lokalna sciezka do bazy .bin (tryb wallets; nadpisuje nazwe z serwera) / "
                         "[EN] local .bin DB path (wallets mode; overrides server name)")
    ap.add_argument("--found", default="found.txt", help="[PL] plik wynikowy / [EN] output file")
    ap.add_argument("--pending", default=None,
                    help="[PL] trwaly plik z zaleglymi share'ami (domyslnie pending_shares_<worker>.jsonl) / "
                         "[EN] durable pending-shares file (default pending_shares_<worker>.jsonl)")
    ap.add_argument("--once", action="store_true", help="[PL] jeden segment i koniec / [EN] one segment then stop")
    args = ap.parse_args()
    run_worker(args)


if __name__ == "__main__":
    main()