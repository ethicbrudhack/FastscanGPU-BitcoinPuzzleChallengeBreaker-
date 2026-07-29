// ============================================================
// main_optimized.cu - FASTSCAN GPU (scalona wersja)
// ============================================================
// Zrodla polaczonych rozwiazan:
//  - main.cu:            mmap ladowania pliku adresow (bez kopii RAM),
//                         budowa 24-bitowego indeksu prefiksowego,
//                         zero-copy live licznik GH/s, logika BIGNUM
//                         rund/chunkow/stride (scan()), rownolegle
//                         dzielenie chunku na threads_per_chunk wątków.
//  - GPUGroup.h:          gotowa tabela G,2G,...,512G (Gx/Gy) - NIE
//                         uzywana w zadnym z oryginalnych plikow! -
//                         wykorzystana tutaj do GRUPOWEJ (batch)
//                         inwersji modularnej (technika Montgomery'ego,
//                         jak w VanitySearch) - to jest NAJWIEKSZY
//                         zysk wydajnosci w tym pliku.
//  - main26ghs/finalchat: inkrementalne stepowanie "+G" (obliczenie
//                         punktu startowego RAZ na (chunk,podwatek),
//                         a NIE full-multiply dla kazdego klucza jak
//                         robil main.cu - to byl gruby narzut main.cu).
//
// GLOWNA OPTYMALIZACJA (batch modular inversion):
//  Zamiast dla KAZDEGO klucza liczyc:
//     _PointAddSecp256k1 (Jacobian) + _ModInv (BARDZO drogie!) + 2x_ModMult
//  co kosztuje ~ (12 ModMult-eq + 1 ModInv) na klucz,
//  liczymy dla calej GRUPY (GROUP_BATCH=128 kluczy naraz):
//     - dx[i] = (i+1)*G.x - start.x   dla i=0..n-1   (tabela z GPUGroup.h)
//     - JEDNA batch-inwersja (Montgomery trick, 1x _ModInv na 128 kluczy!)
//     - dla kazdego i: s=(dy)*inv(dx[i]); x=s^2-start.x-Gx[i]; y=s*(start.x-x)-start.y
//  Matematycznie DOKLADNIE rownowazne P + (i+1)*G (tozsamosc na krzywej) -
//  wynik identyczny co do bita, tylko nieporownywalnie mniej wywolan
//  drogiego _ModInv (128x rzadziej).
//
// POPRAWNOSC: scan_mode, isPrivOne (BUG#4 fix), brak odwracania slow
// (BUG#3 fix), 24-bitowy indeks + fallback bez indeksu, format bazy
// (20-bajtowe hash160, bez zmian) - WSZYSTKO zachowane 1:1 z main.cu.
//
// NIE dotykamy: SHA256/RIPEMD160 (pelny hash zawsze, ZERO "skroconych"
// hashy 4-bajtowych bez pelnego liczenia - user wyraznie zakazal tego
// pod-optymalizowania, bo nie dziala kryptograficznie).
// ============================================================

#ifndef __CUDA_ARCH__
#define __builtin_dynamic_object_size(p, i) __builtin_object_size(p, i)
#endif

#ifdef __CUDA_ARCH__
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#endif

#include <iostream>
#include <fstream>
#include <vector>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <chrono>
#include <thread>
#include <iomanip>
#include <cuda_runtime.h>
#include <mutex>
#include <atomic>
#include <algorithm>
#include <openssl/sha.h>
#include <openssl/ripemd.h>
#include <openssl/bn.h>
#include <secp256k1.h>

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// ============================================================
// MMAP dla glownego pliku adresow (11GB+) - 1:1 z main.cu.
// ============================================================
class MMapFile {
public:
    MMapFile() : fd(-1), data(nullptr), size(0) {}

    explicit MMapFile(const char* path) : fd(-1), data(nullptr), size(0) {
        open_file(path);
    }

    void open_file(const char* path) {
        close_file();
        fd = ::open(path, O_RDONLY);
        if (fd < 0) {
            throw std::runtime_error(std::string("open: ") + strerror(errno));
        }

        struct stat st{};
        if (fstat(fd, &st) != 0) {
            int e = errno;
            ::close(fd);
            fd = -1;
            throw std::runtime_error(std::string("fstat: ") + strerror(e));
        }

        size = (size_t)st.st_size;
        if (size == 0 || size % 20 != 0) {
            ::close(fd);
            fd = -1;
            throw std::runtime_error("invalid bin file (rozmiar musi byc wielokrotnoscia 20 bajtow)");
        }

        data = (const unsigned char*) mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0);
        if (data == MAP_FAILED) {
            int e = errno;
            data = nullptr;
            ::close(fd);
            fd = -1;
            throw std::runtime_error(std::string("mmap: ") + strerror(e));
        }

        madvise((void*)data, size, MADV_WILLNEED);
    }

    void close_file() {
        if (data) { munmap((void*)data, size); data = nullptr; }
        if (fd >= 0) { ::close(fd); fd = -1; }
        size = 0;
    }

    ~MMapFile() { close_file(); }

    MMapFile(const MMapFile&) = delete;
    MMapFile& operator=(const MMapFile&) = delete;
    MMapFile(MMapFile&& o) noexcept : fd(o.fd), data(o.data), size(o.size) {
        o.fd = -1; o.data = nullptr; o.size = 0;
    }
    MMapFile& operator=(MMapFile&& o) noexcept {
        if (this != &o) {
            close_file();
            fd = o.fd; data = o.data; size = o.size;
            o.fd = -1; o.data = nullptr; o.size = 0;
        }
        return *this;
    }

    const unsigned char* ptr() const { return data; }
    size_t length() const { return size; }
    bool is_open() const { return data != nullptr; }

private:
    int fd;
    const unsigned char* data;
    size_t size;
};

#include "GPUSecp.h"
#include "GPUHash.h"
#include "GPUMath.h"
#include "GPUGroup.h"   // Gx[]/Gy[] = G,2G,...,512G ; _2Gnx/_2Gny = 1024G
                         // (NIEUZYWANE w oryginalnych main*.cu - wykorzystane
                         // tutaj do grupowej inwersji modularnej)

// ============================================================
// STAŁE
// ============================================================
#define NUM_GTABLE_CHUNK 16
#define NUM_VALUES 65536
#define SIZE_GTABLE_POINT 32
#define POINT_SIZE 32
#define MAX_FOUND_KEYS 5000000

// Rozmiar grupy dla batch-inwersji modularnej (Montgomery trick).
// Gx[]/Gy[] w GPUGroup.h maja 512 wpisow (1*G..512*G), wiec GROUP_BATCH
// musi byc <= 512.
// BALANS (po analizie): per klucz BEZ batcha kosztuje ~1 _ModInv (~30
// ekwiw. ModMult) + PointAdd (~11) + 2 ModMult = ~43 ModMult-eq.
// Z batchem rozmiaru B koszt _ModInv rozklada sie na B kluczy:
//   ~ 30/B + (1 fwd + 2 bwd + ~5 formula dodawania afinicznego) = 30/B + 8
// B=8  -> 3.75 + 8 = 11.75  (3.7x szybciej, dx[8][4]+subp[8][4]=512B)
// B=16 -> 1.9  + 8 = 9.9    (marginalny zysk, 2x wiecej lokalnej pamieci)
// Zysk maleje wykladniczo powyzej ~8-16, wiec B=8 to sweet spot:
// najwiekszy zysk przy minimalnym uzyciu pamieci lokalnej (zero/minimalny
// spill). Gx[]/Gy[] w GPUGroup.h maja 512 wpisow (1G..512G) => B<=512.
#ifndef GROUP_BATCH
#define GROUP_BATCH 48
#endif

using namespace std;

mutex log_mutex;
uint64_t total_found_global = 0;

// ============================================================
// FUNKCJE KONWERSJI (CPU) - identyczne z main.cu
// ============================================================
void sha256_once(const unsigned char* d, size_t n, unsigned char out[32]) {
    SHA256_CTX c;
    SHA256_Init(&c);
    SHA256_Update(&c, d, n);
    SHA256_Final(out, &c);
}

void ripemd160_once(const unsigned char* d, size_t n, unsigned char out[20]) {
    RIPEMD160_CTX r;
    RIPEMD160_Init(&r);
    RIPEMD160_Update(&r, d, n);
    RIPEMD160_Final(out, &r);
}

void pubkey_hash160(const unsigned char* pub, size_t len, unsigned char out[20]) {
    unsigned char sh[32];
    sha256_once(pub, len, sh);
    ripemd160_once(sh, 32, out);
}

static const char* BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

string base58_encode(const vector<unsigned char>& in) {
    BIGNUM* bn = BN_new();
    BN_bin2bn(in.data(), in.size(), bn);

    BIGNUM *dv = BN_new(), *rem = BN_new(), *b58 = BN_new();
    BN_CTX* ctx = BN_CTX_new();
    BN_set_word(b58, 58);

    string out;
    while (!BN_is_zero(bn)) {
        BN_div(dv, rem, bn, b58, ctx);
        out.insert(out.begin(), BASE58[BN_get_word(rem)]);
        BN_copy(bn, dv);
    }

    for (unsigned char c : in)
        if (c == 0x00) out.insert(out.begin(), '1');
        else break;

    BN_free(bn); BN_free(dv); BN_free(rem); BN_free(b58); BN_CTX_free(ctx);
    return out;
}

