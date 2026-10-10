cmake_minimum_required(VERSION 3.23)
project(concurrency-07-coordination-primitives LANGUAGES CXX)

# C++20: std::barrier is a C++20 facility. The project standardizes
# examples on C++20 per the repo convention.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(barrier_workers src/barrier_workers.cpp)
target_link_libraries(barrier_workers PRIVATE fmt::fmt Threads::Threads)

install(TARGETS barrier_workers RUNTIME DESTINATION bin)
