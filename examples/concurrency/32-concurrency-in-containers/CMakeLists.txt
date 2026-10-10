cmake_minimum_required(VERSION 3.23)
project(concurrency-32-concurrency-in-containers LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(cgroup_probe src/cgroup_probe.cpp)
target_link_libraries(cgroup_probe PRIVATE fmt::fmt Threads::Threads)

install(TARGETS cgroup_probe RUNTIME DESTINATION bin)
