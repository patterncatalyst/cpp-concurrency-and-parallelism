cmake_minimum_required(VERSION 3.23)
project(concurrency-15-thread-pool LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(pool_bench src/pool_bench.cpp)
target_link_libraries(pool_bench PRIVATE fmt::fmt Threads::Threads)

add_executable(cgroup_probe src/cgroup_probe.cpp)
target_link_libraries(cgroup_probe PRIVATE fmt::fmt Threads::Threads)

install(TARGETS pool_bench cgroup_probe RUNTIME DESTINATION bin)
