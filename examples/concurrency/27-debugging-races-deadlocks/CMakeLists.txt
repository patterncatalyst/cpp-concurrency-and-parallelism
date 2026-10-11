cmake_minimum_required(VERSION 3.23)
project(concurrency-27-debugging-races-deadlocks LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Debugging/dynamic-analysis demo: every binary built from this file keeps
# full debug info and frame pointers, and this directory's Containerfile
# never strips a binary afterward -- unlike 20-mechanical-sympathy's
# `strip --strip-all`, a stripped binary here would defeat the entire
# point: gdb needs symbols to name frames, and ThreadSanitizer needs them
# to name source lines in its report. -O2 is kept (not dropped to -Og)
# because the data race depends on the same "the standard permits a
# compiler to assume a race-free program" optimization pressure the
# chapter discusses; the deadlock binary's run_transfer() is marked
# __attribute__((noinline)) in source specifically so it still shows up as
# its own gdb frame at -O2, rather than relying on a lower optimization
# level to keep it from being inlined away.
#
# CMAKE_BUILD_TYPE stays Release -- matching every other example in this
# project, and (more importantly) matching the `-s build_type=Release` the
# Containerfile's `conan install` resolves fmt against. RelWithDebInfo
# would be the more accurate label for what this binary actually is, but
# nothing else in this project builds fmt for anything but Release, and
# CMakeDeps' generated config has no tested fallback for a mismatched
# config here. add_compile_options below overrides Release's default
# `-O3 -DNDEBUG` optimization level (GCC takes the LAST -O flag on the
# command line) and adds back the `-g` Release doesn't include by default
# -- same binary, same debug info, zero new risk on the dependency side.
set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
add_compile_options(-O2 -g -fno-omit-frame-pointer)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(racy_counter src/racy_counter.cpp)
target_link_libraries(racy_counter PRIVATE fmt::fmt Threads::Threads)

add_executable(ab_ba_deadlock src/ab_ba_deadlock.cpp)
target_link_libraries(ab_ba_deadlock PRIVATE fmt::fmt Threads::Threads)

install(TARGETS racy_counter ab_ba_deadlock RUNTIME DESTINATION bin)
