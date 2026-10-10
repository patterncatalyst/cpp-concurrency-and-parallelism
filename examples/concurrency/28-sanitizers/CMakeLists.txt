cmake_minimum_required(VERSION 3.23)
project(concurrency-28-sanitizers LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Dynamic-analysis demo: every binary built from this file keeps full debug
# info and frame pointers, and this directory's Containerfile never strips
# a binary afterward -- Helgrind and ASan both need symbols to name a
# source line in their reports, the same reasoning
# 27-debugging-races-deadlocks/CMakeLists.txt documents for gdb and TSan.
#
# CMAKE_BUILD_TYPE stays Release (not RelWithDebInfo) for the same reason
# documented there: it matches every other example in this project AND the
# `-s build_type=Release` the Containerfile's `conan install` resolves fmt
# against, avoiding an untested CMakeDeps config mismatch. The explicit
# -g below adds back the debug info Release wouldn't otherwise include.
set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
add_compile_options(-O2 -g -fno-omit-frame-pointer)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(racy_counter src/racy_counter.cpp)
target_link_libraries(racy_counter PRIVATE fmt::fmt Threads::Threads)

add_executable(detached_uaf src/detached_uaf.cpp)
target_link_libraries(detached_uaf PRIVATE fmt::fmt Threads::Threads)

install(TARGETS racy_counter detached_uaf RUNTIME DESTINATION bin)
