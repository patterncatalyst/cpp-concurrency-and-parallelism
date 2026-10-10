cmake_minimum_required(VERSION 3.23)
project(concurrency-05-futex-cost LANGUAGES CXX)

# C++20 per the repo convention; this example's std::mutex / std::thread
# usage has worked since C++11, but standardizing the toolchain is the
# point of the convention.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(futex_cost src/futex_cost.cpp)
target_link_libraries(futex_cost PRIVATE fmt::fmt Threads::Threads)

install(TARGETS futex_cost RUNTIME DESTINATION bin)
