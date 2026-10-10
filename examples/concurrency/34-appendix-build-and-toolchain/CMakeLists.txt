cmake_minimum_required(VERSION 3.23)
project(concurrency-34-appendix-build-and-toolchain LANGUAGES CXX)

# C++20 per this project's convention (20-mechanical-sympathy's note
# applies here too): the appendix text targets clang 18 / C++23, but this
# repo standardizes every example's own code on C++20 so it compiles
# cleanly on both clang and GCC without requiring either toolchain's
# newest release.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(shared_counter src/shared_counter.cpp)
target_link_libraries(shared_counter PRIVATE fmt::fmt Threads::Threads)

install(TARGETS shared_counter RUNTIME DESTINATION bin)
