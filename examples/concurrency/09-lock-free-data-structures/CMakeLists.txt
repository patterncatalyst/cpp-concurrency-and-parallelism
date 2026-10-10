cmake_minimum_required(VERSION 3.23)
project(concurrency-09-lock-free-data-structures LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(spsc_ring src/spsc_ring.cpp)
target_link_libraries(spsc_ring PRIVATE fmt::fmt Threads::Threads)

install(TARGETS spsc_ring RUNTIME DESTINATION bin)
