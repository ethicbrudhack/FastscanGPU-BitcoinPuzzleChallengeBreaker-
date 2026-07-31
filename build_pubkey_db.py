#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
# build_pubkey_db.py - budowa bazy .bin dla fastscan_253_256
# ------------------------------------------------------------
# [PL] Wczytuje plik(i) tekstowe z kluczami publicznymi (hex, jeden na
#      linie, 130 znakow, zaczynajace sie od "04" - nieskompresowane
#      klucze publiczne 04||X(32B)||Y(32B)), usuwa duplikaty, SORTUJE
#      po X (wymagane przez binary search w kernelu GPU) i zapisuje
#      jako 65-bajtowe rekordy binarne.
# [EN] Reads text file(s) with hex uncompressed pubkeys (one per line,
#      130 hex chars, starting with "04"), deduplicates, SORTS by X
#      (required by the GPU kernel's binary search) and writes 65-byte
#      binary records.
#
# Uzycie / Usage:
#   python3 build_pubkey_db.py uncompressed_pubkeys.txt -o pubkeys.bin
#   python3 build_pubkey_db.py plik1.txt plik2.txt plik3.txt -o pubkeys.bin
#
# Mozna podac WIELE plikow txt naraz (np. kolejne partie pobierania) -
# skrypt scali je, usunie duplikaty i posortuje od nowa. Mozesz to
# uruchamiac wielokrotnie w miare pobierania kolejnych partii pubkeyow.
# ============================================================
import argparse
import sys
import os


def load_pubkeys_from_file(path):
    """[PL] Wczytuje pubkeye hex z pliku tekstowego, po jednym na linie.
       [EN] Reads hex pubkeys from a text file, one per line."""
    out = []
    bad = 0
    with open(path, "r") as f:
        for lineno, line in enumerate(f, 1):
            h = line.strip()
            if not h:
                continue
            if len(h) != 130:
                bad += 1
                continue
            if not h.lower().startswith("04"):
                bad += 1
                continue
            try:
                b = bytes.fromhex(h)
            except ValueError:
                bad += 1
                continue
            if len(b) != 65:
                bad += 1
                continue
            out.append(b)
    if bad:
        print(f"[PL] UWAGA: {path}: {bad} linii pominieto (zly format/dlugosc).")
        print(f"[EN] WARNING: {path}: {bad} lines skipped (bad format/length).")
    return out


def main():
    ap = argparse.ArgumentParser(
        description="[PL] Budowa bazy .bin (65B pubkey) dla fastscan_253_256 / "
                     "[EN] Build .bin pubkey DB (65B records) for fastscan_253_256")
    ap.add_argument("inputs", nargs="+", help="[PL] plik(i) txt z pubkeyami hex / [EN] input txt file(s)")
    ap.add_argument("-o", "--output", default="pubkeys.bin",
                     help="[PL] plik wynikowy .bin (domyslnie pubkeys.bin) / "
                          "[EN] output .bin file (default pubkeys.bin)")
    args = ap.parse_args()

    all_records = []
    for path in args.inputs:
        if not os.path.exists(path):
            print(f"[PL] BLAD: plik nie istnieje: {path}")
            print(f"[EN] ERROR: file not found: {path}")
            sys.exit(1)
        recs = load_pubkeys_from_file(path)
        print(f"[PL] {path}: wczytano {len(recs)} pubkeyow.")
        print(f"[EN] {path}: loaded {len(recs)} pubkeys.")
        all_records.extend(recs)

    before = len(all_records)
    # [PL] Usun duplikaty (ten sam pubkey moze wystapic w kilku partiach
    #      pobierania) - zamieniamy na set() po bytes, potem z powrotem na liste.
    # [EN] Remove duplicates (the same pubkey may appear across several
    #      download batches) - convert to a set of bytes, then back to a list.
    unique = list(set(all_records))
    after = len(unique)
    dupes = before - after
    if dupes:
        print(f"[PL] Usunieto {dupes} duplikatow ({before} -> {after}).")
        print(f"[EN] Removed {dupes} duplicates ({before} -> {after}).")

    # [PL] SORTOWANIE PO X (bajty [1:33] rekordu) - WYMAGANE przez binary
    #      search + indeks prefiksowy w kernelu GPU (main_253_256.cu).
    #      Bez sortowania skaner NIE znajdzie zadnego trafienia!
    # [EN] SORT BY X (record bytes [1:33]) - REQUIRED by the binary search
    #      + prefix index in the GPU kernel (main_253_256.cu). Without
    #      sorting the scanner will find NOTHING!
    unique.sort(key=lambda r: r[1:33])

    with open(args.output, "wb") as f:
        for r in unique:
            f.write(r)

    size_mb = (after * 65) / (1024 * 1024)
    print("=" * 60)
    print(f"[PL] Zapisano: {args.output}")
    print(f"[EN] Written:  {args.output}")
    print(f"[PL] Rekordow: {after} pubkeyow ({size_mb:.2f} MB)")
    print(f"[EN] Records:  {after} pubkeys ({size_mb:.2f} MB)")
    print("=" * 60)
    print("[PL] Uzycie z fastscan_253_256:")
    print(f"[EN] Use with fastscan_253_256:")
    print(f"   ./fastscan_253_256 {args.output} 253 256")


if __name__ == "__main__":
    main()
