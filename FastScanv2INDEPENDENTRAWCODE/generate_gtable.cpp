// ============================================================
// generate_gtable.cpp - NAPRAWIONY GENERATOR!
// ============================================================
// PROBLEM w poprzedniej wersji:
//   Dla chunku C i cyfry D generator liczyl scalar liniowo jako
//   (C*65536 + D), co jest poprawne TYLKO dla chunku 0.
//   Dla chunku >=1 punkt MUSI byc rowny D * 2^(16*C) * G,
//   a nie (C*65536+D) * G !
//
// Ta wersja buduje dla kazdego (chunk, digit) 32-bajtowy scalar,
// ktory ma cyfre "digit" (1..65535) wstawiona dokladnie w to samo
// miejsce bajtowe, z ktorego main.cu odczytuje 16-bitowe kawalki
// klucza prywatnego (patrz dekompozycja priv_256 -> priv_chunks
// w main.cu). Dzieki temu kazdy punkt liczony jest przez
// secp256k1_ec_pubkey_create (peny, zweryfikowany scalar mult),
// wiec wynik jest matematycznie gwarantowany poprawny.
//
// Konwencja bajtowa (zgodna z main.cu):
//   chunk 0  -> bajty [30,31] (najmniej znaczace 16 bitow)
//   chunk 1  -> bajty [28,29]
//   ...
//   chunk 15 -> bajty [0,1]  (najbardziej znaczace 16 bitow)
//   scalar = digit * 2^(16*chunk)
// ============================================================

#include <secp256k1.h>
#include <fstream>
#include <vector>
#include <iostream>
#include <cstring>
#include <iomanip>
#include <chrono>

#define NUM_CHUNKS 16
#define NUM_VALUES 65536
#define POINT_SIZE 32

// ============================================================
// KONWERSJA LITTLE-ENDIAN DLA GPU
// ============================================================
inline void store64_le(uint8_t* dest, uint64_t val) {
    dest[0] = (val >> 0) & 0xFF;
    dest[1] = (val >> 8) & 0xFF;
    dest[2] = (val >> 16) & 0xFF;
    dest[3] = (val >> 24) & 0xFF;
    dest[4] = (val >> 32) & 0xFF;
    dest[5] = (val >> 40) & 0xFF;
    dest[6] = (val >> 48) & 0xFF;
    dest[7] = (val >> 56) & 0xFF;
}

// ============================================================
// Zbuduj 32-bajtowy (big-endian) scalar dla danego (chunk, digit)
// digit = 1..65535 (0 nigdy nie jest uzywane - patrz main.cu:
// "if (privKey[chunk] > 0)")
// ============================================================
inline void build_chunk_scalar(unsigned char priv[32], int chunk, uint32_t digit) {
    memset(priv, 0, 32);
    int hi_off = 30 - 2 * chunk;
    int lo_off = 31 - 2 * chunk;
    priv[hi_off] = (digit >> 8) & 0xFF;
    priv[lo_off] = digit & 0xFF;
}


