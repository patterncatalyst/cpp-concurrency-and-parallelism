#pragma once
// concurrency/24-concurrent-rest — tiny "--flag value" CLI parser shared by
// rest_server.cpp and rest_client.cpp. Deliberately minimal: linear scan,
// no validation beyond a loose numeric conversion, no usage/help text, and
// no dependency on Boost.ProgramOptions (disabled in conanfile.txt to keep
// the Boost build lean -- see conanfile.txt for the full without_* list).
// An option this program never asks for via get()/get_long() is simply
// ignored, which keeps server and client CLIs independent of each other.

#include <cstdlib>
#include <cstring>
#include <string>

namespace cli {

inline std::string get(int argc, char** argv, const char* name, std::string def) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::strcmp(argv[i], name) == 0) {
            return std::string(argv[i + 1]);
        }
    }
    return def;
}

inline long get_long(int argc, char** argv, const char* name, long def) {
    std::string v = get(argc, argv, name, "");
    if (v.empty()) {
        return def;
    }
    return std::strtol(v.c_str(), nullptr, 10);
}

} // namespace cli
