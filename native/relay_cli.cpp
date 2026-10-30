// The C++ relay as a console tool, for tests only (never shipped): same arguments as net/pbzcoop_net.py for the host
// and client roles, so net/test_pbzcoop_net.py can run it with PBZCOOP_NATIVE_RELAY set.
#include "relay.hpp"

int wmain(int argc, wchar_t** argv) {
    relay::Options o;
    if (argc < 2) {
        std::fputs("usage: relay_cli host|client --dir <folder> [--peer <ip>] [--port <n>] [--ini <file>] ...\n", stderr);
        return 2;
    }
    o.role = relay::narrow(argv[1]);
    for (int i = 2; i + 1 < argc; i += 2) {
        std::wstring key = argv[i], value = argv[i + 1];
        if (key == L"--dir") o.dir = value;
        else if (key == L"--peer") o.peer = relay::narrow(value);
        else if (key == L"--port") o.port = _wtoi(value.c_str());
        else if (key == L"--ini") o.ini = value;
        else if (key == L"--mod-version") o.version = relay::narrow(value);
        else if (key == L"--transport") o.transport = relay::narrow(value);
        else if (key == L"--allow") o.allow_any = value == L"any";
        else if (key == L"--seconds") o.seconds = _wtof(value.c_str());
        else if (key == L"--alive-file") o.alive_file = value;
        else if (key == L"--alive-timeout") o.alive_timeout = _wtof(value.c_str());
        else {
            std::fprintf(stderr, "unknown argument %s\n", relay::narrow(key).c_str());
            return 2;
        }
    }
    if ((o.role != "host" && o.role != "client") || o.dir.empty()) {
        std::fputs("relay_cli needs host or client, and --dir\n", stderr);
        return 2;
    }
    CreateDirectoryW(o.dir.c_str(), nullptr);
    relay::run(o, [](const std::string& line) {
        std::puts(line.c_str());
        std::fflush(stdout);
    });
    return 0;
}

// The console tool has no game around it, so no Steam.
std::unique_ptr<relay::Link> relay::make_steam_link(const std::string&, const std::string&) {
    throw std::runtime_error("relay_cli has no Steam: the Steam link only works inside the game");
}