// ============================================================
// GENERUJ GTABLE DLA UNCOMPRESSED
// GTable[0] = 1*G, GTable[1] = 2*G, ..., GTable[i] = (i+1)*G
// ============================================================
bool generate_uncompressed(secp256k1_context* ctx) {
    std::cout << "\n========================================\n";
    std::cout << "📦 GENEROWANIE UNCOMPRESSED GTABLE\n";
    std::cout << "   GTable[0] = 1*G, GTable[1] = 2*G, ...\n";
    std::cout << "========================================\n";
    
    size_t total_size = NUM_CHUNKS * NUM_VALUES * POINT_SIZE;
    std::vector<uint8_t> gTableX(total_size, 0);
    std::vector<uint8_t> gTableY(total_size, 0);
    
    auto start = std::chrono::steady_clock::now();
    uint64_t total = 0;
    uint64_t errors = 0;
    
    for(int chunk = 0; chunk < NUM_CHUNKS; chunk++) {
        for(int val = 0; val < NUM_VALUES; val++) {
            uint64_t table_index = (uint64_t)chunk * NUM_VALUES + val;
            int offset = table_index * POINT_SIZE;
            
            // ============================================================
            // NAPRAWIONE: scalar = digit * 2^(16*chunk)
            // digit = val + 1 (bo val idzie od 0, a przechowujemy tylko
            // wartosci digit=1..65535 - digit=0 nigdy nie jest uzywane
            // w main.cu, bo "if (privKey[chunk] > 0)")
            // GTable[chunk=0][digit] = digit * G
            // GTable[chunk=1][digit] = digit * 65536 * G
            // GTable[chunk=c][digit] = digit * 2^(16*c) * G
            // ============================================================
            uint32_t digit = (uint32_t)(val + 1);
            
            unsigned char priv[32];
            build_chunk_scalar(priv, chunk, digit);
            
            secp256k1_pubkey pubkey;
            if(secp256k1_ec_pubkey_create(ctx, &pubkey, priv) != 1) {
                errors++;
                // Wpisz INF jako fallback
                memset(&gTableX[offset], 0, POINT_SIZE);
                memset(&gTableY[offset], 0, POINT_SIZE);
                total++;
                continue;
            }
            
            // UNCOMPRESSED: 65 bajtów
            unsigned char pub[65];
            size_t pub_len = 65;
            secp256k1_ec_pubkey_serialize(ctx, pub, &pub_len, &pubkey, SECP256K1_EC_UNCOMPRESSED);
            
            // ============================================================
            // WAZNA POPRAWKA KOLEJNOSCI SLOW (word order)!
            // Cala arytmetyka bignum w GPUMath.h (_ModMult, _PointAddSecp256k1,
            // _ModInv) zaklada konwencje index[0] = NAJMNIEJ znaczace 64 bity
            // (LSB word), index[3] = najbardziej znaczace (MSB word) - dokladnie
            // tak jak oryginalna klasa Int (Int::bits64[0] = LSB), z ktorej
            // ta arytmetyka zostala przeniesiona z VanitySearch.
            // pub[1..32] to X w formacie big-endian (pub[1] = MSB bajt).
            // Zatem word j=0 (offset 0, LSB) MUSI pochodzic z OSTATNICH 8
            // bajtow X (pub[25..32]), a word j=3 (MSB) z PIERWSZYCH 8 bajtow
            // (pub[1..8]) - czyli odwrotna kolejnosc niz poprzednio!
            // ============================================================
            for(int j = 0; j < 4; j++) {
                uint64_t val64 = 0;
                int srcOff = 1 + (3 - j) * 8;
                for(int b = 0; b < 8; b++) {
                    val64 = (val64 << 8) | pub[srcOff + b];
                }
                store64_le(&gTableX[offset + j * 8], val64);
            }
            
            // Zapis Y (ta sama poprawka kolejnosci slow co dla X)
            for(int j = 0; j < 4; j++) {
                uint64_t val64 = 0;
                int srcOff = 33 + (3 - j) * 8;
                for(int b = 0; b < 8; b++) {
                    val64 = (val64 << 8) | pub[srcOff + b];
                }
                store64_le(&gTableY[offset + j * 8], val64);
            }
            
            total++;
        }
        
        if(chunk % 4 == 0 || chunk == NUM_CHUNKS - 1) {
            auto now = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - start).count();
            std::cout << "\r   Chunk " << chunk + 1 << "/" << NUM_CHUNKS
                      << " | " << total << " punktów"
                      << " | " << std::fixed << std::setprecision(0) 
                      << (total / elapsed) << " pkt/s   " << std::flush;
        }
    }
    
    std::cout << "\n💾 Zapis UNCOMPRESSED plików...\n";
    
    std::ofstream fx("gtableX.bin", std::ios::binary);
    fx.write((char*)gTableX.data(), gTableX.size());
    fx.close();
    std::cout << "   ✅ gtableX.bin (" << gTableX.size() / (1024*1024) << " MB)\n";
    
    std::ofstream fy("gtableY.bin", std::ios::binary);
    fy.write((char*)gTableY.data(), gTableY.size());
    fy.close();
    std::cout << "   ✅ gtableY.bin (" << gTableY.size() / (1024*1024) << " MB)\n";
    
    auto end = std::chrono::steady_clock::now();
    double seconds = std::chrono::duration<double>(end - start).count();
    
    std::cout << "   ✅ UNCOMPRESSED wygenerowane w " << std::fixed 
              << std::setprecision(1) << seconds << " s\n";
    std::cout << "   📊 Punkty: " << total << ", Błędy: " << errors << "\n";
    
    // ============================================================
    // WERYFIKACJA INDEX 0 = GENERATOR G
    // ============================================================
    uint64_t x[4];
    memcpy(x, gTableX.data(), 32);  // offset 0 = index 0
    
    std::cout << "\n🔍 Weryfikacja INDEX 0 (powinien być 1*G = GENERATOR):\n";
    std::cout << "   X: ";
    for(int i = 0; i < 4; i++) {
        std::cout << std::hex << std::setw(16) << std::setfill('0') << x[i] << " ";
    }
    std::cout << std::dec << "\n";
    
    // UWAGA: kolejnosc slow jest teraz LSB-first (index[0]=najmniej znaczace),
    // wiec oczekiwane słowa X generatora G sa w odwrotnej kolejnosci niz
    // w oryginalnym zapisie big-endian (79be667e...16f81798)
    uint64_t generator_x[4] = {
        0x59F2815B16F81798ULL,
        0x029BFCDB2DCE28D9ULL,
        0x55A06295CE870B07ULL,
        0x79BE667EF9DCBBACULL
    };
    
    bool match = true;
    for(int i = 0; i < 4; i++) {
        if(x[i] != generator_x[i]) match = false;
    }
    
    if(match) {
        std::cout << "   ✅ INDEX 0 = GENERATOR G (poprawnie!)\n";
    } else {
        std::cout << "   ❌ INDEX 0 NIE JEST GENERATOREM!\n";
    }
    
    // Weryfikacja INDEX 1 = 2*G
    memcpy(x, gTableX.data() + 32, 32);
    std::cout << "\n🔍 Weryfikacja INDEX 1 (powinien być 2*G):\n";
    std::cout << "   X: ";
    for(int i = 0; i < 4; i++) {
        std::cout << std::hex << std::setw(16) << std::setfill('0') << x[i] << " ";
    }
    std::cout << std::dec << "\n";
    
    return true;
}

