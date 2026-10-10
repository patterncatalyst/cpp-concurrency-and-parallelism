cmake_minimum_required(VERSION 3.23)
project(concurrency-06-lock-ordering LANGUAGES CXX)

# C++20: std::latch is a C++20 facility; std::scoped_lock is C++17. The
# project standardizes examples on C++20 per the repo convention.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(lock_ordering src/lock_ordering.cpp)
target_link_libraries(lock_ordering PRIVATE fmt::fmt Threads::Threads)

install(TARGETS lock_ordering RUNTIME DESTINATION bin)
