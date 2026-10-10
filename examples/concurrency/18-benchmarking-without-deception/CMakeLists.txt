cmake_minimum_required(VERSION 3.23)
project(concurrency-18-benchmarking-without-deception LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)

add_executable(bench src/bench.cpp)
target_link_libraries(bench PRIVATE fmt::fmt)

install(TARGETS bench RUNTIME DESTINATION bin)