// ============================================================
// GENERUJ GTABLE DLA COMPRESSED
// GTableX[0] = X z 1*G, GTableY[0] = parity 1*G
// ============================================================
bool generate_compressed(secp256k1_context* ctx) {
    std::cout << "\n========================================\n";
    std::cout << "📦 GENEROWANIE COMPRESSED GTABLE\n";
    std::cout << "   GTableX[0] = X(1*G), GTableY[0] = parity\n";
    std::cout << "========================================\n";
    
    size_t total_size = NUM_CHUNKS * NUM_VALUES * POINT_SIZE;
    std::vector<uint8_t> gTableX(total_size, 0);
    std::vector<uint8_t> gTableY(total_size, 0);
    
    auto start = std::chrono::steady_clock::now();
    uint64_t total = 0;
    uint64_t errors = 0;
    
    for(int chunk = 0; chunk < NUM_CHUNKS; chunk++) {
        for(int val = 0; val < NUM_VALUES; val++) {
            uint64_t table_index = (uint64_t)chunk * NUM_VALUES + val;
            int offset = table_index * POINT_SIZE;
            
            // NAPRAWIONE: scalar = digit * 2^(16*chunk) (patrz komentarz wyzej)
            uint32_t digit = (uint32_t)(val + 1);
            
            unsigned char priv[32];
            build_chunk_scalar(priv, chunk, digit);
            
            secp256k1_pubkey pubkey;
            if(secp256k1_ec_pubkey_create(ctx, &pubkey, priv) != 1) {
                errors++;
                memset(&gTableX[offset], 0, POINT_SIZE);
                gTableY[offset] = 0;
                total++;
                continue;
            }
            
            // COMPRESSED: 33 bajty
            unsigned char pub_comp[33];
            size_t pub_len = 33;
            secp256k1_ec_pubkey_serialize(ctx, pub_comp, &pub_len, &pubkey, SECP256K1_EC_COMPRESSED);
            
            // Zapis X (ta sama poprawka kolejnosci slow co dla UNCOMPRESSED)
            for(int j = 0; j < 4; j++) {
                uint64_t val64 = 0;
                int srcOff = 1 + (3 - j) * 8;
                for(int b = 0; b < 8; b++) {
                    val64 = (val64 << 8) | pub_comp[srcOff + b];
                }
                store64_le(&gTableX[offset + j * 8], val64);
            }
            
            // Zapis parity w pierwszym bajcie Y
            gTableY[offset] = pub_comp[0] & 1;
            
            total++;
        }
        
        if(chunk % 4 == 0 || chunk == NUM_CHUNKS - 1) {
            auto now = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - start).count();
            std::cout << "\r   Chunk " << chunk + 1 << "/" << NUM_CHUNKS
                      << " | " << total << " punktów"
                      << " | " << std::fixed << std::setprecision(0) 
                      << (total / elapsed) << " pkt/s   " << std::flush;
        }
    }
    
    std::cout << "\n💾 Zapis COMPRESSED plików...\n";
    
    std::ofstream fx("gtable_compX.bin", std::ios::binary);
    fx.write((char*)gTableX.data(), gTableX.size());
    fx.close();
    std::cout << "   ✅ gtable_compX.bin (" << gTableX.size() / (1024*1024) << " MB)\n";
    
    std::ofstream fy("gtable_compY.bin", std::ios::binary);
    fy.write((char*)gTableY.data(), gTableY.size());
    fy.close();
    std::cout << "   ✅ gtable_compY.bin (" << gTableY.size() / (1024*1024) << " MB)\n";
    
    auto end = std::chrono::steady_clock::now();
    double seconds = std::chrono::duration<double>(end - start).count();
    
    std::cout << "   ✅ COMPRESSED wygenerowane w " << std::fixed 
              << std::setprecision(1) << seconds << " s\n";
    std::cout << "   📊 Punkty: " << total << ", Błędy: " << errors << "\n";
    
    return true;
}

