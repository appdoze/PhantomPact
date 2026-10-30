// main.dll: UE4SS loads it from PBZCoop\dlls because the folder has that file (a C++ mod). It uses nothing from UE4SS:
// start_mod returns null, so UE4SS treats the mod as not started and never calls into it, and a UE4SS update can't
// break it unless the loader itself changes. (Measured on Vercadi's 3.0.1 build: start_mod is called twice and
// uninstall_mod never, so it starts once and stops by the heartbeat.)
//
// The Lua side (autostart.lua) can't call in here, so the two talk through files in the mod folder:
//   net_native.txt  written here every few seconds: tells the mod the built-in relay is available
//   net_start.txt   written by the mod: what to run (key=value lines), removed once taken
// Everything else is the relay's usual files. Two copies of the game on one PC use the instN folder, as the Lua does.
#include "relay.hpp"

namespace {

constexpr DWORD POLL_MS = 250;
constexpr DWORD NATIVE_EVERY_MS = 2000;

LONG started = 0;
HMODULE self = nullptr;
std::wstring mod_root;     // ...\Mods\PBZCoop
std::wstring mod_dir;      // mod_root, or mod_root\instN for copy N

void find_folders() {
    wchar_t path[MAX_PATH * 4];
    DWORD n = GetModuleFileNameW(self, path, static_cast<DWORD>(std::size(path)));
    std::wstring dll(path, n);
    std::wstring dlls = dll.substr(0, dll.find_last_of(L'\\'));
    mod_root = dlls.substr(0, dlls.find_last_of(L'\\'));
    mod_dir = mod_root;
    wchar_t instance[16];
    if (GetEnvironmentVariableW(L"PBZCOOP_INSTANCE", instance, 16) > 0 && _wtoi(instance) > 1)
        mod_dir += L"\\inst" + std::wstring(instance);
}

DWORD WINAPI announce_thread(void*) {
    const std::wstring path = mod_dir + L"\\net_native.txt";
    while (true) {
        relay::write_atomic(path, "ready " + std::to_string(static_cast<long long>(std::time(nullptr))) + "\n");
        Sleep(NATIVE_EVERY_MS);
    }
}

void run_from(const std::wstring& start_path) {
    relay::Ini start = relay::read_ini(start_path);
    DeleteFileW(start_path.c_str());
    DeleteFileW((mod_dir + L"\\relay_error.txt").c_str());
    const std::wstring log_path = mod_dir + L"\\relay_log.txt";
    relay::write_atomic(log_path, "");

    relay::Options o;
    o.role = start["role"];
    o.dir = mod_dir;
    o.peer = start["peer"];
    o.transport = start["transport"].empty() ? "udp" : start["transport"];
    o.version = start["version"].empty() ? "?" : start["version"];
    o.port = std::atoi(start["port"].c_str());
    if (o.port <= 0 || o.port > 65535) o.port = 47800;
    o.ini = mod_dir + L"\\PhantomPact.ini";
    o.alive_file = mod_dir + L"\\net_alive.txt";
    relay::run(o, [&](const std::string& line) {
        if (line.rfind("role=", 0) != 0) relay::append_lines(log_path, {line});   // not the status, once a second
    });
}

DWORD WINAPI watch_thread(void*) {
    const std::wstring start_path = mod_dir + L"\\net_start.txt";
    while (true) {
        if (GetFileAttributesW(start_path.c_str()) != INVALID_FILE_ATTRIBUTES) {
            try {
                run_from(start_path);
            } catch (const std::exception& e) {
                relay::write_atomic(mod_dir + L"\\relay_error.txt", std::string(e.what()) + "\n");
            }
        }
        Sleep(POLL_MS);
    }
}

}  // namespace

extern "C" __declspec(dllexport) void* start_mod() {
    if (InterlockedExchange(&started, 1) == 0) {
        find_folders();
        CloseHandle(CreateThread(nullptr, 0, announce_thread, nullptr, 0, nullptr));
        CloseHandle(CreateThread(nullptr, 0, watch_thread, nullptr, 0, nullptr));
    }
    return nullptr;
}

extern "C" __declspec(dllexport) void uninstall_mod(void*) {}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        self = instance;
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}
