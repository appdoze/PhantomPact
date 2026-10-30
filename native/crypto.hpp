// SHA-256, HMAC, PBKDF2 and scrypt for the relay's optional Secret (see Auth in relay.hpp). Same results as Python's
// hashlib: the test suite runs this relay against the Python one with a Secret set.
#pragma once
#include <array>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace crypto {

class Sha256 {
public:
    Sha256() { reset(); }

    void reset() {
        static const uint32_t init[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                         0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
        std::memcpy(h_, init, sizeof h_);
        length_ = 0;
        used_ = 0;
    }

    void update(const void* data, size_t size) {
        auto p = static_cast<const uint8_t*>(data);
        length_ += size;
        while (size > 0) {
            size_t take = 64 - used_;
            if (take > size) take = size;
            std::memcpy(block_ + used_, p, take);
            used_ += take;
            p += take;
            size -= take;
            if (used_ == 64) {
                compress(block_);
                used_ = 0;
            }
        }
    }

    std::array<uint8_t, 32> finish() {
        uint64_t bits = length_ * 8;
        uint8_t pad = 0x80;
        update(&pad, 1);
        pad = 0;
        while (used_ != 56) update(&pad, 1);
        uint8_t len[8];
        for (int i = 0; i < 8; i++) len[i] = static_cast<uint8_t>(bits >> (56 - 8 * i));
        update(len, 8);
        std::array<uint8_t, 32> out;
        for (int i = 0; i < 8; i++)
            for (int j = 0; j < 4; j++) out[i * 4 + j] = static_cast<uint8_t>(h_[i] >> (24 - 8 * j));
        return out;
    }

private:
    static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

    void compress(const uint8_t* b) {
        static const uint32_t k[64] = {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = (uint32_t(b[i * 4]) << 24) | (uint32_t(b[i * 4 + 1]) << 16) | (uint32_t(b[i * 4 + 2]) << 8) |
                   uint32_t(b[i * 4 + 3]);
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h_[0], bb = h_[1], c = h_[2], d = h_[3], e = h_[4], f = h_[5], g = h_[6], h = h_[7];
        for (int i = 0; i < 64; i++) {
            uint32_t t1 = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
            uint32_t t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & bb) ^ (a & c) ^ (bb & c));
            h = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = bb;
            bb = a;
            a = t1 + t2;
        }
        h_[0] += a;
        h_[1] += bb;
        h_[2] += c;
        h_[3] += d;
        h_[4] += e;
        h_[5] += f;
        h_[6] += g;
        h_[7] += h;
    }

    uint32_t h_[8];
    uint8_t block_[64];
    uint64_t length_;
    size_t used_;
};

inline std::string hmac_sha256(const std::string& key, const std::string& message) {
    uint8_t k[64] = {};
    if (key.size() > 64) {
        Sha256 s;
        s.update(key.data(), key.size());
        auto d = s.finish();
        std::memcpy(k, d.data(), d.size());
    } else {
        std::memcpy(k, key.data(), key.size());
    }
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; i++) {
        ipad[i] = k[i] ^ 0x36;
        opad[i] = k[i] ^ 0x5c;
    }
    Sha256 inner;
    inner.update(ipad, 64);
    inner.update(message.data(), message.size());
    auto id = inner.finish();
    Sha256 outer;
    outer.update(opad, 64);
    outer.update(id.data(), id.size());
    auto od = outer.finish();
    return std::string(reinterpret_cast<const char*>(od.data()), od.size());
}

inline std::string pbkdf2_sha256_one_round(const std::string& password, const std::string& salt, size_t length) {
    std::string out;
    for (uint32_t block = 1; out.size() < length; block++) {
        std::string msg = salt;
        for (int i = 3; i >= 0; i--) msg.push_back(static_cast<char>(block >> (8 * i)));
        out += hmac_sha256(password, msg);
    }
    out.resize(length);
    return out;
}

inline void salsa20_8(uint32_t b[16]) {
    uint32_t x[16];
    std::memcpy(x, b, sizeof x);
    auto r = [](uint32_t v, int n) { return (v << n) | (v >> (32 - n)); };
    for (int i = 0; i < 8; i += 2) {
        x[4] ^= r(x[0] + x[12], 7);
        x[8] ^= r(x[4] + x[0], 9);
        x[12] ^= r(x[8] + x[4], 13);
        x[0] ^= r(x[12] + x[8], 18);
        x[9] ^= r(x[5] + x[1], 7);
        x[13] ^= r(x[9] + x[5], 9);
        x[1] ^= r(x[13] + x[9], 13);
        x[5] ^= r(x[1] + x[13], 18);
        x[14] ^= r(x[10] + x[6], 7);
        x[2] ^= r(x[14] + x[10], 9);
        x[6] ^= r(x[2] + x[14], 13);
        x[10] ^= r(x[6] + x[2], 18);
        x[3] ^= r(x[15] + x[11], 7);
        x[7] ^= r(x[3] + x[15], 9);
        x[11] ^= r(x[7] + x[3], 13);
        x[15] ^= r(x[11] + x[7], 18);
        x[1] ^= r(x[0] + x[3], 7);
        x[2] ^= r(x[1] + x[0], 9);
        x[3] ^= r(x[2] + x[1], 13);
        x[0] ^= r(x[3] + x[2], 18);
        x[6] ^= r(x[5] + x[4], 7);
        x[7] ^= r(x[6] + x[5], 9);
        x[4] ^= r(x[7] + x[6], 13);
        x[5] ^= r(x[4] + x[7], 18);
        x[11] ^= r(x[10] + x[9], 7);
        x[8] ^= r(x[11] + x[10], 9);
        x[9] ^= r(x[8] + x[11], 13);
        x[10] ^= r(x[9] + x[8], 18);
        x[12] ^= r(x[15] + x[14], 7);
        x[13] ^= r(x[12] + x[15], 9);
        x[14] ^= r(x[13] + x[12], 13);
        x[15] ^= r(x[14] + x[13], 18);
    }
    for (int i = 0; i < 16; i++) b[i] += x[i];
}

// scrypt with p = 1, as the relay uses it.
inline std::string scrypt(const std::string& password, const std::string& salt, size_t n, size_t r, size_t length) {
    const size_t words = 32 * r;    // 128 * r bytes
    std::string b = pbkdf2_sha256_one_round(password, salt, 128 * r);
    std::vector<uint32_t> x(words), y(words), v(words * n);
    std::memcpy(x.data(), b.data(), 128 * r);

    auto block_mix = [&](std::vector<uint32_t>& in, std::vector<uint32_t>& out) {
        uint32_t t[16];
        std::memcpy(t, &in[(2 * r - 1) * 16], sizeof t);
        for (size_t i = 0; i < 2 * r; i++) {
            for (int j = 0; j < 16; j++) t[j] ^= in[i * 16 + j];
            salsa20_8(t);
            std::memcpy(&out[(i / 2 + (i & 1) * r) * 16], t, sizeof t);
        }
    };

    for (size_t i = 0; i < n; i++) {
        std::memcpy(&v[i * words], x.data(), words * 4);
        block_mix(x, y);
        x.swap(y);
    }
    for (size_t i = 0; i < n; i++) {
        size_t j = x[(2 * r - 1) * 16] & (n - 1);
        for (size_t k = 0; k < words; k++) x[k] ^= v[j * words + k];
        block_mix(x, y);
        x.swap(y);
    }
    std::string mixed(reinterpret_cast<const char*>(x.data()), words * 4);
    return pbkdf2_sha256_one_round(password, mixed, length);
}

}  // namespace crypto
