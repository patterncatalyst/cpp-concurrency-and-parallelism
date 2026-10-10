cmake_minimum_required(VERSION 3.23)
project(concurrency-08-atomics-and-the-memory-model LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(ring_handoff src/ring_handoff.cpp)
target_link_libraries(ring_handoff PRIVATE fmt::fmt Threads::Threads)

install(TARGETS ring_handoff RUNTIME DESTINATION bin)