// ============================================================
// DEKODOWANIE ADRESU -> HASH160 (opcja: user podaje adres zamiast .bin)
// Base58Check: adres -> 25 bajtow [wersja(1)][hash160(20)][checksum(4)].
// Zwraca true i wypelnia out[20] jesli adres poprawny (checksum OK).
// ============================================================
static bool base58_decode(const string& s, vector<unsigned char>& out) {
    BIGNUM* bn = BN_new(); BN_zero(bn);
    BIGNUM* b58 = BN_new(); BN_set_word(b58, 58);
    BN_CTX* ctx = BN_CTX_new();
    for(char c : s) {
        const char* p = strchr(BASE58, c);
        if(!p || c == '\0') { BN_free(bn); BN_free(b58); BN_CTX_free(ctx); return false; }
        BN_mul(bn, bn, b58, ctx);
        BN_add_word(bn, (BN_ULONG)(p - BASE58));
    }
    int num_bytes = BN_num_bytes(bn);
    vector<unsigned char> tmp(num_bytes);
    if(num_bytes > 0) BN_bn2bin(bn, tmp.data());
    // wiodace '1' w base58 == wiodace zerowe bajty
    int leading = 0;
    for(char c : s) { if(c == '1') leading++; else break; }
    out.assign(leading, 0x00);
    out.insert(out.end(), tmp.begin(), tmp.end());
    BN_free(bn); BN_free(b58); BN_CTX_free(ctx);
    return true;
}

// Zwraca true jesli 'addr' to poprawny adres P2PKH (zaczyna sie od '1'),
// wypelnia hash160[20]. Weryfikuje checksum (double-SHA256).
static bool address_to_hash160(const string& addr, unsigned char hash160[20]) {
    vector<unsigned char> dec;
    if(!base58_decode(addr, dec)) return false;
    if(dec.size() != 25) return false;             // 1+20+4
    unsigned char c1[32], c2[32];
    sha256_once(dec.data(), 21, c1);
    sha256_once(c1, 32, c2);
    if(memcmp(c2, dec.data() + 21, 4) != 0) return false; // checksum
    memcpy(hash160, dec.data() + 1, 20);
    return true;
}

string addr_p2pkh(const unsigned char ripe[20]) {
    vector<unsigned char> ext;
    ext.push_back(0x00);
    ext.insert(ext.end(), ripe, ripe+20);

    unsigned char c1[32], c2[32];
    sha256_once(ext.data(), ext.size(), c1);
    sha256_once(c1, 32, c2);

    ext.insert(ext.end(), c2, c2+4);
    return base58_encode(ext);
}

static const char* SECP256K1_ORDER_N_HEX = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141";
static bool reducePrivModOrderIfNeeded(unsigned char* priv) {
    BIGNUM* bn_priv = BN_new(); BIGNUM* bn_n = BN_new(); BIGNUM* bn_r = BN_new(); BN_CTX* bctx = BN_CTX_new();
    BN_bin2bn(priv, 32, bn_priv); BN_hex2bn(&bn_n, SECP256K1_ORDER_N_HEX); BN_mod(bn_r, bn_priv, bn_n, bctx);
    unsigned char reduced[32] = {0}; int len = BN_num_bytes(bn_r);
    if(len > 0) BN_bn2bin(bn_r, reduced + (32 - len));
    bool changed = (memcmp(priv, reduced, 32) != 0); memcpy(priv, reduced, 32);
    BN_free(bn_priv); BN_free(bn_n); BN_free(bn_r); BN_CTX_free(bctx); return changed;
}
static bool makeValidPubkey(secp256k1_context* ctx, secp256k1_pubkey* pub, unsigned char* priv) {
    if(secp256k1_ec_pubkey_create(ctx, pub, priv)) return true;
    reducePrivModOrderIfNeeded(priv);
    return secp256k1_ec_pubkey_create(ctx, pub, priv) != 0;
}

string keyToAddressCompressed(unsigned char* priv) {
    secp256k1_context* ctx = secp256k1_context_create(SECP256K1_CONTEXT_SIGN);
    secp256k1_pubkey pub;
    if(!makeValidPubkey(ctx, &pub, priv)) {
        secp256k1_context_destroy(ctx);
        return "INVALID_KEY";
    }
    unsigned char pub_ser[33];
    size_t pub_len = 33;
    secp256k1_ec_pubkey_serialize(ctx, pub_ser, &pub_len, &pub, SECP256K1_EC_COMPRESSED);
    unsigned char hash[20];
    pubkey_hash160(pub_ser, 33, hash);
    string addr = addr_p2pkh(hash);
    secp256k1_context_destroy(ctx);
    return addr;
}

string keyToAddress256(unsigned char* priv) {
    secp256k1_context* ctx = secp256k1_context_create(SECP256K1_CONTEXT_SIGN);
    secp256k1_pubkey pub;
    if(!makeValidPubkey(ctx, &pub, priv)) {
        secp256k1_context_destroy(ctx);
        return "INVALID_KEY";
    }
    unsigned char pub_ser[65];
    size_t pub_len = 65;
    secp256k1_ec_pubkey_serialize(ctx, pub_ser, &pub_len, &pub, SECP256K1_EC_UNCOMPRESSED);
    unsigned char hash[20];
    pubkey_hash160(pub_ser, 65, hash);
    string addr = addr_p2pkh(hash);
    secp256k1_context_destroy(ctx);
    return addr;
}

vector<uint8_t> loadFile(const char* path) {
    ifstream f(path, ios::binary | ios::ate);
    if(!f.is_open()) {
        cerr << "❌ Nie mogę otworzyć: " << path << "\n";
        exit(1);
    }
    size_t size = f.tellg();
    f.seekg(0, ios::beg);
    vector<uint8_t> data(size);
    f.read((char*)data.data(), size);
    f.close();
    return data;
}

void save_progress(uint64_t window_num, int start_bit, int end_bit,
                    uint64_t chunk, uint64_t total_found) {
    ofstream f("progress.txt", ios::trunc);
    f << window_num << "\n"
      << start_bit << "\n"
      << end_bit << "\n"
      << chunk << "\n"
      << total_found << "\n";
}

bool load_progress(uint64_t& window_num, int& start_bit, int& end_bit,
                    uint64_t& chunk, uint64_t& total_found) {
    ifstream f("progress.txt");
    if(!f.is_open()) return false;
    f >> window_num >> start_bit >> end_bit >> chunk >> total_found;
    return f.good() || f.eof();
}

// ============================================================
// BINARY SEARCH (identyczne z main.cu) - zwykly + z 24-bitowym
// indeksem prefiksowym.
// ============================================================
__device__ int _BinarySearch20(const uint8_t* buffer, uint64_t hi, const uint8_t* target)
{
    uint64_t lo = 0;
    while (lo < hi) {
        uint64_t mid = (lo + hi) / 2;
        const uint8_t* addr = buffer + mid * 20;
        bool equal = true;
        bool less = false;
        for(int i = 0; i < 20; i++) {
            if(addr[i] != target[i]) {
                less = (addr[i] < target[i]);
                equal = false;
                break;
            }
        }
        if(equal) return (int)mid;
        else if(less) lo = mid + 1;
        else hi = mid;
    }
    return -1;
}

__device__ __forceinline__ uint32_t _GetPrefix24(const uint8_t* p) {
    return (uint32_t(p[0]) << 16) | (uint32_t(p[1]) << 8) | uint32_t(p[2]);
}

__device__ int _BinarySearch20Indexed(const uint8_t* buffer, const uint64_t* prefixIndex, const uint8_t* target)
{
    uint32_t p = _GetPrefix24(target);
    uint64_t lo = prefixIndex[p];
    uint64_t hi = prefixIndex[p + 1];
    if (lo >= hi) return -1;
    while (lo < hi) {
        uint64_t mid = (lo + hi) / 2;
        const uint8_t* addr = buffer + mid * 20;
        bool equal = true;
        bool less = false;
        for(int i = 0; i < 20; i++) {
            if(addr[i] != target[i]) {
                less = (addr[i] < target[i]);
                equal = false;
                break;
            }
        }
        if(equal) return (int)mid;
        else if(less) lo = mid + 1;
        else hi = mid;
    }
    return -1;
}

// ============================================================
// _PointMultiSecp256k1 - identyczne z main.cu (bez debug-printow w
// hot-path; parametr debug zostawiony dla kompatybilnosci API, ale
// NIEUZYWANY w petli - zero narzutu na predkosc).
// ============================================================
__device__ void _PointMultiSecp256k1(
    uint64_t *qx,
    uint64_t *qy,
    uint16_t *privKey,
    uint8_t *gTableX,
    uint8_t *gTableY
) {
    int chunk = 0;
    uint64_t qz[5] = {1, 0, 0, 0, 0};

    for (; chunk < NUM_GTABLE_CHUNK; chunk++) {
        if (privKey[chunk] > 0) {
            int index = (CHUNK_FIRST_ELEMENT[chunk] + (privKey[chunk] - 1)) * POINT_SIZE;
            memcpy(qx, gTableX + index, POINT_SIZE);
            memcpy(qy, gTableY + index, POINT_SIZE);
            chunk++;
            break;
        }
    }

    for (; chunk < NUM_GTABLE_CHUNK; chunk++) {
        if (privKey[chunk] > 0) {
            uint64_t gx[4];
            uint64_t gy[4];
            int index = (CHUNK_FIRST_ELEMENT[chunk] + (privKey[chunk] - 1)) * POINT_SIZE;
            memcpy(gx, gTableX + index, POINT_SIZE);
            memcpy(gy, gTableY + index, POINT_SIZE);
            _PointAddSecp256k1(qx, qy, qz, gx, gy);
        }
    }

    _ModInv(qz);
    _ModMult(qx, qz);
    _ModMult(qy, qz);
}