// ============================================================
// MAIN
// ============================================================
int main() {
    std::cout << "========================================================\n";
    std::cout << "🚀 GENERATOR GTABLE - POPRAWIONY!\n";
    std::cout << "========================================================\n";
    std::cout << "GTable[0] = 1*G, GTable[1] = 2*G, ...\n";
    std::cout << "Kompatybilne z: (privKey-1) w _PointMultiSecp256k1\n";
    std::cout << "========================================================\n";
    
    secp256k1_context* ctx = secp256k1_context_create(
        SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY
    );
    
    if (!ctx) {
        std::cerr << "❌ Nie można utworzyć kontekstu secp256k1!\n";
        return 1;
    }
    
    std::cout << "\n🔥 GENEROWANIE UNCOMPRESSED GTABLE...\n";
    if(!generate_uncompressed(ctx)) {
        std::cerr << "❌ Błąd generowania UNCOMPRESSED!\n";
        secp256k1_context_destroy(ctx);
        return 1;
    }
    
    std::cout << "\n🔥 GENEROWANIE COMPRESSED GTABLE...\n";
    if(!generate_compressed(ctx)) {
        std::cerr << "❌ Błąd generowania COMPRESSED!\n";
        secp256k1_context_destroy(ctx);
        return 1;
    }
    
    std::cout << "\n========================================================\n";
    std::cout << "✅ WSZYSTKIE GTABLE WYGENEROWANE!\n";
    std::cout << "========================================================\n";
    std::cout << "📁 UNCOMPRESSED: gtableX.bin, gtableY.bin\n";
    std::cout << "📁 COMPRESSED:   gtable_compX.bin, gtable_compY.bin\n";
    std::cout << "========================================================\n";
    
    secp256k1_context_destroy(ctx);
    return 0;
}