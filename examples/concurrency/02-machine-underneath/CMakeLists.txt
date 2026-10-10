cmake_minimum_required(VERSION 3.23)
project(concurrency-02-machine-underneath LANGUAGES CXX)

# C++20 per the project convention. The chase itself needs nothing newer
# than C++17 (std::hardware_destructive_interference_size, <random>,
# std::shuffle), but examples are standardized on C++20.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(cache_latency src/cache_latency.cpp)
target_link_libraries(cache_latency PRIVATE fmt::fmt Threads::Threads)

install(TARGETS cache_latency RUNTIME DESTINATION bin)