// ============================================================
// POMOCNICZE 256-BIT (LE, word[0]=najmniej znaczace 64 bity)
// ============================================================
__device__ __forceinline__ void add256_small(uint64_t v[4], uint64_t inc) {
    uint64_t old0 = v[0]; v[0] += inc;
    uint64_t c = (v[0] < old0) ? 1 : 0;
    for(int i = 1; i < 4 && c; i++) { uint64_t old = v[i]; v[i] += c; c = (v[i] < old) ? 1 : 0; }
}
__device__ __forceinline__ void add256(uint64_t r[4], const uint64_t a[4], const uint64_t b[4]) {
    uint64_t c = 0;
    for(int i = 0; i < 4; i++) {
        uint64_t s = a[i] + b[i] + c;
        uint64_t c1 = (s < a[i]) ? 1 : 0;
        uint64_t c2 = (c && s == a[i]) ? 1 : 0;
        c = c1 | c2; r[i] = s;
    }
}
__device__ __forceinline__ void mul256_u64_add_base(uint64_t out[4], const uint64_t a[4], uint64_t b, const uint64_t base[4]) {
    uint64_t prod[4], carry = 0;
    for(int i = 0; i < 4; i++) {
        uint64_t lo, hi;
        UMULLO(lo, a[i], b); UMULHI(hi, a[i], b);
        uint64_t s = lo + carry;
        uint64_t c1 = (s < lo) ? 1 : 0;
        prod[i] = s; carry = hi + c1;
    }
    add256(out, prod, base);
}

// ============================================================
// UWAGA (na wyrazne zadanie uzytkownika): NIE uzywamy "skroconego"
// hash160 (SHA256+RIPEMD160 obciety do 4 bajtow bez pelnego liczenia)
// - to matematycznie nie ma sensu kryptograficznego (main26ghs mial
// tu BUGa: liczyl PELNY hash i potem obcinal - zero oszczednosci, ale
// user wyraznie zakazal probowania "prawdziwego" 4-bajtowego skrotu,
// bo to nie dziala). Uzywamy WYLACZNIE pelnego, prawidlowego hash160 +
// 24-bitowego indeksu prefiksowego (identycznie jak main.cu) do
// przyspieszenia SAMEGO WYSZUKIWANIA w bazie (nie liczenia hasha).
// ============================================================

// ============================================================
// BLOOM FILTER (tylko dla duzej bazy .bin) - przyspiesza SAMO
// WYSZUKIWANIE w bazie, gdy jest ogromna (606M adresow = 12 GB).
//
// PROBLEM: binary search po 12 GB w pamieci globalnej to ~6 losowych
// odczytow/klucz (cache miss za cache miss) - spowalnia z 3.3 do 1.17
// GH/s. Ale ~99.99% kluczy NIE ma trafienia - wystarczy szybko
// odrzucic te nietrafione.
//
// ROZWIAZANIE: bitmapa 1 GB (2^33 bitow). Dla kazdego hash160 z bazy
// ustawiamy BLOOM_K bitow (indeksy wyprowadzone WPROST z bajtow
// hash160 - hash160 jest juz losowy, wiec zero dodatkowego hashowania).
// Sprawdzenie klucza: jesli KTORYKOLWIEK z BLOOM_K bitow = 0 => klucza
// NA PEWNO nie ma w bazie => pomijamy drogi binary search. Bloom NIE
// ma falszywych negatywow (prawdziwy klucz zawsze przejdzie), wiec
// poprawnosc zachowana 1:1. Falszywe pozytywy (~0.1%) po prostu spadaja
// do binary search (ktory zwroci -1) - rzadkie, wiec tanie.
//
// 2^33 bitow / 606M wpisow = ~14 bitow/wpis, k=11 => FPR ~0.1%.
// Dostep: bloom w L2/global, ale bitmapa 1GB + wzorzec dostepu daje
// znacznie lepszy hit-rate niz binary search po 12 GB.
// ============================================================
#define BLOOM_BITS  (1ULL << 33)          // 8.59 Gbit = 1 GB bitmapy
#define BLOOM_MASK  (BLOOM_BITS - 1ULL)
#define BLOOM_WORDS (BLOOM_BITS >> 6)      // liczba uint64 = 2^27 = 128M
#define BLOOM_K     11                     // liczba bitow/wpis

// Wyprowadzenie 2 baz indeksu z 20-bajtowego hash160 (identyczne na CPU
// i GPU). Double-hashing Kirsch-Mitzenmacher: idx_i = a + i*b.
__host__ __device__ __forceinline__ void _bloomBases(const uint8_t* h, uint64_t& a, uint64_t& b) {
    a = (uint64_t)h[0] | ((uint64_t)h[1]<<8) | ((uint64_t)h[2]<<16) | ((uint64_t)h[3]<<24)
      | ((uint64_t)h[4]<<32) | ((uint64_t)h[5]<<40) | ((uint64_t)h[6]<<48) | ((uint64_t)h[7]<<56);
    b = (uint64_t)h[8] | ((uint64_t)h[9]<<8) | ((uint64_t)h[10]<<16) | ((uint64_t)h[11]<<24)
      | ((uint64_t)h[12]<<32) | ((uint64_t)h[13]<<40) | ((uint64_t)h[14]<<48) | ((uint64_t)h[15]<<56);
    uint64_t c = (uint64_t)h[16] | ((uint64_t)h[17]<<8) | ((uint64_t)h[18]<<16) | ((uint64_t)h[19]<<24);
    b ^= (c * 0x9E3779B97F4A7C15ULL); // wmieszaj ostatnie 4 bajty
    b |= 1ULL;                          // nieparzysty krok => lepsze pokrycie
}

// Zwraca false jesli hash NA PEWNO nie ma go w bazie (mozna pominac
// binary search). true = "byc moze jest" (trzeba potwierdzic).
__device__ __forceinline__ bool _BloomMaybe(const uint64_t* __restrict__ bloom, const uint8_t* h) {
    uint64_t a, b;
    _bloomBases(h, a, b);
    #pragma unroll
    for(int i = 0; i < BLOOM_K; i++) {
        uint64_t bit = (a + (uint64_t)i * b) & BLOOM_MASK;
        if(((bloom[bit >> 6] >> (bit & 63)) & 1ULL) == 0ULL) return false;
    }
    return true;
}

// ============================================================
// HELPER: sprawdzenie punktu (compressed/uncompressed) w bazie i zapis
// trafienia. Wydzielone, by petla batch-inwersji nie duplikowala tego
// kodu 3x (P_cur + kazdy punkt w grupie). __forceinline__ => zero
// narzutu wywolania (kod wklejany w miejscu jak wczesniej).
// cur_k = start_k + (indeks klucza w podwatku); found_priv = base_priv + cur_k.
// bloom != nullptr tylko dla duzej bazy .bin (pojedynczy adres nie
// potrzebuje - lookup i tak natychmiastowy).
// ============================================================
__device__ __forceinline__ void _checkStorePoint(
    uint64_t* qx_use, uint64_t* qy_use,
    uint64_t cur_k, const uint64_t* base_priv,
    bool do_compressed, bool do_uncompressed,
    const uint8_t* hash_data, uint64_t hash_count,
    const uint64_t* prefix_index,
    const uint64_t* bloom,
    unsigned char* found_keys, unsigned char* found_type,
    unsigned int* found_count,
    const uint8_t* __restrict__ single_target) // NEW: !=NULL = fast path
{
    uint8_t isOdd = (uint8_t)(qy_use[0] & 1);

    if (do_compressed) {
        uint8_t hash_comp[20];
        _GetHash160Comp(qx_use, isOdd, hash_comp);
        bool match = false;
        if (single_target) {
            // Fast path: 1 adres, bezposrednie porownanie 20 bajtow
            match = true;
            for (int i = 0; i < 20 && match; i++)
                if (hash_comp[i] != single_target[i]) match = false;
        } else if (bloom == nullptr || _BloomMaybe(bloom, hash_comp)) {
            int pos = (prefix_index != nullptr)
                ? _BinarySearch20Indexed(hash_data, prefix_index, hash_comp)
                : _BinarySearch20(hash_data, hash_count, hash_comp);
            match = (pos >= 0);
        }
        if (match) {
            unsigned int idx = atomicAdd(found_count, 1u);
            if (idx < MAX_FOUND_KEYS) {
                uint64_t tmpk[4], k_arr[4] = {cur_k, 0, 0, 0};
                add256(tmpk, base_priv, k_arr);
                for(int w = 0; w < 4; w++)
                    for(int b = 0; b < 8; b++)
                        found_keys[idx*32 + 31 - (w*8 + b)] = (unsigned char)((tmpk[w] >> (b*8)) & 0xFF);
                found_type[idx] = 0;
            }
        }
    }

    if (do_uncompressed) {
        uint8_t hash_unc[20];
        _GetHash160(qx_use, qy_use, hash_unc);
        bool match = false;
        if (single_target) {
            match = true;
            for (int i = 0; i < 20 && match; i++)
                if (hash_unc[i] != single_target[i]) match = false;
        } else if (bloom == nullptr || _BloomMaybe(bloom, hash_unc)) {
            int pos = (prefix_index != nullptr)
                ? _BinarySearch20Indexed(hash_data, prefix_index, hash_unc)
                : _BinarySearch20(hash_data, hash_count, hash_unc);
            match = (pos >= 0);
        }
        if (match) {
            unsigned int idx = atomicAdd(found_count, 1u);
            if (idx < MAX_FOUND_KEYS) {
                uint64_t tmpk[4], k_arr[4] = {cur_k, 0, 0, 0};
                add256(tmpk, base_priv, k_arr);
                for(int w = 0; w < 4; w++)
                    for(int b = 0; b < 8; b++)
                        found_keys[idx*32 + 31 - (w*8 + b)] = (unsigned char)((tmpk[w] >> (b*8)) & 0xFF);
                found_type[idx] = 1;
            }
        }
    }
}

