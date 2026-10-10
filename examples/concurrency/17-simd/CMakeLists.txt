cmake_minimum_required(VERSION 3.23)
project(concurrency-17-simd LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Deliberately no -march flag beyond the default x86-64 baseline (SSE2 is
# mandated by the ABI itself). The chapter is explicit that -march=native
# baked into a container image is a portability trap -- a binary built on
# one machine's CPU features can SIGILL on a different deployment target
# with narrower ones. It also keeps the three update variants' arithmetic
# provably identical: without -mavx2/-mfma, neither the scalar nor the
# std::experimental::simd path can fuse a multiply-add into a hardware FMA
# instruction the other lacks, so this example's HARD correctness check
# (bit-identical position hashes across all three variants) holds by
# construction rather than needing a floating-point tolerance.
add_compile_options(-O2)

find_package(fmt REQUIRED)

add_executable(simd_particles src/simd_particles.cpp)
target_link_libraries(simd_particles PRIVATE fmt::fmt)

install(TARGETS simd_particles RUNTIME DESTINATION bin)
