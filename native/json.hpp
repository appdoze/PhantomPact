// The small part of JSON the relay's packets use. Parsing never throws: a packet from the network is untrusted, so
// anything malformed (or nested deeper than MAX_DEPTH) simply comes back as "not parsed".
#pragma once
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

namespace json {

constexpr int MAX_DEPTH = 32;

struct Value {
    enum Type { Null, Bool, Number, String, Array, Object } type = Null;
    bool boolean = false;
    bool integer = false;        // a number written without '.', 'e' or 'E'
    double number = 0;
    std::string text;
    std::vector<Value> items;
    std::vector<std::pair<std::string, Value>> members;

    const Value* get(const char* key) const {
        // Last one wins on a repeated key, as in Python's json.
        for (auto it = members.rbegin(); it != members.rend(); ++it)
            if (it->first == key) return &it->second;
        return nullptr;
    }
    const std::string* get_string(const char* key) const {
        const Value* v = get(key);
        return v && v->type == String ? &v->text : nullptr;
    }
};

class Parser {
public:
    explicit Parser(const std::string& s) : p_(s.data()), end_(s.data() + s.size()) {}

    bool parse(Value& out) {
        if (!value(out, 0)) return false;
        skip();
        return p_ == end_;
    }

private:
    void skip() {
        while (p_ < end_ && (*p_ == ' ' || *p_ == '\n' || *p_ == '\r' || *p_ == '\t')) p_++;
    }

    bool literal(const char* word) {
        const char* q = p_;
        for (; *word; word++, q++)
            if (q >= end_ || *q != *word) return false;
        p_ = q;
        return true;
    }

    bool value(Value& out, int depth) {
        if (depth > MAX_DEPTH) return false;
        skip();
        if (p_ >= end_) return false;
        switch (*p_) {
        case '{': return object(out, depth);
        case '[': return array(out, depth);
        case '"':
            out.type = Value::String;
            return string(out.text);
        case 't':
            out.type = Value::Bool;
            out.boolean = true;
            return literal("true");
        case 'f':
            out.type = Value::Bool;
            return literal("false");
        case 'n':
            out.type = Value::Null;
            return literal("null");
        default: return number(out);
        }
    }

    bool object(Value& out, int depth) {
        out.type = Value::Object;
        p_++;
        skip();
        if (p_ < end_ && *p_ == '}') {
            p_++;
            return true;
        }
        while (true) {
            skip();
            std::string key;
            if (p_ >= end_ || *p_ != '"' || !string(key)) return false;
            skip();
            if (p_ >= end_ || *p_ != ':') return false;
            p_++;
            Value v;
            if (!value(v, depth + 1)) return false;
            out.members.emplace_back(std::move(key), std::move(v));
            skip();
            if (p_ >= end_) return false;
            if (*p_ == ',') {
                p_++;
                continue;
            }
            if (*p_ == '}') {
                p_++;
                return true;
            }
            return false;
        }
    }

    bool array(Value& out, int depth) {
        out.type = Value::Array;
        p_++;
        skip();
        if (p_ < end_ && *p_ == ']') {
            p_++;
            return true;
        }
        while (true) {
            Value v;
            if (!value(v, depth + 1)) return false;
            out.items.push_back(std::move(v));
            skip();
            if (p_ >= end_) return false;
            if (*p_ == ',') {
                p_++;
                continue;
            }
            if (*p_ == ']') {
                p_++;
                return true;
            }
            return false;
        }
    }

    static void put_utf8(std::string& s, uint32_t c) {
        if (c < 0x80) {
            s.push_back(static_cast<char>(c));
        } else if (c < 0x800) {
            s.push_back(static_cast<char>(0xC0 | (c >> 6)));
            s.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        } else if (c < 0x10000) {
            s.push_back(static_cast<char>(0xE0 | (c >> 12)));
            s.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
            s.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        } else {
            s.push_back(static_cast<char>(0xF0 | (c >> 18)));
            s.push_back(static_cast<char>(0x80 | ((c >> 12) & 0x3F)));
            s.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
            s.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        }
    }

    bool hex4(uint32_t& out) {
        if (end_ - p_ < 4) return false;
        out = 0;
        for (int i = 0; i < 4; i++) {
            char c = *p_++;
            out <<= 4;
            if (c >= '0' && c <= '9') out |= c - '0';
            else if (c >= 'a' && c <= 'f') out |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') out |= c - 'A' + 10;
            else return false;
        }
        return true;
    }

