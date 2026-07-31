// ============================================================
// main_253_256_standalone.cu - FASTSCAN GPU - SKANER 253-256 bit (baza PUBKEY)
// ============================================================
// Wersja STANDALONE z wieloma rundami (bez pool) – działa jak oryginalny skaner,
// ale bez logiki pool/split-key. Po każdej rundzie zwiększa licznik rund,
// podwaja liczbę chunków i stosuje DEDUP (grid_mult/off) aby uniknąć duplikatów.
// ============================================================
// POPRAWKI:
// 1. --resume teraz poprawnie wznawia od zapisanej rundy (resume_round)
// 2. CHUNKS jest poprawnie obliczane dla wznowionej rundy
// 3. start_launch jest poprawnie przekazywany z progress.txt
// 4. total_found_global używa std::atomic (bezpieczny dla multi-GPU)
// 5. progress.txt zapisywany per-GPU (progress_gpu0.txt itd.)
// 6. DEDUP optymalizacja: tylko potrzebne launch'e
// 7. Dodano flagę --split-gpu – dzieli zakres równo między wszystkie GPU
// 8. Poprawiono błąd BN_new_set_word -> BN_new() + BN_set_word()
// 9. Usunięto warning o redefinicji GRP_SIZE (ustawiamy przed includami)
// ============================================================

#define _FORTIFY_SOURCE 0

#ifndef __CUDA_ARCH__
#define __builtin_dynamic_object_size(p, i) __builtin_object_size(p, i)
#endif

// ============================================================
// FIX: GRP_SIZE – ustawiamy raz, przed includami, aby uniknąć redefinicji
// ============================================================
#ifdef GRP_SIZE
#undef GRP_SIZE
#endif
#define GRP_SIZE 1024

#include <iostream>
#include <fstream>
#include <vector>
#include <cstring>
#include <cstdlib>
#include <cstdio>
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

#include "GPUSecp.h"
#include "GPUHash.h"
#include "GPUMath.h"
#include "GPUGroup.h"

// ============================================================
// STAŁE
// ============================================================
#define NUM_GTABLE_CHUNK 16
#define NUM_VALUES 65536
#define SIZE_GTABLE_POINT 32
#define POINT_SIZE 32
#define MAX_FOUND_KEYS 5000

#ifndef USE_ENDO
#define USE_ENDO 1
#endif

#ifndef GROUP_BATCH
#define GROUP_BATCH 40
#endif

using namespace std;

mutex log_mutex;
atomic<uint64_t> total_found_global(0);

// ============================================================
// STAŁE KRYPTYCZNE
// ============================================================
__device__ __constant__ uint64_t SECP_N[4] = {
    0xBFD25E8CD0364141ULL, 0xBAAEDCE6AF48A03BULL,
    0xFFFFFFFFFFFFFFFEULL, 0xFFFFFFFFFFFFFFFFULL
};

static const char* LAMBDA_HEX = "5363ad4cc05c30e0a5261c028812645a122e22ea20816678df02967c1b23bd72";
static const char* LAMBDA2_HEX = "ac9c52b33fa3cf1f5ad9e3fd77ed9ba4a880b9fc8ec739c2e0cfc810b51283ce";

// ============================================================
// MMAP
// ============================================================
class MMapFile {
public:
    MMapFile() : fd(-1), data(nullptr), size(0) {}
    explicit MMapFile(const char* path) : fd(-1), data(nullptr), size(0) { open_file(path); }

    void open_file(const char* path) {
        close_file();
        fd = ::open(path, O_RDONLY);
        if (fd < 0) throw std::runtime_error(std::string("open: ") + strerror(errno));
        struct stat st{};
        if (fstat(fd, &st) != 0) { int e = errno; ::close(fd); fd = -1; throw std::runtime_error(std::string("fstat: ") + strerror(e)); }
        size = (size_t)st.st_size;
        if (size == 0 || size % 65 != 0) { ::close(fd); fd = -1; throw std::runtime_error("invalid bin file (rozmiar musi byc wielokrotnoscia 65 bajtow - pubkey 04||X||Y)"); }
        data = (const unsigned char*) mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0);
        if (data == MAP_FAILED) { int e = errno; data = nullptr; ::close(fd); fd = -1; throw std::runtime_error(std::string("mmap: ") + strerror(e)); }
        madvise((void*)data, size, MADV_WILLNEED);
    }

    void close_file() { if (data) { munmap((void*)data, size); data = nullptr; } if (fd >= 0) { ::close(fd); fd = -1; } size = 0; }
    ~MMapFile() { close_file(); }
    MMapFile(const MMapFile&) = delete;
    MMapFile& operator=(const MMapFile&) = delete;
    MMapFile(MMapFile&& o) noexcept : fd(o.fd), data(o.data), size(o.size) { o.fd = -1; o.data = nullptr; o.size = 0; }
    MMapFile& operator=(MMapFile&& o) noexcept { if (this != &o) { close_file(); fd = o.fd; data = o.data; size = o.size; o.fd = -1; o.data = nullptr; o.size = 0; } return *this; }
    const unsigned char* ptr() const { return data; }
    size_t length() const { return size; }
    bool is_open() const { return data != nullptr; }

private:
    int fd;
    const unsigned char* data;
    size_t size;
};

// ============================================================
// FUNKCJE KONWERSJI (CPU)
// ============================================================
void sha256_once(const unsigned char* d, size_t n, unsigned char out[32]) {
    SHA256_CTX c; SHA256_Init(&c); SHA256_Update(&c, d, n); SHA256_Final(out, &c);
}

void ripemd160_once(const unsigned char* d, size_t n, unsigned char out[20]) {
    RIPEMD160_CTX r; RIPEMD160_Init(&r); RIPEMD160_Update(&r, d, n); RIPEMD160_Final(out, &r);
}

void pubkey_hash160(const unsigned char* pub, size_t len, unsigned char out[20]) {
    unsigned char sh[32]; sha256_once(pub, len, sh); ripemd160_once(sh, 32, out);
}

static const char* BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

string base58_encode(const vector<unsigned char>& in) {
    BIGNUM* bn = BN_new(); BN_bin2bn(in.data(), in.size(), bn);
    BIGNUM *dv = BN_new(), *rem = BN_new(), *b58 = BN_new(); BN_CTX* ctx = BN_CTX_new(); BN_set_word(b58, 58);
    string out;
    while (!BN_is_zero(bn)) { BN_div(dv, rem, bn, b58, ctx); out.insert(out.begin(), BASE58[BN_get_word(rem)]); BN_copy(bn, dv); }
    for (unsigned char c : in) if (c == 0x00) out.insert(out.begin(), '1'); else break;
    BN_free(bn); BN_free(dv); BN_free(rem); BN_free(b58); BN_CTX_free(ctx);
    return out;
}

static bool base58_decode(const string& s, vector<unsigned char>& out) {
    BIGNUM* bn = BN_new(); BN_zero(bn); BIGNUM* b58 = BN_new(); BN_set_word(b58, 58); BN_CTX* ctx = BN_CTX_new();
    for(char c : s) { const char* p = strchr(BASE58, c); if(!p || c == '\0') { BN_free(bn); BN_free(b58); BN_CTX_free(ctx); return false; } BN_mul(bn, bn, b58, ctx); BN_add_word(bn, (BN_ULONG)(p - BASE58)); }
    int num_bytes = BN_num_bytes(bn); vector<unsigned char> tmp(num_bytes); if(num_bytes > 0) BN_bn2bin(bn, tmp.data());
    int leading = 0; for(char c : s) { if(c == '1') leading++; else break; } out.assign(leading, 0x00); out.insert(out.end(), tmp.begin(), tmp.end());
    BN_free(bn); BN_free(b58); BN_CTX_free(ctx);
    return true;
}

static bool address_to_hash160(const string& addr, unsigned char hash160[20]) {
    vector<unsigned char> dec; if(!base58_decode(addr, dec)) return false; if(dec.size() != 25) return false;
    unsigned char c1[32], c2[32]; sha256_once(dec.data(), 21, c1); sha256_once(c1, 32, c2);
    if(memcmp(c2, dec.data() + 21, 4) != 0) return false; memcpy(hash160, dec.data() + 1, 20); return true;
}