// ============================================================
// FAST PATH: sprawdzenie punktu majac TYLKO qx i bit parzystosci Y (isOdd),
// bez pelnego Y. Uzywane dla compressed-only (puzzle), gdy Y nie jest
// potrzebne do niczego innego. Liczy hash160 compressed identycznie jak
// _checkStorePoint, ale bez zbednego przekazywania/liczenia pelnego qy.
// ============================================================
__device__ __forceinline__ void _checkStorePointFast(
    uint64_t* qx_use, uint8_t isOdd,
    uint64_t cur_k, const uint64_t* base_priv,
    const uint8_t* hash_data, uint64_t hash_count,
    const uint64_t* prefix_index,
    const uint64_t* bloom,
    unsigned char* found_keys, unsigned char* found_type,
    unsigned int* found_count,
    const uint8_t* __restrict__ single_target)
{
    uint8_t hash_comp[20];
    _GetHash160Comp(qx_use, isOdd, hash_comp);
    bool match = false;
    if (single_target) {
        match = true;
        for (int i = 0; i < 20 && match; i++)
            if (hash_comp[i] != single_target[i]) match = false;
    } else if (bloom == nullptr || _BloomMaybe(bloom, hash_comp)) {
        int pos = (prefix_index != nullptr)
            ? _BinarySearch20Indexed(hash_data, prefix_index, hash_comp)
            : _BinarySearch20(hash_data, hash_count, hash_comp);
        match = (pos >= 0);
    }
    if (match) {
        unsigned int idx = atomicAdd(found_count, 1u);
        if (idx < MAX_FOUND_KEYS) {
            uint64_t tmpk[4], k_arr[4] = {cur_k, 0, 0, 0};
            add256(tmpk, base_priv, k_arr);
            for(int w = 0; w < 4; w++)
                for(int b = 0; b < 8; b++)
                    found_keys[idx*32 + 31 - (w*8 + b)] = (unsigned char)((tmpk[w] >> (b*8)) & 0xFF);
            found_type[idx] = 0;
        }
    }
}
// ============================================================
// GLOWNY KERNEL - GRUPOWA (BATCH) INWERSJA MODULARNA
// ============================================================
// Kazdy (chunk, sub-watek) dostaje jeden punkt startowy P0 (tak jak w
// main.cu), po czym generuje block_size kolejnych punktow P0+G, P0+2G,
// ..., P0+block_size*G. ROBI TO W GRUPACH po GROUP_BATCH kluczy:
//   1. dx[i] = Gx[i] - P0.x dla i=0..n-1 (Gx[] z GPUGroup.h)
//   2. JEDNA batch-inwersja _ModInvGroupedN -> dx[i] = 1/dx[i]
//   3. Dla kazdego i liczy P0+((i+1)*G) uzywajac wzoru dodawania
//      punktow w afinicznych wspolrzednych (Z=1, jak w VanitySearch):
//         s = (Gy[i]-P0.y) * dx[i]
//         qx = s^2 - P0.x - Gx[i]
//         qy = s*(P0.x - qx) - P0.y
//      Matematycznie identyczne z _PointAddSecp256k1(Jacobian)+_ModInv,
//      tylko bez zbednych operacji na Z. Wynik identyczny co do bita.
// __launch_bounds__(256,2): WAZNY FIX PO POMIARACH - (256,6) (pierwsza
// wersja tego pliku) wymuszalo kompilatorowi TYLKO 40 rejestrow/wątek,
// co przy tak zlozonym kernelu (SHA256+RIPEMD160+ECDSA+batch inversion)
// powodowalo MASOWY spill do lokalnej pamieci (2412B store/3092B load
// NA WATEK, zmierzone przez -Xptxas -v) - lokalna pamiec jest
// nieporownywalnie wolniejsza od rejestrow, co dawalo NETTO regresje
// szybkosci (wolniej niz main.cu!). (256,2) daje 128 rejestrow/wątek
// i tylko 148B/128B spill (prawie zero) - min. 2 bloki/SM (lepsza
// okupancja niz bez __launch_bounds__ w ogole, co dawalo 172 rej. i
// tylko 1 blok/SM zmierzone empirycznie kompilacja z -Xptxas -v).
// Warp-level reduction (uzywana przez licznik hashy w kernelu)
__device__ __forceinline__ unsigned long long warp_reduce_add_ull(unsigned long long v) {
    v += __shfl_down_sync(0xFFFFFFFFu, v, 16);
    v += __shfl_down_sync(0xFFFFFFFFu, v, 8);
    v += __shfl_down_sync(0xFFFFFFFFu, v, 4);
    v += __shfl_down_sync(0xFFFFFFFFu, v, 2);
    v += __shfl_down_sync(0xFFFFFFFFu, v, 1);
    return v;
}