    bool string(std::string& out) {
        p_++;
        while (p_ < end_) {
            unsigned char c = static_cast<unsigned char>(*p_++);
            if (c == '"') return true;
            if (c < 0x20) return false;
            if (c != '\\') {
                out.push_back(static_cast<char>(c));
                continue;
            }
            if (p_ >= end_) return false;
            char e = *p_++;
            switch (e) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u': {
                uint32_t c1;
                if (!hex4(c1)) return false;
                if (c1 >= 0xD800 && c1 < 0xDC00 && end_ - p_ >= 6 && p_[0] == '\\' && p_[1] == 'u') {
                    const char* back = p_;
                    p_ += 2;
                    uint32_t c2;
                    if (!hex4(c2)) return false;
                    if (c2 >= 0xDC00 && c2 < 0xE000) c1 = 0x10000 + ((c1 - 0xD800) << 10) + (c2 - 0xDC00);
                    else p_ = back;
                }
                if (c1 >= 0xD800 && c1 < 0xE000) c1 = 0xFFFD;    // a lone surrogate has no UTF-8 form
                put_utf8(out, c1);
                break;
            }
            default: return false;
            }
        }
        return false;
    }

    bool number(Value& out) {
        const char* start = p_;
        bool integer = true;
        if (p_ < end_ && *p_ == '-') p_++;
        const char* digits = p_;
        while (p_ < end_ && *p_ >= '0' && *p_ <= '9') p_++;
        if (p_ == digits) return false;
        if (p_ < end_ && *p_ == '.') {
            integer = false;
            p_++;
            const char* frac = p_;
            while (p_ < end_ && *p_ >= '0' && *p_ <= '9') p_++;
            if (p_ == frac) return false;
        }
        if (p_ < end_ && (*p_ == 'e' || *p_ == 'E')) {
            integer = false;
            p_++;
            if (p_ < end_ && (*p_ == '+' || *p_ == '-')) p_++;
            const char* exp = p_;
            while (p_ < end_ && *p_ >= '0' && *p_ <= '9') p_++;
            if (p_ == exp) return false;
        }
        out.type = Value::Number;
        out.integer = integer;
        out.number = std::strtod(std::string(start, p_ - start).c_str(), nullptr);   // 400 digits just become inf
        return true;
    }

    const char* p_;
    const char* end_;
};

// A JSON string literal. Invalid UTF-8 (a half-written multibyte name, say) becomes U+FFFD, as Python's
// errors="replace" does, so the packet stays valid for the other side.
inline void append_string(std::string& out, const std::string& s) {
    out.push_back('"');
    const size_t n = s.size();
    for (size_t i = 0; i < n;) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (c < 0x80) {
            if (c == '"' || c == '\\') {
                out.push_back('\\');
                out.push_back(static_cast<char>(c));
            } else if (c < 0x20) {
                char hex[8];
                std::snprintf(hex, sizeof hex, "\\u%04x", c);
                out += hex;
            } else {
                out.push_back(static_cast<char>(c));
            }
            i++;
            continue;
        }
        size_t len = c >= 0xF0 && c <= 0xF4 ? 4 : c >= 0xE0 && c < 0xF0 ? 3 : c >= 0xC2 && c < 0xE0 ? 2 : 0;
        bool ok = len != 0 && i + len <= n;
        for (size_t k = 1; ok && k < len; k++)
            ok = (static_cast<unsigned char>(s[i + k]) & 0xC0) == 0x80;
        if (ok && len == 3) {
            unsigned char d = static_cast<unsigned char>(s[i + 1]);
            ok = !(c == 0xE0 && d < 0xA0) && !(c == 0xED && d >= 0xA0);
        } else if (ok && len == 4) {
            unsigned char d = static_cast<unsigned char>(s[i + 1]);
            ok = !(c == 0xF0 && d < 0x90) && !(c == 0xF4 && d >= 0x90);
        }
        if (ok) {
            out.append(s, i, len);
            i += len;
        } else {
            out += "\\ufffd";
            i++;
        }
    }
    out.push_back('"');
}

}  // namespace json