string addr_p2pkh(const unsigned char ripe[20]) {
    vector<unsigned char> ext; ext.push_back(0x00); ext.insert(ext.end(), ripe, ripe+20);
    unsigned char c1[32], c2[32]; sha256_once(ext.data(), ext.size(), c1); sha256_once(c1, 32, c2);
    ext.insert(ext.end(), c2, c2+4); return base58_encode(ext);
}

static const char* SECP256K1_ORDER_N_HEX = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141";

static bool reducePrivModOrderIfNeeded(unsigned char* priv) {
    BIGNUM* bn_priv = BN_new(); BIGNUM* bn_n = BN_new(); BIGNUM* bn_r = BN_new(); BN_CTX* bctx = BN_CTX_new();
    BN_bin2bn(priv, 32, bn_priv); BN_hex2bn(&bn_n, SECP256K1_ORDER_N_HEX); BN_mod(bn_r, bn_priv, bn_n, bctx);
    unsigned char reduced[32] = {0}; int len = BN_num_bytes(bn_r); if(len > 0) BN_bn2bin(bn_r, reduced + (32 - len));
    bool changed = (memcmp(priv, reduced, 32) != 0); memcpy(priv, reduced, 32);
    BN_free(bn_priv); BN_free(bn_n); BN_free(bn_r); BN_CTX_free(bctx); return changed;
}

static bool makeValidPubkey(secp256k1_context* ctx, secp256k1_pubkey* pub, unsigned char* priv) {
    if(secp256k1_ec_pubkey_create(ctx, pub, priv)) return true;
    reducePrivModOrderIfNeeded(priv); return secp256k1_ec_pubkey_create(ctx, pub, priv) != 0;
}

string keyToAddressCompressed(unsigned char* priv) {
    secp256k1_context* ctx = secp256k1_context_create(SECP256K1_CONTEXT_SIGN);
    secp256k1_pubkey pub; if(!makeValidPubkey(ctx, &pub, priv)) { secp256k1_context_destroy(ctx); return "INVALID_KEY"; }
    unsigned char pub_ser[33]; size_t pub_len = 33; secp256k1_ec_pubkey_serialize(ctx, pub_ser, &pub_len, &pub, SECP256K1_EC_COMPRESSED);
    unsigned char hash[20]; pubkey_hash160(pub_ser, 33, hash); string addr = addr_p2pkh(hash); secp256k1_context_destroy(ctx); return addr;
}

string keyToAddressUncompressed(unsigned char* priv) {
    secp256k1_context* ctx = secp256k1_context_create(SECP256K1_CONTEXT_SIGN);
    secp256k1_pubkey pub; if(!makeValidPubkey(ctx, &pub, priv)) { secp256k1_context_destroy(ctx); return "INVALID_KEY"; }
    unsigned char pub_ser[65]; size_t pub_len = 65; secp256k1_ec_pubkey_serialize(ctx, pub_ser, &pub_len, &pub, SECP256K1_EC_UNCOMPRESSED);
    unsigned char hash[20]; pubkey_hash160(pub_ser, 65, hash); string addr = addr_p2pkh(hash); secp256k1_context_destroy(ctx); return addr;
}

vector<uint8_t> loadFile(const char* path) {
    ifstream f(path, ios::binary | ios::ate); if(!f.is_open()) { cerr << "❌ Nie mogę otworzyć: " << path << "\n"; exit(1); }
    size_t size = f.tellg(); f.seekg(0, ios::beg); vector<uint8_t> data(size); f.read((char*)data.data(), size); f.close(); return data;
}

// ============================================================
// FUNKCJE ZAPISU POSTĘPU (per-GPU)
// ============================================================
void save_progress(uint64_t window_num, int start_bit, int end_bit,
                    uint64_t chunk, uint64_t total_found, int gpu_id = 0) {
    string fname = (gpu_id == 0) ? "progress.txt" : "progress_gpu" + to_string(gpu_id) + ".txt";
    ofstream f(fname, ios::trunc);
    f << window_num << "\n" << start_bit << "\n" << end_bit << "\n" << chunk << "\n" << total_found << "\n";
}

bool load_progress(uint64_t& window_num, int& start_bit, int& end_bit,
                    uint64_t& chunk, uint64_t& total_found, int gpu_id = 0) {
    string fname = (gpu_id == 0) ? "progress.txt" : "progress_gpu" + to_string(gpu_id) + ".txt";
    ifstream f(fname); if(!f.is_open()) return false;
    f >> window_num >> start_bit >> end_bit >> chunk >> total_found;
    return f.good() || f.eof();
}

// ============================================================
// BAZA PUBKEY - FUNKCJE WYSZUKIWANIA (GPU)
// ============================================================
__device__ __forceinline__ int _CmpX32(const uint8_t* a, const uint8_t* b) {
    for(int i = 0; i < 32; i++) {
        if(a[i] != b[i]) return (a[i] < b[i]) ? -1 : 1;
    }
    return 0;
}

__device__ __forceinline__ bool _Eq65(const uint8_t* a, const uint8_t* b) {
    #pragma unroll
    for(int i = 0; i < 65; i++) if(a[i] != b[i]) return false;
    return true;
}

__device__ int _BinarySearch65(const uint8_t* buffer, uint64_t hi, const uint8_t* target) {
    uint64_t lo = 0;
    while (lo < hi) {
        uint64_t mid = (lo + hi) / 2;
        const uint8_t* rec = buffer + mid * 65;
        int c = _CmpX32(rec + 1, target + 1);
        if(c == 0) {
            if(_Eq65(rec, target)) return (int)mid;
            for(uint64_t j = mid; j > 0; j--) { const uint8_t* r2 = buffer + (j-1)*65; if(_CmpX32(r2+1, target+1) != 0) break; if(_Eq65(r2, target)) return (int)(j-1); }
            for(uint64_t j = mid + 1; j < hi; j++) { const uint8_t* r2 = buffer + j*65; if(_CmpX32(r2+1, target+1) != 0) break; if(_Eq65(r2, target)) return (int)j; }
            return -1;
        } else if(c < 0) lo = mid + 1;
        else hi = mid;
    }
    return -1;
}

__device__ __forceinline__ uint32_t _GetPrefix24(const uint8_t* p) {
    return (uint32_t(p[0]) << 16) | (uint32_t(p[1]) << 8) | uint32_t(p[2]);
}

__device__ int _BinarySearch65Indexed(const uint8_t* buffer, const uint64_t* prefixIndex, const uint8_t* target) {
    uint32_t p = _GetPrefix24(target + 1);
    uint64_t lo = prefixIndex[p];
    uint64_t hi = prefixIndex[p + 1];
    if (lo >= hi) return -1;
    while (lo < hi) {
        uint64_t mid = (lo + hi) / 2;
        const uint8_t* rec = buffer + mid * 65;
        int c = _CmpX32(rec + 1, target + 1);
        if(c == 0) {
            if(_Eq65(rec, target)) return (int)mid;
            for(uint64_t j = mid; j > lo; j--) { const uint8_t* r2 = buffer + (j-1)*65; if(_CmpX32(r2+1, target+1) != 0) break; if(_Eq65(r2, target)) return (int)(j-1); }
            for(uint64_t j = mid + 1; j < hi; j++) { const uint8_t* r2 = buffer + j*65; if(_CmpX32(r2+1, target+1) != 0) break; if(_Eq65(r2, target)) return (int)j; }
            return -1;
        } else if(c < 0) lo = mid + 1;
        else hi = mid;
    }
    return -1;
}