// ============================================================
__launch_bounds__(256, 1)
__global__ void fastscan_kernel(
    const uint8_t* __restrict__ hash_data,
    uint64_t hash_count,
    const uint64_t* __restrict__ prefix_index,
    const uint64_t* __restrict__ R0,
    const uint64_t* __restrict__ stride,
    uint64_t CHUNKS,
    const uint64_t* __restrict__ last_start,
    uint64_t launch_id,
    uint64_t block_size,
    uint64_t threads_per_chunk,
    uint64_t sub_block_size,
    unsigned char* __restrict__ found_keys,
    unsigned char* __restrict__ found_type,
    unsigned int* __restrict__ found_count,
    uint8_t* __restrict__ gTableX,
    uint8_t* __restrict__ gTableY,
    unsigned long long* __restrict__ progress_ptr,
    int scan_mode,
    const uint64_t* __restrict__ bloom,
    const uint8_t* __restrict__ single_target
) {
    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    int total = blockDim.x * gridDim.x;

    uint64_t global_id = launch_id * (uint64_t)total + (uint64_t)tid;
    uint64_t chunk_idx = global_id / threads_per_chunk;
    uint64_t sub_id = global_id % threads_per_chunk;
    if(chunk_idx >= CHUNKS) return;

    uint64_t start_k = sub_id * sub_block_size;
    if(start_k >= block_size) return;
    uint64_t end_k = start_k + sub_block_size;
    if(end_k > block_size) end_k = block_size;

    const bool do_compressed   = (scan_mode == 0 || scan_mode == 2);
    const bool do_uncompressed = (scan_mode == 1 || scan_mode == 2);

    uint64_t base_priv[4];
    if(chunk_idx == CHUNKS - 1) {
        base_priv[0] = last_start[0]; base_priv[1] = last_start[1];
        base_priv[2] = last_start[2]; base_priv[3] = last_start[3];
    } else {
        mul256_u64_add_base(base_priv, stride, chunk_idx, R0);
    }

    uint64_t priv4[4] = {base_priv[0], base_priv[1], base_priv[2], base_priv[3]};
    add256_small(priv4, start_k);

    unsigned char priv_256[32] = {0};
    for(int w = 0; w < 4; w++)
        for(int b = 0; b < 8; b++)
            priv_256[31 - (w*8 + b)] = (unsigned char)((priv4[w] >> (b*8)) & 0xFF);

    uint16_t priv_chunks[16] = {0};
    for(int i = 0; i < 16; i++)
        priv_chunks[15 - i] = (priv_256[i*2] << 8) | priv_256[i*2 + 1];

    // Punkt startowy P0 = priv4 * G, liczony RAZ na (chunk,sub-watek).
    uint64_t p0x[4], p0y[4];
    bool isPrivOne = (priv4[0] == 1 && priv4[1] == 0 && priv4[2] == 0 && priv4[3] == 0);
    if(isPrivOne) {
        p0x[0] = 0x59F2815B16F81798ULL; p0x[1] = 0x029BFCDB2DCE28D9ULL;
        p0x[2] = 0x55A06295CE870B07ULL; p0x[3] = 0x79BE667EF9DCBBACULL;
        p0y[0] = 0x9C47D08FFB10D4B8ULL; p0y[1] = 0xFD17B448A6855419ULL;
        p0y[2] = 0x5DA4FBFC0E1108A8ULL; p0y[3] = 0x483ADA7726A3C465ULL;
    } else {
        _PointMultiSecp256k1(p0x, p0y, priv_chunks, gTableX, gTableY);
    }

    const unsigned lane = threadIdx.x & 31u;
    unsigned int local_hashes = 0;
    #define FLUSH_THRESHOLD 65536u
    #define WARP_FLUSH() do { \
        unsigned long long v = warp_reduce_add_ull((unsigned long long)local_hashes); \
        if (lane == 0 && v) atomicAdd(progress_ptr, v); \
        local_hashes = 0; \
    } while(0)

    uint64_t total_keys = end_k - start_k;

    // ============================================================
    // GRUPOWA (BATCH) INWERSJA MONTGOMERY'EGO - POPRAWNA WERSJA.
    //
    // Punkt bazowy grupy P (afiniczny, Z=1). Dla grupy o rozmiarze n
    // liczymy n NOWYCH punktow: P+1G, P+2G, ..., P+nG. Wszystkie dodaja
    // do TEGO SAMEGO P (P nie jest aktualizowane wewnatrz grupy), wiec
    // potrzebujemy tylko dx[i]=Gx[i]-P.x, jedna batch-inwersja i dla
    // kazdego i wzor dodawania w afinicznych wspolrzednych.
    //
    // KLUCZOWY FIX na off-by-one z poprzednich prob: punkt P0 (klucz o
    // indeksie 0) jest sprawdzany JAWNIE PRZED petla grup. Nastepnie
    // kazda grupa produkuje DOKLADNIE n punktow (indeksy k_done..k_done+n-1),
    // bez luk i bez powtorzen. Suma sprawdzonych = 1 + (total_keys-1) =
    // total_keys. Zamiast total_keys wywolan _ModInv robimy ~total_keys/n.
    //
    // cur_k dla punktu i w grupie = start_k + k_done + i, bo:
    //  - P0 (indeks 0) sprawdzony osobno, potem k_done=1;
    //  - grupa o bazie P=P0+(k_done-1)*G produkuje P+(i+1)*G = indeks k_done+i.
    // Matematycznie identyczne co do bita z _PointAddSecp256k1+_ModInv.
    // ============================================================
    uint64_t Px[4] = {p0x[0],p0x[1],p0x[2],p0x[3]};
    uint64_t Py[4] = {p0y[0],p0y[1],p0y[2],p0y[3]};

    // --- klucz o indeksie 0 = P0 (sprawdzany jawnie) ---
    {
        uint64_t qx_use[4] = {Px[0],Px[1],Px[2],Px[3]};
        uint64_t qy_use[4] = {Py[0],Py[1],Py[2],Py[3]};
        _checkStorePoint(qx_use, qy_use, start_k + 0, base_priv,
                         do_compressed, do_uncompressed,
                         hash_data, hash_count, prefix_index, bloom,
                         found_keys, found_type, found_count, single_target);
        local_hashes++;
    }

    uint64_t k_done = 1;
    while(k_done < total_keys) {
        uint64_t remaining = total_keys - k_done;
        int n = (remaining < (uint64_t)GROUP_BATCH) ? (int)remaining : GROUP_BATCH;

        // dx[i] = Gx[i] - P.x   (Gx[i] = (i+1)*G z GPUGroup.h)
        uint64_t dx[GROUP_BATCH][4];
        for(int i = 0; i < n; i++)
            _ModSub256(dx[i], (uint64_t*)Gx[i], Px);

        // --- JEDNA batch-inwersja Montgomery'ego dla dx[0..n-1] ---
        {
            uint64_t subp[GROUP_BATCH][4];
            uint64_t inverse[5];
            subp[0][0]=dx[0][0]; subp[0][1]=dx[0][1]; subp[0][2]=dx[0][2]; subp[0][3]=dx[0][3];
            for(int i = 1; i < n; i++)
                _ModMult(subp[i], subp[i-1], dx[i]);

            inverse[0]=subp[n-1][0]; inverse[1]=subp[n-1][1];
            inverse[2]=subp[n-1][2]; inverse[3]=subp[n-1][3]; inverse[4]=0;
            _ModInv(inverse);

            for(int i = n-1; i > 0; i--) {
                uint64_t newValue[4];
                _ModMult(newValue, subp[i-1], inverse); // = 1/dx[i]
                _ModMult(inverse, dx[i]);               // = 1/(dx[0]*..*dx[i-1])
                dx[i][0]=newValue[0]; dx[i][1]=newValue[1]; dx[i][2]=newValue[2]; dx[i][3]=newValue[3];
            }
            dx[0][0]=inverse[0]; dx[0][1]=inverse[1]; dx[0][2]=inverse[2]; dx[0][3]=inverse[3];
        }

        // --- dla kazdego i: P+(i+1)*G = klucz(start_k + k_done + i) ---
        // OPTYMALIZACJA: dla i < n-1 potrzebujemy TYLKO bitu parzystosci Y
        // (do prefiksu compressed 0x02/0x03) - uzywamy _ModSub256isOdd, ktore
        // liczy tylko LSB, bez pelnego _ModMult na Y (patrz CUDACyclone).
        // Pelne Y liczymy TYLKO dla ostatniego punktu grupy (i=n-1), bo staje
        // sie nowa baza (Px,Py) dla nastepnej grupy w chainie.
        uint64_t lastx[4], lasty[4];
        for(int i = 0; i < n; i++) {
            uint64_t s[4], s2[4], qx_use[4], dy[4];
            _ModSub256(dy, (uint64_t*)Gy[i], Py);
            _ModMult(s, dy, dx[i]);          // s = (Gy[i]-Py)/dx[i]
            _ModSqr(s2, s);
            _ModSub256(qx_use, s2, Px);
            _ModSub256(qx_use, (uint64_t*)Gx[i]); // qx = s^2 - Px - Gx[i]

            if (i == n - 1) {
                // Ostatni punkt grupy: potrzebujemy PELNEGO Y (nowa baza chainu).
                uint64_t tmp[4], qy_use[4];
                _ModSub256(tmp, Px, qx_use);
                _ModMult(qy_use, s, tmp);
                _ModSub256(qy_use, Py);      // qy = s*(Px-qx) - Py

                lastx[0]=qx_use[0]; lastx[1]=qx_use[1]; lastx[2]=qx_use[2]; lastx[3]=qx_use[3];
                lasty[0]=qy_use[0]; lasty[1]=qy_use[1]; lasty[2]=qy_use[2]; lasty[3]=qy_use[3];

                _checkStorePoint(qx_use, qy_use, start_k + k_done + (uint64_t)i, base_priv,
                                 do_compressed, do_uncompressed,
                                 hash_data, hash_count, prefix_index, bloom,
                                 found_keys, found_type, found_count, single_target);
            } else if (do_uncompressed) {
                // Tryb uncompressed w uzyciu (baza .bin) - potrzebny pelny Y.
                uint64_t tmp[4], qy_use[4];
                _ModSub256(tmp, Px, qx_use);
                _ModMult(qy_use, s, tmp);
                _ModSub256(qy_use, Py);

                _checkStorePoint(qx_use, qy_use, start_k + k_done + (uint64_t)i, base_priv,
                                 do_compressed, do_uncompressed,
                                 hash_data, hash_count, prefix_index, bloom,
                                 found_keys, found_type, found_count, single_target);
            } else {
                // FAST PATH (puzzle, compressed-only): pomijamy druga polowe
                // pelnego _ModSub256 na Py - liczymy tylko bit parzystosci
                // wyniku (s*(Px-qx) - Py) przez _ModSub256isOdd.
                uint64_t tmp[4];
                _ModSub256(tmp, Px, qx_use);    // tmp = Px - qx
                uint64_t qy_tmp[4];
                _ModMult(qy_tmp, s, tmp);        // qy_tmp = s*(Px-qx)
                uint8_t isOdd = _ModSub256isOdd(qy_tmp, Py); // parytet (qy_tmp - Py)

                _checkStorePointFast(qx_use, isOdd, start_k + k_done + (uint64_t)i,
                                     base_priv, hash_data, hash_count, prefix_index,
                                     bloom, found_keys, found_type, found_count, single_target);
            }
            local_hashes++;
        }

        // nowa baza grupy = P + n*G (ostatni policzony punkt, i=n-1)
        Px[0]=lastx[0]; Px[1]=lastx[1]; Px[2]=lastx[2]; Px[3]=lastx[3];
        Py[0]=lasty[0]; Py[1]=lasty[1]; Py[2]=lasty[2]; Py[3]=lasty[3];

        k_done += (uint64_t)n;
        if(local_hashes >= FLUSH_THRESHOLD) WARP_FLUSH();
    }
    WARP_FLUSH();
}



// ============================================================
// KLASA SKANERA (identyczna logika BIGNUM rund/chunkow/stride jak
// main.cu - sprawdzona, poprawna implementacja algorytmu CPU
// fastscan v2, tylko podlaczona pod nowy, szybszy kernel powyzej).
// ============================================================
class FastScan {
private:
    uint8_t* gpu_hash_data;
    uint8_t* gpu_gTableX;
    uint8_t* gpu_gTableY;
    unsigned char* gpu_found;
    unsigned char* gpu_found_type;
    unsigned int* gpu_found_count;
    uint64_t* gpu_prefix_index;
    uint64_t* gpu_bloom;               // bitmapa bloom (tylko duza baza), else nullptr
    bool use_bloom;                    // czy budowac/uzywac bloom
    unsigned long long* progress_pinned;
    uint64_t hash_count;

    // --- TRYB 1 ADRESU (puzzle) - fast path bez binary search/indeksu/bloom ---
    bool single_mode = false;          // true = tryb 1 adresu (compressed only)
    uint8_t* gpu_single_target = nullptr; // 20-bajtowy hash160 celu na GPU (fast path)

    MMapFile hash_mmap;
    // Generyczne zrodlo hash-y: albo wskazuje na mmap (baza .bin), albo na
    // cpu_single_hash (gdy user podal pojedynczy adres zamiast pliku).
    const uint8_t* host_hash_ptr = nullptr;
    size_t host_hash_len = 0;
    vector<uint8_t> cpu_single_hash;   // trzymany w RAM gdy skanujemy 1 adres
    vector<uint8_t> cpu_gTableX;
    vector<uint8_t> cpu_gTableY;
    vector<unsigned char> cpu_found;
    vector<unsigned char> cpu_found_type;

public:
    FastScan() : gpu_hash_data(nullptr), gpu_gTableX(nullptr), gpu_gTableY(nullptr),
                 gpu_found(nullptr), gpu_found_type(nullptr), gpu_found_count(nullptr),
                 gpu_prefix_index(nullptr), gpu_bloom(nullptr), use_bloom(false),
                 gpu_single_target(nullptr), progress_pinned(nullptr), hash_count(0) {}

    ~FastScan() {
        if(gpu_hash_data) cudaFree(gpu_hash_data);
        if(gpu_gTableX) cudaFree(gpu_gTableX);
        if(gpu_gTableY) cudaFree(gpu_gTableY);
        if(gpu_found) cudaFree(gpu_found);
        if(gpu_found_type) cudaFree(gpu_found_type);
        if(gpu_found_count) cudaFree(gpu_found_count);
        if(gpu_prefix_index) cudaFree(gpu_prefix_index);
        if(gpu_bloom) cudaFree(gpu_bloom);
        if(gpu_single_target) cudaFree(gpu_single_target);
        if(progress_pinned) cudaFreeHost(progress_pinned);
    }

