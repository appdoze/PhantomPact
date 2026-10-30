// Steam P2P for the relay: Steam Networking Messages through the game's own steam_api64.dll. Unlike
// net/steam_transport.py, which is a separate process with its own Steam connection, this runs inside the game: Steam
// is already started, so nothing here may init it, shut it down or take over callback dispatch. Only session requests
// need a callback, and they arrive on whatever thread the game runs Steam callbacks on, so they're queued for the
// relay thread.
#include "relay.hpp"

#include <mutex>

namespace {

constexpr uint32_t APP_ID = 4115450;
constexpr int CHANNEL = 0;
constexpr int SEND_NO_NAGLE = 1;
constexpr int SEND_AUTO_RESTART_BROKEN_SESSION = 32;
constexpr int FRIEND_FLAG_IMMEDIATE = 4;       // regular Steam friends
constexpr int IDENTITY_TYPE_STEAMID = 16;
constexpr int CALLBACK_SESSION_REQUEST = 1251; // SteamNetworkingMessagesSessionRequest_t
constexpr double FRIENDS_REFRESH = 5.0;
constexpr int STEAM_WAIT_S = 20;

// SteamNetworkingIdentity: a type tag, a size and a 128-byte union (the SteamID64 sits at its start).
struct Identity {
    int32_t type;
    int32_t size;
    uint64_t steam_id;
    uint8_t rest[120];
};

// The leading fields of SteamNetworkingMessage_t (it is released through the API, never freed here).
struct Message {
    void* data;
    int32_t size;
    uint32_t conn;
    Identity peer;
};

struct FriendGameInfo {
    uint64_t game_id;
    uint32_t ip;
    uint16_t port;
    uint16_t query_port;
    uint64_t lobby;
};

// Same declarations, in the same order, as CCallbackBase in Steam's headers: the compiler lays out the vtable from
// them, and Steam calls into it.
class CCallbackBase {
public:
    CCallbackBase() : flags_(0), id_(0) {}
    virtual void Run(void* param) = 0;
    virtual void Run(void* param, bool io_failure, uint64_t call) = 0;
    virtual int GetCallbackSizeBytes() = 0;

protected:
    uint8_t flags_;
    int id_;
};

std::mutex requests_lock;
std::vector<Identity> requests;

class SessionRequestCallback : public CCallbackBase {
public:
    void Run(void* param) override {
        if (!param) return;
        std::lock_guard<std::mutex> lock(requests_lock);
        if (requests.size() < 64) requests.push_back(*static_cast<Identity*>(param));
    }
    void Run(void* param, bool, uint64_t) override { Run(param); }
    int GetCallbackSizeBytes() override { return static_cast<int>(sizeof(Identity)); }
};

SessionRequestCallback session_request_callback;   // registered once, for the life of the game
bool callback_registered = false;

template <typename F>
F find_fn(HMODULE dll, const char* name) {
    auto f = reinterpret_cast<F>(GetProcAddress(dll, name));
    if (!f) throw std::runtime_error(std::string("this game's Steam has no ") + name);
    return f;
}

class SteamLink : public relay::Link {
public:
    SteamLink(const std::string& role, const std::string& peer_text) {
        HMODULE dll = GetModuleHandleW(L"steam_api64.dll");
        if (!dll) throw std::runtime_error("Steam isn't loaded in this game (steam_api64.dll)");
        auto get_friends = find_fn<void* (*)()>(dll, "SteamAPI_SteamFriends_v018");
        auto get_utils = find_fn<void* (*)()>(dll, "SteamAPI_SteamNetworkingUtils_SteamAPI_v004");
        auto get_msgs = find_fn<void* (*)()>(dll, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002");
        // The mod can get here before the game has signed in to Steam.
        for (int i = 0; i < STEAM_WAIT_S * 4 && !(friends_ && msgs_); i++) {
            friends_ = get_friends();
            msgs_ = get_msgs();
            if (!(friends_ && msgs_)) Sleep(250);
        }
        if (!friends_ || !msgs_) throw std::runtime_error("Steam isn't ready: is it running and logged in?");

        persona_ = find_fn<const char* (*)(void*)>(dll, "SteamAPI_ISteamFriends_GetPersonaName");
        friend_count_ = find_fn<int (*)(void*, int)>(dll, "SteamAPI_ISteamFriends_GetFriendCount");
        friend_by_index_ = find_fn<uint64_t (*)(void*, int, int)>(dll, "SteamAPI_ISteamFriends_GetFriendByIndex");
        friend_game_ = find_fn<bool (*)(void*, uint64_t, FriendGameInfo*)>(dll, "SteamAPI_ISteamFriends_GetFriendGamePlayed");
        friend_name_ = find_fn<const char* (*)(void*, uint64_t)>(dll, "SteamAPI_ISteamFriends_GetFriendPersonaName");
        send_ = find_fn<int (*)(void*, const Identity*, const void*, uint32_t, int, int)>(
            dll, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser");
        receive_ = find_fn<int (*)(void*, int, Message**, int)>(dll, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel");
        accept_ = find_fn<bool (*)(void*, const Identity*)>(dll, "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser");
        release_ = find_fn<void (*)(Message*)>(dll, "SteamAPI_SteamNetworkingMessage_t_Release");

        void* utils = get_utils();
        if (utils) find_fn<void (*)(void*)>(dll, "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess")(utils);
        if (!callback_registered) {
            find_fn<void (*)(CCallbackBase*, int)>(dll, "SteamAPI_RegisterCallback")(&session_request_callback,
                                                                                     CALLBACK_SESSION_REQUEST);
            callback_registered = true;
        }
        if (role != "host" && !peer_text.empty()) {
            bool is_id = peer_text.size() == 17 &&
                         std::all_of(peer_text.begin(), peer_text.end(), [](char c) { return c >= '0' && c <= '9'; });
            if (is_id) {
                relay::Addr a;
                a.steam = std::strtoull(peer_text.c_str(), nullptr, 10);
                peer = a;
            } else {
                wanted_ = relay::lower(relay::strip(peer_text));    // a friend name, case-insensitive
            }
        }
    }

    void send(const relay::Addr& to, const std::string& data) override {
        Identity id = identity(to.steam);
        send_(msgs_, &id, data.data(), static_cast<uint32_t>(data.size()), SEND_NO_NAGLE | SEND_AUTO_RESTART_BROKEN_SESSION,
              CHANNEL);
    }

    std::vector<std::pair<relay::Addr, std::string>> receive() override {
        accept_friends();
        std::vector<std::pair<relay::Addr, std::string>> out;
        Message* batch[32];
        while (true) {
            int n = receive_(msgs_, CHANNEL, batch, 32);
            for (int i = 0; i < n; i++) {
                relay::Addr a;
                a.steam = batch[i]->peer.steam_id;
                out.emplace_back(a, std::string(static_cast<const char*>(batch[i]->data), batch[i]->size));
                release_(batch[i]);
            }
            if (n < 32) return out;
        }
    }

    bool wait(double seconds) override {
        // Steam has no socket to select on: poll every few ms, cheap next to the 50 ms tick.
        Sleep(static_cast<DWORD>(std::min(seconds, 0.005) * 1000));
        return true;
    }

    std::vector<relay::Addr> candidates() override {
        double now = relay::monotonic();
        if (now - friends_at_ >= FRIENDS_REFRESH) {
            friends_at_ = now;
            playing_.clear();
            int count = friend_count_(friends_, FRIEND_FLAG_IMMEDIATE);
            for (int i = 0; i < count; i++) {
                uint64_t id = friend_by_index_(friends_, i, FRIEND_FLAG_IMMEDIATE);
                FriendGameInfo info{};
                if (!friend_game_(friends_, id, &info) || (info.game_id & 0xFFFFFF) != APP_ID) continue;
                if (!wanted_.empty() && relay::lower(relay::strip(name_of(id))) != wanted_) continue;
                relay::Addr a;
                a.steam = id;
                playing_.push_back(a);
            }
        }
        return playing_;
    }

    std::string describe(const relay::Addr& a) override {
        std::string name = name_of(a.steam);
        return name.empty() ? std::to_string(a.steam) : name;
    }

    std::string describe_self() override { return std::string("Steam as ") + persona_(friends_); }

    const char* via() override { return "steam"; }

private:
    static Identity identity(uint64_t steam_id) {
        Identity id{};
        id.type = IDENTITY_TYPE_STEAMID;
        id.size = 8;
        id.steam_id = steam_id;
        return id;
    }

    std::string name_of(uint64_t id) {
        const char* name = friend_name_(friends_, id);
        return name ? name : "";
    }

    bool is_friend(uint64_t id) {
        int count = friend_count_(friends_, FRIEND_FLAG_IMMEDIATE);
        for (int i = 0; i < count; i++)
            if (friend_by_index_(friends_, i, FRIEND_FLAG_IMMEDIATE) == id) return true;
        return false;
    }

    // Strangers are ignored, so their messages are dropped.
    void accept_friends() {
        std::vector<Identity> pending;
        {
            std::lock_guard<std::mutex> lock(requests_lock);
            pending.swap(requests);
        }
        for (const Identity& id : pending)
            if (is_friend(id.steam_id)) accept_(msgs_, &id);
    }

    void* friends_ = nullptr;
    void* msgs_ = nullptr;
    const char* (*persona_)(void*) = nullptr;
    int (*friend_count_)(void*, int) = nullptr;
    uint64_t (*friend_by_index_)(void*, int, int) = nullptr;
    bool (*friend_game_)(void*, uint64_t, FriendGameInfo*) = nullptr;
    const char* (*friend_name_)(void*, uint64_t) = nullptr;
    int (*send_)(void*, const Identity*, const void*, uint32_t, int, int) = nullptr;
    int (*receive_)(void*, int, Message**, int) = nullptr;
    bool (*accept_)(void*, const Identity*) = nullptr;
    void (*release_)(Message*) = nullptr;
    std::string wanted_;
    std::vector<relay::Addr> playing_;
    double friends_at_ = -1e9;
};

}  // namespace

std::unique_ptr<relay::Link> relay::make_steam_link(const std::string& role, const std::string& peer) {
    return std::make_unique<SteamLink>(role, peer);
}