// ============================================================
// BITMAP FILTER
// ============================================================
__device__ __forceinline__ bool _BitmapCheck32(const uint32_t* L1, const uint32_t* L2, const uint64_t* qx_use) {
    if (!L1 && !L2) return true;
    uint32_t top32 = (uint32_t)(qx_use[3] >> 32);
    if (L1) { uint32_t t26=top32>>6; if(!(L1[(t26>>5)] & (1u<<(t26&31)))) return false; }
    if (L2) { if(!(L2[(top32>>5)] & (1u<<(top32&31)))) return false; }
    return true;
}

__device__ __forceinline__ bool _BinarySearchX32Only(const uint8_t* buffer, uint64_t lo, uint64_t hi, const uint8_t* targetX32, const uint32_t* L1, const uint32_t* L2, const uint64_t* qx_use) {
    if (!_BitmapCheck32(L1, L2, qx_use)) return false;
    while (lo < hi) {
        uint64_t mid = (lo + hi) / 2;
        const uint8_t* rec = buffer + mid * 65;
        int c = _CmpX32(rec + 1, targetX32);
        if(c == 0) return true;
        else if(c < 0) lo = mid + 1;
        else hi = mid;
    }
    return false;
}

__device__ __forceinline__ bool _BinarySearchX32OnlyIndexed(const uint8_t* buffer, const uint64_t* prefixIndex, const uint8_t* targetX32, const uint32_t* L1, const uint32_t* L2, const uint64_t* qx_use) {
    if (!_BitmapCheck32(L1, L2, qx_use)) return false;
    uint32_t p = _GetPrefix24(targetX32);
    uint64_t lo = prefixIndex[p];
    uint64_t hi = prefixIndex[p + 1];
    if (lo >= hi) return false;
    return _BinarySearchX32Only(buffer, lo, hi, targetX32, L1, L2, qx_use);
}