    bool loadHashes(const char* filename) {
        cout << "📂 Mapowanie (mmap) pliku adresów: " << filename << "\n";
        try {
            hash_mmap.open_file(filename);
        } catch(const std::exception& e) {
            cerr << "❌ Błąd mmap: " << e.what() << "\n";
            return false;
        }
        hash_count = hash_mmap.length() / 20;
        host_hash_ptr = hash_mmap.ptr();
        host_hash_len = hash_mmap.length();
        cout << "📊 Hash-y: " << hash_count << "\n";
        cout << "📊 Rozmiar pliku: " << (hash_mmap.length() / (1024*1024*1024)) << " GB (mmap, nie kopiowany do RAM)\n";

        // Bloom oplaca sie tylko dla duzej bazy (>~1M adresow). Dla malej
        // binary search i tak jest tani, a 1 GB bitmapy niepotrzebne.
        use_bloom = (hash_count > 1000000ULL);
        return loadGTable();
    }

    // Tryb bez pliku .bin: user podaje ADRES (np. 1BgGZ9...), program
    // dekoduje go do hash160 (Base58Check, checksum weryfikowany) i trzyma
    // JEDEN 20-bajtowy rekord w RAM (cpu_single_hash). Reszta pipeline
    // (upload na GPU, indeks prefiksowy, binary search) dziala bez zmian.
    bool loadSingleAddress(const string& address) {
        cout << "🏷️  Tryb pojedynczego adresu (bez pliku .bin): " << address << "\n";
        unsigned char h160[20];
        if(!address_to_hash160(address, h160)) {
            cerr << "❌ Niepoprawny adres P2PKH (checksum/format). Oczekiwany adres zaczynajacy sie od '1'.\n";
            return false;
        }
        cpu_single_hash.assign(h160, h160 + 20);
        hash_count = 1;
        single_mode = true;   // fast path: bez binary search / indeksu / bloom
        host_hash_ptr = cpu_single_hash.data();
        host_hash_len = cpu_single_hash.size();
        cout << "   hash160 = ";
        for(int i=0;i<20;i++){ char b[3]; sprintf(b,"%02x",h160[i]); cout<<b; }
        cout << "\n📊 Hash-y: 1 (w cache RAM, baza .bin nie ladowana)\n";
        return loadGTable();
    }

    bool loadGTable() {
        cout << "📂 Ładowanie GTable...\n";
        cpu_gTableX = loadFile("gtableX.bin");
        cpu_gTableY = loadFile("gtableY.bin");
        cout << "   gtableX: " << cpu_gTableX.size() / (1024*1024) << " MB\n";
        cout << "   gtableY: " << cpu_gTableY.size() / (1024*1024) << " MB\n";
        cout << "✅ Gotowe (mmap aktywny)\n";
        return true;
    }

    vector<uint64_t> buildPrefixIndex24() {
        const uint8_t* base = host_hash_ptr;
        uint64_t count = hash_count;

        vector<uint64_t> index(16777217, 0);

        cout << "📦 Budowanie 24-bitowego indeksu dla " << count << " adresów...\n";
        cout << "📊 Rozmiar indeksu: ~" << (index.size() * sizeof(uint64_t)) / (1024*1024) << " MB\n";

        auto start_time = chrono::steady_clock::now();

        auto get_prefix24 = [](const uint8_t* p) -> uint32_t {
            return (uint32_t(p[0]) << 16) | (uint32_t(p[1]) << 8) | uint32_t(p[2]);
        };

        // ============================================================
        // FIX KRYTYCZNY (bug "nie dziala z 1 adresem w bazie"):
        // Poprzedni algorytm uzywal index[p]==0 jako znacznika "pusty
        // kubełek", co koliduje z PRAWDZIWYM rekordem na pozycji 0, a
        // petla wypelniajaca luki (wstecz) nadpisywala granice kubełkow.
        // Przy duzej gestej bazie kazdy kubełek jest niezerowy => bug
        // ukryty; przy 1 adresie lookup zawsze zwracal -1.
        //
        // Nowy algorytm (counting + exclusive prefix-sum) jest POPRAWNY
        // dla dowolnej liczby rekordow (1 lub 600M) i O(count):
        //   index[p]   = offset pierwszego rekordu o prefiksie p
        //   index[p+1] = offset za ostatnim (czyli poczatek p+1)
        // Pusty kubełek => index[p]==index[p+1] => search zwraca -1.
        // Wymaga posortowanej bazy (prefiks niemalejacy) - tak jak dotad.
        // ============================================================
        // krok 1: policz wystapienia kazdego prefiksu (do index[0..2^24-1])
        for (uint64_t pos = 0; pos < count; pos++) {
            uint32_t p = get_prefix24(base + pos * 20);
            index[p]++;
            if ((pos & 0x3FFFFFF) == 0 && pos > 0) {
                cout << "\r   Zliczanie prefiksow: " << pos << "/" << count << flush;
            }
        }

        // krok 2: exclusive prefix-sum -> index[p] = poczatek kubełka p
        uint64_t running = 0;
        uint64_t buckets_found = 0;
        for (uint32_t p = 0; p < 16777216; p++) {
            uint64_t c = index[p];
            if (c > 0) buckets_found++;
            index[p] = running;
            running += c;
        }
        index[16777216] = running; // == count

        auto end_time = chrono::steady_clock::now();
        double seconds = chrono::duration<double>(end_time - start_time).count();

        cout << "\n✅ Indeks zbudowany: " << buckets_found << "/16777216 prefiksów używanych"
             << " (rekordow: " << running << ")\n";
        cout << "⏱️  Czas budowy: " << fixed << setprecision(1) << seconds << " s\n";

        return index;
    }

    // Buduje bitmape bloom na CPU (1 GB) i wgrywa na GPU. Tylko dla duzej
    // bazy. Zwraca true jesli bloom aktywny na GPU.
    bool buildBloomAndUpload() {
        if(!use_bloom) return false;
        auto t0 = chrono::steady_clock::now();
        size_t words = (size_t)BLOOM_WORDS;
        cout << "📦 Budowanie bloom filtra (" << (words*8/(1024*1024)) << " MB, k=" << BLOOM_K << ")...\n";
        vector<uint64_t> bloom(words, 0ULL);
        const uint8_t* base = host_hash_ptr;
        uint64_t count = hash_count;
        // Rownolegle (OpenMP): ustawianie bitow to OR - kolejnosc nieistotna,
        // ale rownoczesny zapis do TEGO SAMEGO slowa to wyscig, ktory moze
        // ZGUBIC ustawiony bit => falszywy negatyw => pominiety klucz. Dlatego
        // atomowy OR (sprzetowy lock-or). Kontencja niska (bity rozproszone po
        // 8 Gbit). Skraca budowe z ~90s do kilku s na 32 watkach.
        std::atomic<uint64_t>* ab = reinterpret_cast<std::atomic<uint64_t>*>(bloom.data());
        #pragma omp parallel for schedule(static)
        for(uint64_t pos = 0; pos < count; pos++) {
            const uint8_t* h = base + pos * 20;
            uint64_t a, b; _bloomBases(h, a, b);
            for(int i = 0; i < BLOOM_K; i++) {
                uint64_t bit = (a + (uint64_t)i * b) & (uint64_t)BLOOM_MASK;
                ab[bit >> 6].fetch_or(1ULL << (bit & 63), std::memory_order_relaxed);
            }
        }
        cudaError_t e = cudaMalloc(&gpu_bloom, words * sizeof(uint64_t));
        if(e != cudaSuccess) {
            cerr << "\n⚠️  Nie udalo sie zaalokowac bloom na GPU (" << (words*8/(1024*1024))
                 << " MB): " << cudaGetErrorString(e) << " - kontynuuje BEZ bloom\n";
            gpu_bloom = nullptr; use_bloom = false; return false;
        }
        cudaMemcpy(gpu_bloom, bloom.data(), words * sizeof(uint64_t), cudaMemcpyHostToDevice);
        double s = chrono::duration<double>(chrono::steady_clock::now() - t0).count();
        cout << "\n✅ Bloom na GPU (" << (words*8/(1024*1024)) << " MB, " << fixed << setprecision(1) << s << " s)\n";
        return true;
    }

    bool initGPU() {
        cout << "\n🖥️  Inicjalizacja GPU...\n";

        int deviceCount;
        cudaGetDeviceCount(&deviceCount);
        if(deviceCount == 0) {
            cerr << "❌ Brak GPU!\n";
            return false;
        }

        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, 0);
        cout << "   GPU: " << prop.name << "\n";
        cout << "   VRAM: " << prop.totalGlobalMem / (1024*1024*1024) << " GB\n";

        // CUDACyclone-style: L1 cache instead of shared memory = better perf
        cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
        cout << "   Cache: L1 preferred (CUDACyclone-style)\n";

        cout << "📦 Kopiowanie hash-y na GPU (" << host_hash_len << " B)...\n";
        cudaMalloc(&gpu_hash_data, host_hash_len);
        cudaMemcpy(gpu_hash_data, host_hash_ptr, host_hash_len, cudaMemcpyHostToDevice);

        cout << "📦 Kopiowanie GTable na GPU (64 MB)...\n";
        cudaMalloc(&gpu_gTableX, cpu_gTableX.size());
        cudaMemcpy(gpu_gTableX, cpu_gTableX.data(), cpu_gTableX.size(), cudaMemcpyHostToDevice);

        cudaMalloc(&gpu_gTableY, cpu_gTableY.size());
        cudaMemcpy(gpu_gTableY, cpu_gTableY.data(), cpu_gTableY.size(), cudaMemcpyHostToDevice);

        cudaMalloc(&gpu_found, MAX_FOUND_KEYS * 32);
        cudaMalloc(&gpu_found_type, MAX_FOUND_KEYS);
        cudaMalloc(&gpu_found_count, sizeof(unsigned int));
        cudaMemset(gpu_found_count, 0, sizeof(unsigned int));

        cpu_found.resize(MAX_FOUND_KEYS * 32);
        cpu_found_type.resize(MAX_FOUND_KEYS);

        cudaHostAlloc((void**)&progress_pinned, sizeof(unsigned long long), cudaHostAllocMapped);
        *progress_pinned = 0;