// ============================================================
// _PointMultiSecp256k1
// ============================================================
__device__ void _PointMultiSecp256k1(
    uint64_t *qx, uint64_t *qy,
    uint16_t *privKey,
    uint8_t *gTableX, uint8_t *gTableY
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
            uint64_t gx[4]; uint64_t gy[4];
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
// POMOCNICZE 256-bit
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
// SPRAWDZENIE PUNKTU W BAZIE
// ============================================================
__device__ __forceinline__ bool _checkStorePointPubkey(
    uint64_t* qx_use, uint64_t* qy_use,
    uint64_t cur_k, const uint64_t* base_priv,
    const uint8_t* pubkey_data, uint64_t pubkey_count,
    const uint64_t* prefix_index,
    unsigned char* found_keys, unsigned char* found_type,
    unsigned int* found_count,
    const uint8_t* __restrict__ single_target,
    int variant_base)
{
    uint8_t pub[65];
    pub[0] = 0x04;
    for(int w = 0; w < 4; w++)
        for(int b = 0; b < 8; b++)
            pub[1 + 31 - (w*8 + b)] = (unsigned char)((qx_use[w] >> (b*8)) & 0xFF);
    for(int w = 0; w < 4; w++)
        for(int b = 0; b < 8; b++)
            pub[33 + 31 - (w*8 + b)] = (unsigned char)((qy_use[w] >> (b*8)) & 0xFF);

    if (single_target) {
        bool match = true;
        for (int i = 0; i < 65 && match; i++) if (pub[i] != single_target[i]) match = false;
        if (match) goto do_save_normal;
        uint64_t qy_neg[4] = {qy_use[0], qy_use[1], qy_use[2], qy_use[3]};
        _ModNeg256(qy_neg);
        for(int w = 0; w < 4; w++)
            for(int b = 0; b < 8; b++)
                pub[33 + 31 - (w*8 + b)] = (unsigned char)((qy_neg[w] >> (b*8)) & 0xFF);
        match = true;
        for (int i = 0; i < 65 && match; i++) if (pub[i] != single_target[i]) match = false;
        if (match) goto do_save_negated;
        return false;
    } else {
        int pos = (prefix_index != nullptr)
            ? _BinarySearch65Indexed(pubkey_data, prefix_index, pub)
            : _BinarySearch65(pubkey_data, pubkey_count, pub);
        if (pos >= 0) goto do_save_normal;
        uint64_t qy_neg[4] = {qy_use[0], qy_use[1], qy_use[2], qy_use[3]};
        _ModNeg256(qy_neg);
        for(int w = 0; w < 4; w++)
            for(int b = 0; b < 8; b++)
                pub[33 + 31 - (w*8 + b)] = (unsigned char)((qy_neg[w] >> (b*8)) & 0xFF);
        pos = (prefix_index != nullptr)
            ? _BinarySearch65Indexed(pubkey_data, prefix_index, pub)
            : _BinarySearch65(pubkey_data, pubkey_count, pub);
        if (pos >= 0) goto do_save_negated;
        return false;
    }
do_save_normal:
    {
        unsigned int idx = atomicAdd(found_count, 1u);
        if (idx < MAX_FOUND_KEYS) {
            uint64_t tmpk[4] = {base_priv[0], base_priv[1], base_priv[2], base_priv[3]};
            add256_small(tmpk, cur_k);
            for(int w = 0; w < 4; w++)
                for(int b = 0; b < 8; b++)
                    found_keys[idx*32 + 31 - (w*8 + b)] = (unsigned char)((tmpk[w] >> (b*8)) & 0xFF);
            found_type[idx] = (unsigned char)(variant_base);
        }
        return true;
    }
do_save_negated:
    {
        unsigned int idx = atomicAdd(found_count, 1u);
        if (idx < MAX_FOUND_KEYS) {
            uint64_t tmpk[4] = {base_priv[0], base_priv[1], base_priv[2], base_priv[3]};
            add256_small(tmpk, cur_k);
            for(int w = 0; w < 4; w++)
                for(int b = 0; b < 8; b++)
                    found_keys[idx*32 + 31 - (w*8 + b)] = (unsigned char)((tmpk[w] >> (b*8)) & 0xFF);
            found_type[idx] = (unsigned char)(variant_base + 1);
        }
        return true;
    }
}

// ============================================================
// KERNEL GŁÓWNY (z DEDUP: grid_mult, grid_off)
// ============================================================
__device__ __forceinline__ unsigned long long warp_reduce_add_ull(unsigned long long v) {
    v += __shfl_down_sync(0xFFFFFFFFu, v, 16);
    v += __shfl_down_sync(0xFFFFFFFFu, v, 8);
    v += __shfl_down_sync(0xFFFFFFFFu, v, 4);
    v += __shfl_down_sync(0xFFFFFFFFu, v, 2);
    v += __shfl_down_sync(0xFFFFFFFFu, v, 1);
    return v;
}

__launch_bounds__(256, 1)
__global__ void fastscan_kernel(
    const uint8_t* __restrict__ pubkey_data,
    uint64_t pubkey_count,
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
    const uint32_t* __restrict__ bitmap,
    const uint32_t* __restrict__ bitmap_L1,
    const uint8_t* __restrict__ single_target,
    const uint64_t* __restrict__ single_target_X,
    uint64_t grid_mult,
    uint64_t grid_off
) {
    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    int total = blockDim.x * gridDim.x;

    uint64_t global_id = launch_id * (uint64_t)total + (uint64_t)tid;
    uint64_t work_idx = global_id / threads_per_chunk;
    uint64_t grid_idx = work_idx * grid_mult + grid_off;
    uint64_t sub_id = global_id % threads_per_chunk;
    if(work_idx >= CHUNKS) return;
    if(grid_idx >= CHUNKS) return;

    uint64_t start_k = sub_id * sub_block_size;
    if(start_k >= block_size) return;
    uint64_t end_k = start_k + sub_block_size;
    if(end_k > block_size) end_k = block_size;

    uint64_t base_priv[4];
    if(grid_idx == CHUNKS - 1) {
        base_priv[0] = last_start[0]; base_priv[1] = last_start[1];
        base_priv[2] = last_start[2]; base_priv[3] = last_start[3];
    } else {
        mul256_u64_add_base(base_priv, stride, grid_idx, R0);
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

    uint64_t Px[4] = {p0x[0],p0x[1],p0x[2],p0x[3]};
    uint64_t Py[4] = {p0y[0],p0y[1],p0y[2],p0y[3]};

    // klucz o indeksie 0
    {
        uint64_t qx_use[4] = {Px[0],Px[1],Px[2],Px[3]};
        uint64_t qy_use[4] = {Py[0],Py[1],Py[2],Py[3]};
        _checkStorePointPubkey(qx_use, qy_use, start_k + 0, base_priv,
                         pubkey_data, pubkey_count, prefix_index,
                         found_keys, found_type, found_count, single_target, 1);
#if USE_ENDO
        uint64_t qx2[4], qx3[4];
        _ModMult(qx2, qx_use, (uint64_t*)_beta);
        _ModMult(qx3, qx2, (uint64_t*)_beta);
        _checkStorePointPubkey(qx2, qy_use, start_k + 0, base_priv,
                         pubkey_data, pubkey_count, prefix_index,
                         found_keys, found_type, found_count, single_target, 3);
        _checkStorePointPubkey(qx3, qy_use, start_k + 0, base_priv,
                         pubkey_data, pubkey_count, prefix_index,
                         found_keys, found_type, found_count, single_target, 5);
#endif
        local_hashes++;
    }

    uint64_t k_done = 1;
    while(k_done < total_keys) {
        uint64_t remaining = total_keys - k_done;
        int n = (remaining < (uint64_t)GROUP_BATCH) ? (int)remaining : GROUP_BATCH;

        uint64_t dx[GROUP_BATCH][4];
        for(int i = 0; i < n; i++)
            _ModSub256(dx[i], (uint64_t*)Gx[i], Px);

        {
            uint64_t inverse[5];
            for(int i = 1; i < n; i++)
                _ModMult(dx[i], dx[i-1], dx[i]);
            inverse[0]=dx[n-1][0]; inverse[1]=dx[n-1][1];
            inverse[2]=dx[n-1][2]; inverse[3]=dx[n-1][3]; inverse[4]=0;
            _ModInv(inverse);
            for(int i = n-1; i > 0; i--) {
                uint64_t newVal[4];
                _ModMult(newVal, dx[i-1], inverse);
                uint64_t orig_i[4];
                _ModSub256(orig_i, (uint64_t*)Gx[i], Px);
                _ModMult(inverse, orig_i);
                dx[i][0]=newVal[0]; dx[i][1]=newVal[1]; dx[i][2]=newVal[2]; dx[i][3]=newVal[3];
            }
            dx[0][0]=inverse[0]; dx[0][1]=inverse[1]; dx[0][2]=inverse[2]; dx[0][3]=inverse[3];
        }

        uint64_t lastx[4], lasty[4];
        for(int i = 0; i < n; i++) {
            uint64_t s[4], s2[4], qx_use[4], dy[4];
            _ModSub256(dy, (uint64_t*)Gy[i], Py);
            _ModMult(s, dy, dx[i]);
            _ModSqr(s2, s);
            _ModSub256(qx_use, s2, Px);
            _ModSub256(qx_use, (uint64_t*)Gx[i]);

            uint8_t xbytes[32];
            if (!single_target) {
                for(int w = 0; w < 4; w++)
                    for(int b = 0; b < 8; b++)
                        xbytes[31 - (w*8 + b)] = (unsigned char)((qx_use[w] >> (b*8)) & 0xFF);
            }

            bool candidate;
            if (single_target) {
                candidate = (qx_use[0] == single_target_X[0] && qx_use[1] == single_target_X[1] &&
                             qx_use[2] == single_target_X[2] && qx_use[3] == single_target_X[3]);
            } else {
                candidate = (prefix_index != nullptr)
                    ? _BinarySearchX32OnlyIndexed(pubkey_data, prefix_index, xbytes, bitmap_L1, bitmap, qx_use)
                    : _BinarySearchX32Only(pubkey_data, 0, pubkey_count, xbytes, bitmap_L1, bitmap, qx_use);
            }

#if USE_ENDO
            uint64_t qx2[4], qx3[4];
            _ModMult(qx2, qx_use, (uint64_t*)_beta);
            _ModMult(qx3, qx2, (uint64_t*)_beta);
            uint8_t xb2[32], xb3[32];
            for(int w = 0; w < 4; w++)
                for(int b = 0; b < 8; b++)
                    xb2[31 - (w*8 + b)] = (unsigned char)((qx2[w] >> (b*8)) & 0xFF);
            for(int w = 0; w < 4; w++)
                for(int b = 0; b < 8; b++)
                    xb3[31 - (w*8 + b)] = (unsigned char)((qx3[w] >> (b*8)) & 0xFF);
            bool cand_beta, cand_beta2;
            if (single_target) {
                cand_beta = (qx2[0] == single_target_X[0] && qx2[1] == single_target_X[1] &&
                              qx2[2] == single_target_X[2] && qx2[3] == single_target_X[3]);
                cand_beta2 = (qx3[0] == single_target_X[0] && qx3[1] == single_target_X[1] &&
                               qx3[2] == single_target_X[2] && qx3[3] == single_target_X[3]);
            } else {
                cand_beta = (prefix_index != nullptr)
                    ? _BinarySearchX32OnlyIndexed(pubkey_data, prefix_index, xb2, bitmap_L1, bitmap, qx2)
                    : _BinarySearchX32Only(pubkey_data, 0, pubkey_count, xb2, bitmap_L1, bitmap, qx2);
                cand_beta2 = (prefix_index != nullptr)
                    ? _BinarySearchX32OnlyIndexed(pubkey_data, prefix_index, xb3, bitmap_L1, bitmap, qx3)
                    : _BinarySearchX32Only(pubkey_data, 0, pubkey_count, xb3, bitmap_L1, bitmap, qx3);
            }
#endif

            bool is_last = (i == n - 1);
#if USE_ENDO
            bool need_y = is_last || candidate || cand_beta || cand_beta2;
#else
            bool need_y = is_last || candidate;
#endif
            uint64_t qy_use[4];
            if (need_y) {
                uint64_t tmp[4];
                _ModSub256(tmp, Px, qx_use);
                _ModMult(qy_use, s, tmp);
                _ModSub256(qy_use, Py);
            }

            if (is_last) {
                lastx[0]=qx_use[0]; lastx[1]=qx_use[1]; lastx[2]=qx_use[2]; lastx[3]=qx_use[3];
                lasty[0]=qy_use[0]; lasty[1]=qy_use[1]; lasty[2]=qy_use[2]; lasty[3]=qy_use[3];
            }

            if (candidate)
                _checkStorePointPubkey(qx_use, qy_use, start_k + k_done + (uint64_t)i, base_priv,
                                 pubkey_data, pubkey_count, prefix_index,
                                 found_keys, found_type, found_count, single_target, 1);
#if USE_ENDO
            if (cand_beta)
                _checkStorePointPubkey(qx2, qy_use, start_k + k_done + (uint64_t)i, base_priv,
                                 pubkey_data, pubkey_count, prefix_index,
                                 found_keys, found_type, found_count, single_target, 3);
            if (cand_beta2)
                _checkStorePointPubkey(qx3, qy_use, start_k + k_done + (uint64_t)i, base_priv,
                                 pubkey_data, pubkey_count, prefix_index,
                                 found_keys, found_type, found_count, single_target, 5);
#endif
        }
            local_hashes++;

        Px[0]=lastx[0]; Px[1]=lastx[1]; Px[2]=lastx[2]; Px[3]=lastx[3];
        Py[0]=lasty[0]; Py[1]=lasty[1]; Py[2]=lasty[2]; Py[3]=lasty[3];

        k_done += (uint64_t)n;
        if(local_hashes >= FLUSH_THRESHOLD) WARP_FLUSH();
    }
    WARP_FLUSH();
}

// ============================================================
// KLASA SKANERA (STANDALONE z wieloma rundami)
// ============================================================
class FastScan {
private:
    uint8_t* gpu_pubkey_data;
    uint8_t* gpu_gTableX;
    uint8_t* gpu_gTableY;
    unsigned char* gpu_found;
    unsigned char* gpu_found_type;
    unsigned int* gpu_found_count;
    uint64_t* gpu_prefix_index;
    uint32_t* gpu_bitmap;
    uint32_t* gpu_bitmap_L1;
    unsigned long long* progress_pinned;
    uint64_t pubkey_count;
    int gpu_id;

    bool single_mode = false;
    uint8_t* gpu_single_target = nullptr;
    uint64_t* gpu_single_target_X = nullptr;

    MMapFile pubkey_mmap;
    const uint8_t* host_pubkey_ptr = nullptr;
    size_t host_pubkey_len = 0;
    vector<uint8_t> cpu_single_pubkey;
    vector<uint8_t> cpu_gTableX;
    vector<uint8_t> cpu_gTableY;
    vector<unsigned char> cpu_found;
    vector<unsigned char> cpu_found_type;

public:
    FastScan() : gpu_pubkey_data(nullptr), gpu_gTableX(nullptr), gpu_gTableY(nullptr),
                 gpu_found(nullptr), gpu_found_type(nullptr), gpu_found_count(nullptr),
                 gpu_prefix_index(nullptr), gpu_bitmap(nullptr), gpu_bitmap_L1(nullptr),
                 progress_pinned(nullptr), pubkey_count(0), gpu_id(0) {}

    ~FastScan() {
        if(gpu_pubkey_data) cudaFree(gpu_pubkey_data);
        if(gpu_gTableX) cudaFree(gpu_gTableX);
        if(gpu_gTableY) cudaFree(gpu_gTableY);
        if(gpu_found) cudaFree(gpu_found);
        if(gpu_found_type) cudaFree(gpu_found_type);
        if(gpu_found_count) cudaFree(gpu_found_count);
        if(gpu_prefix_index) cudaFree(gpu_prefix_index);
        if(gpu_bitmap) cudaFree(gpu_bitmap);
        if(gpu_bitmap_L1) cudaFree(gpu_bitmap_L1);
        if(gpu_single_target) cudaFree(gpu_single_target);
        if(gpu_single_target_X) cudaFree(gpu_single_target_X);
        if(progress_pinned) cudaFreeHost(progress_pinned);
    }

    void setGPUId(int id) { gpu_id = id; }

    bool loadHashes(const char* filename) {
        cout << "[GPU " << gpu_id << "] Loading pubkey database (mmap): " << filename << "\n";
        try { pubkey_mmap.open_file(filename); } catch(const std::exception& e) { cerr << "ERROR mmap: " << e.what() << "\n"; return false; }
        pubkey_count = pubkey_mmap.length() / 65;
        host_pubkey_ptr = pubkey_mmap.ptr();
        host_pubkey_len = pubkey_mmap.length();
        cout << "[GPU " << gpu_id << "] Pubkeys: " << pubkey_count << "\n";
        cout << "[GPU " << gpu_id << "] File size: " << (pubkey_mmap.length() / (1024*1024)) << " MB (mmap, no RAM copy)\n";
        return loadGTable();
    }

    bool loadSingleAddress(const string& pubkey_hex) {
        cout << "[GPU " << gpu_id << "] Single pubkey mode (no .bin file): " << pubkey_hex << "\n";
        if(pubkey_hex.size() != 130 || pubkey_hex.substr(0,2) != "04") {
            cerr << "ERROR: Invalid uncompressed pubkey (musi byc 130 znakow hex, zaczynac od 04).\n";
            return false;
        }
        uint8_t pub[65];
        for(int i = 0; i < 65; i++) pub[i] = (uint8_t)strtoul(pubkey_hex.substr(i*2, 2).c_str(), nullptr, 16);
        cpu_single_pubkey.assign(pub, pub + 65);
        pubkey_count = 1;
        single_mode = true;
        host_pubkey_ptr = cpu_single_pubkey.data();
        host_pubkey_len = cpu_single_pubkey.size();
        cout << "[GPU " << gpu_id << "] Pubkeys: 1 (in RAM cache, .bin not loaded)\n";
        return loadGTable();
    }

    bool loadGTable() {
        cout << "[GPU " << gpu_id << "] Loading GTable...\n";
        cpu_gTableX = loadFile("gtableX.bin");
        cpu_gTableY = loadFile("gtableY.bin");
        cout << "[GPU " << gpu_id << "]    gtableX: " << cpu_gTableX.size() / (1024*1024) << " MB\n";
        cout << "[GPU " << gpu_id << "]    gtableY: " << cpu_gTableY.size() / (1024*1024) << " MB\n";
        cout << "[GPU " << gpu_id << "] Ready (mmap active)\n";
        return true;
    }

    vector<uint64_t> buildPrefixIndex24() {
        const uint8_t* base = host_pubkey_ptr;
        uint64_t count = pubkey_count;
        vector<uint64_t> index(16777217, 0);
        cout << "[GPU " << gpu_id << "] Building 24-bit prefix index for " << count << " pubkeys...\n";
        cout << "[GPU " << gpu_id << "] Index size: ~" << (index.size() * sizeof(uint64_t)) / (1024*1024) << " MB\n";
        auto start_time = chrono::steady_clock::now();
        auto get_prefix24 = [](const uint8_t* rec) -> uint32_t {
            const uint8_t* p = rec + 1;
            return (uint32_t(p[0]) << 16) | (uint32_t(p[1]) << 8) | uint32_t(p[2]);
        };
        for (uint64_t pos = 0; pos < count; pos++) {
            uint32_t p = get_prefix24(base + pos * 65);
            index[p]++;
            if ((pos & 0x3FFFFFF) == 0 && pos > 0) { cout << "\r   Counting prefixes: " << pos << "/" << count << flush; }
        }
        uint64_t running = 0; uint64_t buckets_found = 0;
        for (uint32_t p = 0; p < 16777216; p++) {
            uint64_t c = index[p]; if (c > 0) buckets_found++;
            index[p] = running; running += c;
        }
        index[16777216] = running;
        auto end_time = chrono::steady_clock::now();
        double seconds = chrono::duration<double>(end_time - start_time).count();
        cout << "\n   Index built: " << buckets_found << "/16777216 prefixes used (rekordow: " << running << ")\n";
        cout << "⏱️  Build time: " << fixed << setprecision(1) << seconds << " s\n";
        return index;
    }

    bool initGPU() {
        cout << "\n[GPU " << gpu_id << "] GPU initialization...\n";
        int deviceCount; cudaError_t devErr = cudaGetDeviceCount(&deviceCount);
        if(deviceCount == 0 || devErr != cudaSuccess) {
            cerr << "ERROR: No GPU or CUDA driver not working!\n";
            cerr << "   Recompile for your card: nvcc -O3 -arch=sm_XX ...\n";
            return false;
        }
        cudaDeviceProp prop; cudaGetDeviceProperties(&prop, gpu_id);
        cout << "[GPU " << gpu_id << "]    GPU: " << prop.name << "\n";
        cout << "[GPU " << gpu_id << "]    VRAM: " << prop.totalGlobalMem / (1024*1024*1024) << " GB\n";
        cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
        cout << "[GPU " << gpu_id << "]    Cache: L1 preferred\n";

        cout << "[GPU " << gpu_id << "] Uploading pubkeys to GPU (" << host_pubkey_len << " B)...\n";
        cudaError_t mallocErr = cudaMalloc(&gpu_pubkey_data, host_pubkey_len);
        if(mallocErr != cudaSuccess) {
            cerr << "ERROR: GPU allocation failed: " << cudaGetErrorString(mallocErr) << "\n";
            return false;
        }
        cudaMemcpy(gpu_pubkey_data, host_pubkey_ptr, host_pubkey_len, cudaMemcpyHostToDevice);

        cout << "[GPU " << gpu_id << "] Uploading GTable to GPU (64 MB)...\n";
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

        if(single_mode) {
            cout << "[GPU " << gpu_id << "] Uploading pubkey target to GPU (65 B)...\n";
            cudaMalloc(&gpu_single_target, 65);
            cudaMemcpy(gpu_single_target, host_pubkey_ptr, 65, cudaMemcpyHostToDevice);
            const uint8_t* xb = host_pubkey_ptr + 1;
            uint64_t tgtX[4];
            for(int w=0; w<4; w++) {
                tgtX[w] = 0;
                for(int b=0; b<8; b++) tgtX[w] = (tgtX[w] << 8) | xb[(3-w)*8 + b];
            }
            cudaMalloc(&gpu_single_target_X, 32);
            cudaMemcpy(gpu_single_target_X, tgtX, 32, cudaMemcpyHostToDevice);
        }

        if(!single_mode) {
            cout << "[GPU " << gpu_id << "] Building and uploading 24-bit prefix index to GPU...\n";
            vector<uint64_t> cpu_prefix_index = buildPrefixIndex24();
            size_t idxBytes = cpu_prefix_index.size() * sizeof(uint64_t);
            cudaError_t allocErr = cudaMalloc(&gpu_prefix_index, idxBytes);
            if(allocErr != cudaSuccess) {
                cerr << "WARNING: Failed to allocate index on GPU (" << idxBytes / (1024*1024) << " MB): " << cudaGetErrorString(allocErr) << " - continuing WITHOUT index (slower fallback binary search)\n";
                gpu_prefix_index = nullptr;
            } else {
                cudaMemcpy(gpu_prefix_index, cpu_prefix_index.data(), idxBytes, cudaMemcpyHostToDevice);
                cout << "[GPU " << gpu_id << "] Index uploaded to GPU (" << idxBytes / (1024*1024) << " MB)\n";
            }
        }

        if(!single_mode) {
            const uint64_t L1_W=1ULL<<21, L2_W=1ULL<<27;
            vector<uint32_t> cl1(L1_W,0), cl2(L2_W,0);
            cout << "[GPU " << gpu_id << "] Building bitmaps...\n";
            for(uint64_t j=0;j<pubkey_count;j++){
                const uint8_t* r=host_pubkey_ptr+j*65;
                uint32_t t=((uint32_t)r[1]<<24)|((uint32_t)r[2]<<16)|((uint32_t)r[3]<<8)|r[4];
                cl2[(t>>5)]|=(1u<<(t&31)); cl1[((t>>6)>>5)]|=(1u<<((t>>6)&31));
            }
            cudaMalloc(&gpu_bitmap_L1,L1_W*4); cudaMemcpy(gpu_bitmap_L1,cl1.data(),L1_W*4,cudaMemcpyHostToDevice);
            cudaMalloc(&gpu_bitmap,L2_W*4); cudaMemcpy(gpu_bitmap,cl2.data(),L2_W*4,cudaMemcpyHostToDevice);
            cout << "[GPU " << gpu_id << "] Bitmaps uploaded\n";
        }

        cout << "[GPU " << gpu_id << "] GPU ready!\n";
        return true;
    }

    static void bn_to_words(const BIGNUM* bn, uint64_t w[4]) {
        unsigned char buf[32] = {0};
        BN_bn2binpad(bn, buf, 32);
        for(int word = 0; word < 4; word++) {
            uint64_t v = 0;
            for(int b = 0; b < 8; b++) v = (v << 8) | buf[(3 - word) * 8 + b];
            w[word] = v;
        }
    }

    // ============================================================
    // scan() - STANDALONE z wieloma rundami
    // ============================================================
    void scan(int start_bit, int end_bit,
              bool resume = false,
              uint64_t resume_round = 0,
              uint64_t resume_launch = 0,
              uint64_t resume_total_found = 0,
              bool split_gpu = false,
              int total_gpus = 1,
              int gpu_index = 0) {

        const int MAX_BIT = 256;
        if(start_bit < 0) start_bit = 0;
        if(start_bit > MAX_BIT) start_bit = MAX_BIT;
        if(end_bit > MAX_BIT) end_bit = MAX_BIT;
        if(end_bit <= start_bit) end_bit = start_bit + 1;

        const uint64_t BLOCK_SIZE = 5000000ULL;
        const uint64_t INITIAL_CHUNKS = 3563ULL;

        #define BLOCKS 8192
        #define THREADS 256
        #define TOTAL_THREADS (BLOCKS * THREADS)
        const uint64_t MIN_THREADS_PER_CHUNK = 32;

        BN_CTX* bnctx = BN_CTX_new();
        BIGNUM *R0 = BN_new(), *R1 = BN_new(), *RLEN = BN_new();
        BIGNUM *two = BN_new(), *bs = BN_new(), *be = BN_new();
        BN_set_word(two, 2);
        BN_set_word(bs, start_bit);
        BN_set_word(be, end_bit);
        BN_exp(R0, two, bs, bnctx);
        BN_exp(R1, two, be, bnctx);
        BN_sub_word(R1, 1);
        cout << "\n[GPU " << gpu_id << "] Range: bit " << start_bit << " -> bit " << end_bit << "\n";
        char* r0_hex = BN_bn2hex(R0); char* r1_hex = BN_bn2hex(R1);
        cout << "[GPU " << gpu_id << "] HEX: " << r0_hex << ":" << r1_hex << "\n";
        OPENSSL_free(r0_hex); OPENSSL_free(r1_hex);
        BN_sub(RLEN, R1, R0);
        BN_add_word(RLEN, 1);

        // ============================================================
        // SPLIT-GPU: jeśli włączone, dzielimy zakres na części
        // ============================================================
        if (split_gpu && total_gpus > 1) {
            BIGNUM* total_range = BN_new();
            BN_copy(total_range, RLEN);
            BIGNUM* gpu_count = BN_new();
            BN_set_word(gpu_count, total_gpus);
            BIGNUM* chunk_size = BN_new();
            BN_div(chunk_size, nullptr, total_range, gpu_count, bnctx);
            if (BN_is_zero(chunk_size)) BN_set_word(chunk_size, 1);

            BIGNUM* my_start = BN_new();
            BIGNUM* my_end = BN_new();
            BIGNUM* gpu_idx_bn = BN_new();
            BN_set_word(gpu_idx_bn, gpu_index);
            BN_mul(my_start, gpu_idx_bn, chunk_size, bnctx);
            BN_add(my_end, my_start, chunk_size);
            if (gpu_index == total_gpus - 1) {
                BN_copy(my_end, R1);
                BN_add_word(my_end, 1);
            }
            // R0 = my_start, R1 = my_end - 1, RLEN = my_end - my_start
            BN_copy(R0, my_start);
            BN_sub(R1, my_end, BN_new()); // R1 = my_end - 1
            BN_sub_word(R1, 1);
            BN_sub(RLEN, my_end, my_start);
            BN_add_word(RLEN, 1);

            cout << "[GPU " << gpu_id << "] SPLIT-GPU: part " << gpu_index+1 << "/" << total_gpus
                 << " range: [" << BN_bn2hex(R0) << " : " << BN_bn2hex(R1) << "]\n";

            BN_free(total_range); BN_free(gpu_count); BN_free(chunk_size);
            BN_free(my_start); BN_free(my_end); BN_free(gpu_idx_bn);
        }

        uint64_t total_found = resume_total_found;
        total_found_global.store(resume_total_found, std::memory_order_relaxed);

        uint64_t round_idx = (resume && resume_round > 0) ? resume_round : 1;
        uint64_t start_launch = resume_launch;

        uint64_t CHUNKS = INITIAL_CHUNKS;
        for (uint64_t r = 1; r < round_idx; r++) {
            CHUNKS *= 2;
        }

        ofstream f("found.txt", ios::app);

        while(true) {
            BIGNUM* bn_chunks = BN_new();
            BN_set_word(bn_chunks, CHUNKS);
            BIGNUM* stride = BN_new();
            BN_div(stride, nullptr, RLEN, bn_chunks, bnctx);
            if(BN_is_zero(stride)) BN_set_word(stride, 1);

            uint64_t effChunks = CHUNKS;
            {
                BIGNUM* pow2 = BN_new(); BN_one(pow2);
                while(BN_cmp(pow2, stride) <= 0) { BN_mul_word(pow2, 2); }
                BN_rshift1(pow2, pow2);
                if(BN_is_zero(pow2)) BN_one(pow2);
                BN_copy(stride, pow2);
                BN_free(pow2);

                BIGNUM* new_chunks = BN_new();
                BN_div(new_chunks, nullptr, RLEN, stride, bnctx);
                if(!BN_is_zero(new_chunks)) {
                    uint64_t new_c = BN_get_word(new_chunks);
                    if(new_c > 0) {
                        if(new_c & 1) new_c--;
                        if(new_c < 2) new_c = 2;
                        effChunks = new_c;
                    }
                }
                BN_free(new_chunks);
            }

            uint64_t effBlockSize;
            {
                BIGNUM* bn_block_size = BN_new(); BN_set_word(bn_block_size, BLOCK_SIZE);
                BIGNUM* eff_block_bn = BN_new();
                if(BN_cmp(stride, bn_block_size) < 0) BN_copy(eff_block_bn, stride);
                else BN_copy(eff_block_bn, bn_block_size);
                if(BN_is_zero(eff_block_bn)) BN_set_word(eff_block_bn, 1);
                effBlockSize = BN_get_word(eff_block_bn);
                BN_free(bn_block_size); BN_free(eff_block_bn);
            }

            BIGNUM* last_start_bn = BN_new();
            BN_copy(last_start_bn, R1);
            BIGNUM* bsz = BN_new(); BN_set_word(bsz, effBlockSize - 1);
            if(BN_cmp(RLEN, bsz) > 0) BN_sub(last_start_bn, R1, bsz);
            else BN_copy(last_start_bn, R0);
            BN_free(bsz);

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

            char* strideStr = BN_bn2dec(stride);
            cout << "\n[GPU " << gpu_id << "] Round " << round_idx << " | Chunks: " << effChunks
                 << " | stride: " << strideStr << " | block_size (eff): " << effBlockSize
                 << " (max: " << BLOCK_SIZE << ")"
                 << (effBlockSize < BLOCK_SIZE ? " | [denser coverage - no overlap]" : "")
                 << "\n";
            OPENSSL_free(strideStr);

            uint64_t threads_per_chunk = (uint64_t)TOTAL_THREADS / effChunks;
            if(threads_per_chunk < MIN_THREADS_PER_CHUNK) threads_per_chunk = MIN_THREADS_PER_CHUNK;
            if(threads_per_chunk > effBlockSize) threads_per_chunk = (effBlockSize > 0) ? effBlockSize : 1;
            uint64_t sub_block_size = (effBlockSize + threads_per_chunk - 1) / threads_per_chunk;
            if(sub_block_size < 1) sub_block_size = 1;

            uint64_t chunksToRun = effChunks;
            uint64_t grid_mult = (round_idx == 1) ? 1 : 2;
            uint64_t grid_off  = (round_idx == 1) ? 0 : 1;

            // OPTYMALIZACJA DEDUP: tylko potrzebne launch'e
            uint64_t effective_chunks = chunksToRun / grid_mult;
            uint64_t effective_work_units = effective_chunks * threads_per_chunk;
            uint64_t numLaunches = (effective_work_units + TOTAL_THREADS - 1) / TOTAL_THREADS;

            cout << "[GPU " << gpu_id << "]    [Parallelism: " << threads_per_chunk << " threads/chunk, "
                 << sub_block_size << " keys/thread sequential, "
                 << "effective launches: " << numLaunches << "]\n";

            auto start_time = chrono::steady_clock::now();

            const auto PROGRESS_SAVE_INTERVAL = chrono::minutes(10);
            auto last_progress_save = chrono::steady_clock::now() - PROGRESS_SAVE_INTERVAL;

            for(uint64_t launch = start_launch; launch < numLaunches; launch++) {
                *progress_pinned = 0;

                fastscan_kernel<<<BLOCKS, THREADS>>>(
                    gpu_pubkey_data,
                    pubkey_count,
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
                    gpu_bitmap,
                    gpu_bitmap_L1,
                    gpu_single_target,
                    gpu_single_target_X,
                    grid_mult,
                    grid_off
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
                    double elapsed = chrono::duration<double>(now - start_time).count();
                    cout << "\r[GPU " << gpu_id << "]    Batch: " << launch << "/" << numLaunches
                         << " | elapsed: " << fixed << setprecision(0) << elapsed << "s"
                         << " | found: " << total_found_global.load(std::memory_order_relaxed)
                         << std::flush;
                } while(qerr != cudaSuccess);

                unsigned int count = 0;
                cudaMemcpy(&count, gpu_found_count, sizeof(unsigned int), cudaMemcpyDeviceToHost);

                if(count > 0) {
                    if(count > MAX_FOUND_KEYS) count = MAX_FOUND_KEYS;
                    cout << "\n[GPU " << gpu_id << "] FOUND " << count << " HIT(S)!\n";
                    total_found += count;
                    total_found_global.fetch_add(count, std::memory_order_relaxed);

                    cudaMemcpy(cpu_found.data(), gpu_found, count * 32, cudaMemcpyDeviceToHost);
                    cudaMemcpy(cpu_found_type.data(), gpu_found_type, count, cudaMemcpyDeviceToHost);

                    for(unsigned int i = 0; i < count; i++) {
                        unsigned char* key = cpu_found.data() + i * 32;
                        unsigned char ftype = cpu_found_type[i];

                        {
                            BIGNUM* bn_key = BN_new();
                            BIGNUM* bn_lambda = BN_new();
                            BIGNUM* bn_n = BN_new();
                            BIGNUM* bn_result = BN_new();
                            BN_CTX* bn_ctx = BN_CTX_new();
                            BN_bin2bn(key, 32, bn_key);
                            BN_hex2bn(&bn_n, SECP256K1_ORDER_N_HEX);

                            if (ftype >= 3 && ftype <= 6) {
                                BN_hex2bn(&bn_lambda,
                                    (ftype == 3 || ftype == 4) ? LAMBDA_HEX : LAMBDA2_HEX);
                                BN_mod_mul(bn_result, bn_key, bn_lambda, bn_n, bn_ctx);
                            } else {
                                BN_copy(bn_result, bn_key);
                            }

                            if (ftype == 2 || ftype == 4 || ftype == 6) {
                                BIGNUM* bn_tmp = BN_new();
                                BN_sub(bn_tmp, bn_n, bn_result);
                                BN_copy(bn_result, bn_tmp);
                                BN_free(bn_tmp);
                            }

                            int len = BN_num_bytes(bn_result);
                            unsigned char tmpkey[32] = {0};
                            BN_bn2bin(bn_result, tmpkey + (32 - len));
                            memcpy(key, tmpkey, 32);

                            BN_free(bn_key); BN_free(bn_lambda); BN_free(bn_n);
                            BN_free(bn_result); BN_CTX_free(bn_ctx);
                        }

                        bool isUncompressed = (ftype != 0);
                        string addr = isUncompressed ? keyToAddressUncompressed(key) : keyToAddressCompressed(key);
                        const char* typeLabel = isUncompressed ? "UNCOMPRESSED" : "COMPRESSED";
                        const char* variantLabel = "";
                        if (ftype == 1) variantLabel = " (k)";
                        else if (ftype == 2) variantLabel = " (n-k)";
                        else if (ftype == 3) variantLabel = " (λ·k)";
                        else if (ftype == 4) variantLabel = " (n-λ·k)";
                        else if (ftype == 5) variantLabel = " (λ²·k)";
                        else if (ftype == 6) variantLabel = " (n-λ²·k)";

                        cout << "[GPU " << gpu_id << "]    KEY: ";
                        for(int j = 0; j < 32; j++) cout << hex << setw(2) << setfill('0') << (int)key[j];
                        cout << dec << "\n";
                        cout << "[GPU " << gpu_id << "]       TYPE: " << typeLabel << variantLabel << "\n";
                        cout << "[GPU " << gpu_id << "]       ADDR: " << addr << "\n";

                        f << "KEY: ";
                        for(int j = 0; j < 32; j++) f << hex << setw(2) << setfill('0') << (int)key[j];
                        f << dec << "\n";
                        f << "TYPE: " << typeLabel << "\n";
                        f << "ADDR: " << addr << "\n";
                        f << "---\n";
                        f.flush();
                    }

                    unsigned int zero = 0;
                    cudaMemcpy(gpu_found_count, &zero, sizeof(unsigned int), cudaMemcpyHostToDevice);
                }

                auto nowSave = chrono::steady_clock::now();
                if(nowSave - last_progress_save >= PROGRESS_SAVE_INTERVAL) {
                    save_progress(round_idx, start_bit, end_bit, launch + 1,
                                  total_found_global.load(std::memory_order_relaxed), gpu_id);
                    last_progress_save = nowSave;
                }
            }

            auto end_time = chrono::steady_clock::now();
            double elapsed = chrono::duration<double>(end_time - start_time).count();
            uint64_t unique_chunks = chunksToRun / grid_mult;
            double speed = (elapsed > 0) ? ((double)(unique_chunks) * (double)effBlockSize) / elapsed / 1e9 : 0.0;

            cout << "\n[GPU " << gpu_id << "] Round " << round_idx << " completed! Chunks done: "
                 << chunksToRun << "/" << effChunks << " (unique: " << unique_chunks << ")\n";
            cout << "[GPU " << gpu_id << "]    Time: " << elapsed << " s\n";
            cout << "[GPU " << gpu_id << "]    Speed: " << fixed << setprecision(1) << speed << " Gadd/s"
                 << " | eff: " << speed * (USE_ENDO ? 6 : 2) << " Gkeys/s\n";
            cout << "[GPU " << gpu_id << "]    Total found: " << total_found_global.load(std::memory_order_relaxed) << " hits\n\n";

            cudaFree(d_R0); cudaFree(d_stride); cudaFree(d_last);
            BN_free(bn_chunks); BN_free(stride); BN_free(last_start_bn);

            start_launch = 0;
            round_idx++;
            CHUNKS *= 2;
            save_progress(round_idx, start_bit, end_bit, 0,
                          total_found_global.load(std::memory_order_relaxed), gpu_id);
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
        cout << "FASTSCAN GPU - SKANER 253-256 (STANDALONE, no pool, multi-round)\n";
        cout << "================================================================\n\n";
        cout << "Usage: ./fastscan_253_256 <pubkeys.bin | PUBKEY_HEX> start_bit end_bit [--gpu=N|all] [--resume] [--split-gpu]\n\n";
        cout << "  <pubkeys.bin> - database file (65-byte 04||X||Y, sorted by X) OR\n";
        cout << "  <PUBKEY_HEX>  - single uncompressed pubkey (130 hex chars, starts with 04)\n\n";
        cout << "Options:\n";
        cout << "  --gpu=N|all   - select GPU(s) (e.g. --gpu=0, --gpu=all)\n";
        cout << "  --resume      - resume from progress.txt\n";
        cout << "  --split-gpu   - split the range equally between all GPUs (only with --gpu=all)\n\n";
        cout << "Examples:\n";
        cout << "  ./fastscan_253_256 04... 253 256 --gpu=all\n";
        cout << "  ./fastscan_253_256 pubkeys.bin 253 256 --resume\n";
        cout << "  ./fastscan_253_256 pubkeys.bin 253 256 --gpu=all --split-gpu\n";
        return 1;
    }

    int start_bit = 0, end_bit = 0;
    bool resume = false;
    bool split_gpu = false;
    int gpu_device = 0;
    bool use_all_gpus = false;

    for(int i = 1; i < argc; i++) {
        string a = argv[i];
        if(a == "--resume") {
            resume = true;
        } else if(a == "--split-gpu") {
            split_gpu = true;
        } else if(a == "--gpu=all" || a == "--gpu=-1") {
            use_all_gpus = true;
            gpu_device = -1;
        } else if(a.rfind("--gpu=", 0) == 0) {
            gpu_device = stoi(a.substr(6));
            use_all_gpus = false;
        } else if(i == 1) {
            continue;
        } else if(i == 2) {
            start_bit = stoi(a);
        } else if(i == 3) {
            end_bit = stoi(a);
        }
    }

    string addr_source = argv[1];
    bool is_file;
    struct stat st;
    is_file = (stat(argv[1], &st) == 0 && S_ISREG(st.st_mode));

    int num_gpus = 1;
    if (use_all_gpus) {
        cudaGetDeviceCount(&num_gpus);
        if (num_gpus < 1) num_gpus = 1;
        cout << "\nMULTI-GPU MODE: " << num_gpus << " GPU(s) detected\n";
        if (split_gpu) {
            cout << "SPLIT-GPU: Range will be divided equally among " << num_gpus << " GPUs\n";
        } else {
            cout << "WARNING: Each GPU will scan the FULL range independently (no split).\n";
            cout << "Use --split-gpu to divide work between GPUs.\n";
        }
    }

    if (num_gpus == 1) {
        FastScan scanner;
        scanner.setGPUId(0);
        bool ok = is_file ? scanner.loadHashes(argv[1]) : scanner.loadSingleAddress(addr_source);
        if(!ok) return 1;
        cudaSetDevice(gpu_device >= 0 ? gpu_device : 0);
        if(!scanner.initGPU()) return 1;

        uint64_t resume_round = 0, resume_launch = 0, resume_found = 0;
        int sb=0, eb=0;
        if(resume) {
            if(load_progress(resume_round, sb, eb, resume_launch, resume_found, 0)) {
                start_bit = sb;
                end_bit = eb;
                cout << "RESUME from progress.txt: round #" << resume_round
                     << ", launch " << resume_launch << ", found " << resume_found << "\n";
            } else {
                cout << "WARNING: --resume specified but progress.txt not found or invalid. Starting from scratch.\n";
                resume = false;
                resume_round = 0;
                resume_launch = 0;
                resume_found = 0;
            }
        }

        scanner.scan(start_bit, end_bit, resume, resume_round, resume_launch, resume_found,
                     split_gpu, num_gpus, 0);
    } else {
        cout << "\n";
        cout << "╔═══════════════════════════════════════════════════════════════╗\n";
        if (split_gpu) {
            cout << "║  SPLIT-GPU MODE: Range divided equally between GPUs       ║\n";
        } else {
            cout << "║  MULTI-GPU MODE: Each GPU scans the FULL range            ║\n";
            cout << "║  (use --split-gpu to divide work)                        ║\n";
        }
        cout << "╚═══════════════════════════════════════════════════════════════╝\n\n";

        vector<thread> threads;
        atomic<int> gpu_errors{0};

        for (int g = 0; g < num_gpus; g++) {
            threads.emplace_back([&, g, addr_source, is_file, start_bit, end_bit, resume, split_gpu, num_gpus]() {
                FastScan scanner;
                scanner.setGPUId(g);
                cout << "\n[GPU " << g << "] Initializing...\n";
                bool ok = is_file ? scanner.loadHashes(addr_source.c_str()) : scanner.loadSingleAddress(addr_source);
                if(!ok) { gpu_errors++; return; }
                cudaSetDevice(g);
                if(!scanner.initGPU()) { gpu_errors++; return; }

                uint64_t resume_round = 0, resume_launch = 0, resume_found = 0;
                int sb=0, eb=0;
                if(resume) {
                    if(load_progress(resume_round, sb, eb, resume_launch, resume_found, g)) {
                        cout << "[GPU " << g << "] RESUME: round #" << resume_round
                             << ", launch " << resume_launch << "\n";
                    }
                }
                scanner.scan(start_bit, end_bit, resume, resume_round, resume_launch, resume_found,
                             split_gpu, num_gpus, g);
                cout << "[GPU " << g << "] Finished.\n";
            });
        }

        for(auto& t : threads) t.join();
        if(gpu_errors > 0) cerr << "WARNING: " << gpu_errors << " GPU(s) failed to initialize\n";
    }

    return 0;
}