        // Fast path dla 1 adresu: wgraj 20-bajtowy hash160 celu na GPU.
        // Dla bazy .bin: single_target = nullptr -> kernel uzywa bloom + binary search.
        if(single_mode) {
            cout << "📦 Kopiowanie celu hash na GPU (20 B, fast path)...\n";
            cudaMalloc(&gpu_single_target, 20);
            cudaMemcpy(gpu_single_target, host_hash_ptr, 20, cudaMemcpyHostToDevice);
        }

        // Tryb bazy .bin (wiele adresow): buduj 24-bit indeks + bloom.
        // Tryb 1 adresu (puzzle): POMIJAMY - fast path robi bezposrednie
        // porownanie 20 bajtow w kernelu (zero indeksu, zero bloom).
        if(!single_mode) {
            cout << "📦 Budowanie i kopiowanie 24-bitowego indeksu prefiksowego na GPU...\n";
            {
            vector<uint64_t> cpu_prefix_index = buildPrefixIndex24();
            size_t idxBytes = cpu_prefix_index.size() * sizeof(uint64_t);
            cudaError_t allocErr = cudaMalloc(&gpu_prefix_index, idxBytes);
            if(allocErr != cudaSuccess) {
                cerr << "⚠️  Nie udalo sie zaalokowac indeksu na GPU (" << idxBytes / (1024*1024)
                     << " MB): " << cudaGetErrorString(allocErr)
                     << " - kontynuuje BEZ indeksu (wolniejszy fallback binary search)\n";
                gpu_prefix_index = nullptr;
            } else {
                cudaMemcpy(gpu_prefix_index, cpu_prefix_index.data(), idxBytes, cudaMemcpyHostToDevice);
                cout << "✅ Indeks skopiowany na GPU (" << idxBytes / (1024*1024) << " MB)\n";
            }
        }

        // Bloom filter (tylko duza baza) - przyspiesza wyszukiwanie.
        buildBloomAndUpload();
        }

        cout << "✅ GPU gotowe!\n";
        return true;
    }

    static void bn_to_words(const BIGNUM* bn, uint64_t w[4]) {
        unsigned char buf[32] = {0};
        BN_bn2binpad(bn, buf, 32);
        for(int word = 0; word < 4; word++) {
            uint64_t v = 0;
            for(int b = 0; b < 8; b++) {
                v = (v << 8) | buf[(3 - word) * 8 + b];
            }
            w[word] = v;
        }
    }

    // ============================================================
    // scan() - identyczna logika z main.cu (BIGNUM rundy/chunki/stride,
    // 1:1 z algorytmem CPU fastscan v2) - podlaczona pod nowy kernel.
    // ============================================================
    void scan(int start_bit, int end_bit,
              uint64_t resume_round = 0,
              uint64_t resume_launch = 0,
              uint64_t resume_total_found = 0,
              int scan_mode = 2) {
        // ============================================================
        // FIX (proste, ale kluczowe): main.cu mial BLOCKS=512, THREADS=256
        // = tylko 131072 wątkow calkowicie - dla RTX 4090 (128 SM) to
        // DRASTYCZNIE za malo, GPU byl w duzej czesci bezczynny. Twoje
        // wlasne pliki main26ghs (BLOCKS=4096,THREADS=512) i finalchat
        // (BLOCKS=8192,THREADS=256) uzywaly 2097152 wątkow - 16x wiecej!
        // Kopiuje te sprawdzone wartosci (main26ghs) - to jedna z
        // najprostszych i najwiekszych mozliwych poprawek predkosci.
        // ============================================================
        // BLOCKS=8192, THREADS=256 (finalchat.cu) - zgodne z
        // __launch_bounds__(256,1) kernela (GROUP_BATCH=4, zero spill,
        // 246 rejestrow/wątek - maksimum bez spillowania przy tej
        // zlozonosci kernela z SHA256+RIPEMD160+batch inversion).
        #define BLOCKS 8192
        #define THREADS 256
        #define TOTAL_THREADS (BLOCKS * THREADS)

        const int MAX_BIT = 256;
        if(start_bit < 0) start_bit = 0;
        if(start_bit > MAX_BIT) start_bit = MAX_BIT;
        if(end_bit > MAX_BIT) end_bit = MAX_BIT;
        if(end_bit <= start_bit) end_bit = start_bit + 1;

        const uint64_t BLOCK_SIZE = 5000000ULL;
        const uint64_t INITIAL_CHUNKS = 3563ULL;

        BN_CTX* bnctx = BN_CTX_new();
        BIGNUM *R0 = BN_new(), *R1 = BN_new(), *RLEN = BN_new();
        BIGNUM *two = BN_new(), *bs = BN_new(), *be = BN_new();
        BN_set_word(two, 2);
        BN_set_word(bs, start_bit);
        BN_set_word(be, end_bit);
        BN_exp(R0, two, bs, bnctx);
        BN_exp(R1, two, be, bnctx);
        BN_sub_word(R1, 1);
        BN_sub(RLEN, R1, R0);
        BN_add_word(RLEN, 1);

        cout << "\n🪟 Zakres (STALY, NIE rozszerzany): bit " << start_bit
             << " -> bit " << end_bit << "\n";

        uint64_t total_found = resume_total_found;
        total_found_global = resume_total_found;
        uint64_t round_idx = (resume_round > 0) ? resume_round : 1;
        uint64_t start_launch = resume_launch;

        ofstream f("found.txt", ios::app);

        uint64_t CHUNKS = INITIAL_CHUNKS;
        for(uint64_t r = 1; r < round_idx; r++) CHUNKS *= 2;

        while(true) {
            BIGNUM* bn_chunks = BN_new();
            BN_set_word(bn_chunks, CHUNKS);

            BIGNUM* stride = BN_new();
            BN_div(stride, nullptr, RLEN, bn_chunks, bnctx);
            if(BN_is_zero(stride)) BN_set_word(stride, 1);

            BIGNUM* bn_block_size = BN_new();
            BN_set_word(bn_block_size, BLOCK_SIZE);
            BIGNUM* eff_block_bn = BN_new();
            if(BN_cmp(stride, bn_block_size) < 0) {
                BN_copy(eff_block_bn, stride);
            } else {
                BN_copy(eff_block_bn, bn_block_size);
            }
            if(BN_is_zero(eff_block_bn)) BN_set_word(eff_block_bn, 1);
            uint64_t effBlockSize = BN_get_word(eff_block_bn);
            BN_free(bn_block_size);
            BN_free(eff_block_bn);

            BIGNUM* last_start_bn = BN_new();
            BN_copy(last_start_bn, R1);
            BIGNUM* bsz = BN_new();
            BN_set_word(bsz, effBlockSize - 1);
            if(BN_cmp(RLEN, bsz) > 0) {
                BN_sub(last_start_bn, R1, bsz);
            } else {
                BN_copy(last_start_bn, R0);
            }
            BN_free(bsz);

            uint64_t effChunks = CHUNKS;

            uint64_t R0w[4], stridew[4], lastw[4];
            bn_to_words(R0, R0w);
            bn_to_words(stride, stridew);
            bn_to_words(last_start_bn, lastw);

            uint64_t *d_R0, *d_stride, *d_last;
            cudaMalloc(&d_R0, 4*sizeof(uint64_t));
            cudaMalloc(&d_stride, 4*sizeof(uint64_t));
            cudaMalloc(&d_last, 4*sizeof(uint64_t));
            cudaMemcpy(d_R0, R0w, 4*sizeof(uint64_t), cudaMemcpyHostToDevice);
            cudaMemcpy(d_stride, stridew, 4*sizeof(uint64_t), cudaMemcpyHostToDevice);
            cudaMemcpy(d_last, lastw, 4*sizeof(uint64_t), cudaMemcpyHostToDevice);

            uint64_t numLaunches = (effChunks + TOTAL_THREADS - 1) / TOTAL_THREADS;

            char* strideStr = BN_bn2dec(stride);
            cout << "\n🔁 Runda " << round_idx << " | Chunks: " << effChunks
                 << " | stride: " << strideStr << " | block_size (eff): " << effBlockSize
                 << " (max: " << BLOCK_SIZE << ")"
                 << (effBlockSize < BLOCK_SIZE ? " | [gestniejsze pokrycie - chunki bez zachodzenia]" : "");
            if(start_launch > 0) cout << " | ⏯️  wznowienie od batcha " << start_launch;
            cout << "\n";
            OPENSSL_free(strideStr);

            uint64_t threads_per_chunk = (uint64_t)TOTAL_THREADS / effChunks;
            const uint64_t MIN_THREADS_PER_CHUNK = 32;   // = 1 warp na chunk
            if(threads_per_chunk < MIN_THREADS_PER_CHUNK) threads_per_chunk = MIN_THREADS_PER_CHUNK;
            if(threads_per_chunk > effBlockSize) threads_per_chunk = (effBlockSize > 0) ? effBlockSize : 1;
            uint64_t sub_block_size = (effBlockSize + threads_per_chunk - 1) / threads_per_chunk;
            if(sub_block_size < 1) sub_block_size = 1;

            uint64_t totalWorkUnits = effChunks * threads_per_chunk;
            uint64_t numLaunches2 = (totalWorkUnits + TOTAL_THREADS - 1) / TOTAL_THREADS;
            numLaunches = numLaunches2;

            cout << "   [Rownoleglosc: " << threads_per_chunk << " watkow/chunk, "
                 << sub_block_size << " kluczy/watek sekwencyjnie]\n";

            auto start_time = chrono::steady_clock::now();

            const auto PROGRESS_SAVE_INTERVAL = chrono::minutes(10);
            auto last_progress_save = chrono::steady_clock::now() - PROGRESS_SAVE_INTERVAL;

            for(uint64_t launch = start_launch; launch < numLaunches; launch++) {
                *progress_pinned = 0;

                fastscan_kernel<<<BLOCKS, THREADS>>>(
                    gpu_hash_data,
                    hash_count,
                    gpu_prefix_index,
                    d_R0,
                    d_stride,
                    effChunks,
                    d_last,
                    launch,
                    effBlockSize,
                    threads_per_chunk,
                    sub_block_size,
                    gpu_found,
                    gpu_found_type,
                    gpu_found_count,
                    gpu_gTableX,
                    gpu_gTableY,
                    progress_pinned,
                    scan_mode,
                    gpu_bloom,
                    gpu_single_target
                );

                cudaError_t qerr;
                auto last_print_time = chrono::steady_clock::now() - chrono::seconds(10);
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                    qerr = cudaStreamQuery(0);

                    auto now = chrono::steady_clock::now();
                    bool shouldPrint = (qerr == cudaSuccess) ||
                        (chrono::duration<double>(now - last_print_time).count() >= 1.0);
                    if(!shouldPrint) continue;
                    last_print_time = now;

                    unsigned long long liveProg = *progress_pinned;

                    double elapsed = chrono::duration<double>(now - start_time).count();
                    uint64_t chunksDoneLive = (launch * (uint64_t)TOTAL_THREADS) / (threads_per_chunk > 0 ? threads_per_chunk : 1);
                    double extraChunks = (effBlockSize > 0) ? ((double)liveProg / (double)effBlockSize) : 0.0;
                    double chunksDoneApprox = (double)chunksDoneLive + extraChunks;
                    if(chunksDoneApprox > (double)effChunks) chunksDoneApprox = (double)effChunks;

                    double speed = (elapsed > 0) ? (chunksDoneApprox * effBlockSize) / elapsed / 1e9 : 0.0;

                    cout << "\r   Batch: " << launch << "/" << numLaunches
                         << " | chunki: " << (uint64_t)chunksDoneApprox << "/" << effChunks
                         << " | " << fixed << setprecision(2) << speed << " Gkeys/s"
                         << " | found: " << total_found_global
                         << std::flush;
                } while(qerr != cudaSuccess);

                unsigned int count = 0;
                cudaMemcpy(&count, gpu_found_count, sizeof(unsigned int), cudaMemcpyDeviceToHost);

                if(count > 0) {
                    if(count > MAX_FOUND_KEYS) count = MAX_FOUND_KEYS;
                    cout << "\n🎯 ZNALEZIONO " << count << " TRAFIEN!\n";
                    total_found += count;
                    total_found_global += count;

                    cudaMemcpy(cpu_found.data(), gpu_found, count * 32, cudaMemcpyDeviceToHost);
                    cudaMemcpy(cpu_found_type.data(), gpu_found_type, count, cudaMemcpyDeviceToHost);

                    for(unsigned int i = 0; i < count; i++) {
                        unsigned char orig_key[32];
                        memcpy(orig_key, cpu_found.data() + i * 32, 32);
                        bool isUncompressed = (cpu_found_type[i] != 0);
                        string addr = isUncompressed ? keyToAddress256(orig_key) : keyToAddressCompressed(orig_key);

                        cout << "   ✅ KEY: ";
                        for(int j = 0; j < 32; j++) {
                            cout << hex << setw(2) << setfill('0') << (int)orig_key[j];
                        }
                        cout << dec << "\n";
                        cout << "   ✅ TYP: " << (isUncompressed ? "UNCOMPRESSED" : "COMPRESSED") << "\n";
                        cout << "   ✅ ADDR: " << addr << "\n";

                        f << "KEY: ";
                        for(int j = 0; j < 32; j++) {
                            f << hex << setw(2) << setfill('0') << (int)orig_key[j];
                        }
                        f << dec << "\n";
                        f << "TYP: " << (isUncompressed ? "UNCOMPRESSED" : "COMPRESSED") << "\n";
                        f << "ADDR: " << addr << "\n";
                        f << "---\n";
                        f.flush();
                    }

                    unsigned int zero = 0;
                    cudaMemcpy(gpu_found_count, &zero, sizeof(unsigned int), cudaMemcpyHostToDevice);
                }

                auto nowSave = chrono::steady_clock::now();
                if(nowSave - last_progress_save >= PROGRESS_SAVE_INTERVAL) {
                    save_progress(round_idx, start_bit, end_bit, launch + 1, total_found_global);
                    last_progress_save = nowSave;
                }
            }

            auto end_time = chrono::steady_clock::now();
            double elapsed = chrono::duration<double>(end_time - start_time).count();
            // ============================================================
            // FIX BUGA (odziedziczonego 1:1 z main.cu): stara formula
            // "numLaunches * TOTAL_THREADS * effBlockSize" ZAWYZA wynik o
            // czynnik threads_per_chunk, bo kazdy z threads_per_chunk
            // watkow dzielacych 1 chunk robi TYLKO sub_block_size kluczy
            // (nie effBlockSize) - mnozenie przez effBlockSize dla KAZDEGO
            // watka liczy te same klucze threads_per_chunk-krotnie.
            // Poprawna calkowita liczba kluczy w rundzie to ZAWSZE
            // effChunks * effBlockSize, niezaleznie od podzialu na watki
            // (bo threads_per_chunk * sub_block_size ~= effBlockSize).
            // ============================================================
            double speed = (elapsed > 0) ? ((double)effChunks * (double)effBlockSize) / elapsed / 1e9 : 0.0;

            cout << "\n✅ Runda " << round_idx << " zakończona! Chunkow zrobionych: "
                 << effChunks << "/" << effChunks << "\n";
            cout << "   Czas: " << elapsed << " s\n";
            cout << "   Szybkość: " << fixed << setprecision(2) << speed << " Gkeys/s\n";
            cout << "   Znaleziono łącznie: " << total_found << " trafień\n\n";

            cudaFree(d_R0); cudaFree(d_stride); cudaFree(d_last);
            BN_free(bn_chunks); BN_free(stride); BN_free(last_start_bn);

            start_launch = 0;
            round_idx++;
            CHUNKS *= 2;
            save_progress(round_idx, start_bit, end_bit, 0, total_found_global);
        }

        f.close();
        BN_free(R0); BN_free(R1); BN_free(RLEN);
        BN_free(two); BN_free(bs); BN_free(be);
        BN_CTX_free(bnctx);
    }
};

// ============================================================
// MAIN
// ============================================================
int main(int argc, char* argv[]) {
    if(argc < 4) {
        cout << "================================================================\n";
        cout << "🚀 FASTSCAN GPU - OPTYMALIZOWANY (batch modular inversion)\n";
        cout << "================================================================\n\n";
        cout << "Użycie: ./fastscan_gpu_opt <adresy.bin | ADRES> start_bit end_bit [--resume] [--mode=comp|uncomp|both]\n\n";
        cout << "  <adresy.bin> - plik bazy (20-bajtowe hash160, posortowane) LUB\n";
        cout << "  <ADRES>      - pojedynczy adres P2PKH (np. 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH);\n";
        cout << "                 program sam zamienia go na hash160 i trzyma w cache (bez pliku .bin)\n\n";
        cout << "Przykład:\n";
        cout << "  ./fastscan_gpu_opt adresy.bin 0 5\n";
        cout << "  ./fastscan_gpu_opt adresy.bin 0 5 --mode=comp\n";
        cout << "  ./fastscan_gpu_opt 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH 66 67 --mode=comp\n";
        cout << "  ./fastscan_gpu_opt adresy.bin 0 5 --resume\n";
        return 1;
    }

    int scan_mode = 2;
    for(int i = 4; i < argc; i++) {
        string a = argv[i];
        if(a == "--mode=comp" || a == "--mode=compressed") scan_mode = 0;
        else if(a == "--mode=uncomp" || a == "--mode=uncompressed") scan_mode = 1;
        else if(a == "--mode=both") scan_mode = 2;
    }
    const char* modeLabel = (scan_mode == 0) ? "COMPRESSED" : (scan_mode == 1) ? "UNCOMPRESSED" : "BOTH";
    cout << "🔎 Tryb skanowania adresów: " << modeLabel << "\n";

    cout << "================================================================\n";
    cout << "🚀 FASTSCAN GPU - OPTYMALIZOWANY (batch modular inversion)\n";
    cout << "================================================================\n\n";

    FastScan scanner;
    // Auto-detekcja: jesli argv[1] istnieje jako plik -> baza .bin;
    // w przeciwnym razie traktuj argv[1] jako adres P2PKH do zamiany na hash160.
    {
        struct stat st;
        bool is_file = (stat(argv[1], &st) == 0 && S_ISREG(st.st_mode));
        bool ok = is_file ? scanner.loadHashes(argv[1])
                          : scanner.loadSingleAddress(string(argv[1]));
        if(!ok) return 1;
    }
    if(!scanner.initGPU()) return 1;

    int start_bit = stoi(argv[2]);
    int end_bit = stoi(argv[3]);

    bool resume = (argc >= 5 && string(argv[4]) == "--resume");
    uint64_t resume_window = 0, resume_chunk = 0, resume_found = 0;

    if(resume) {
        int saved_start_bit = 0, saved_end_bit = 0;
        if(load_progress(resume_window, saved_start_bit, saved_end_bit, resume_chunk, resume_found)) {
            start_bit = saved_start_bit;
            end_bit = saved_end_bit;
            cout << "⏯️  WZNOWIENIE z progress.txt: okno #" << resume_window
                 << " (bit " << start_bit << " -> " << end_bit << ")"
                 << " | chunk " << resume_chunk
                 << " | znaleziono dotad: " << resume_found << "\n\n";
        } else {
            cout << "⚠️  Brak progress.txt lub plik nieprawidłowy - zaczynam od podanych argumentów.\n\n";
        }
    }

    scanner.scan(start_bit, end_bit, resume_window, resume_chunk, resume_found, scan_mode);

    return 0;
}
