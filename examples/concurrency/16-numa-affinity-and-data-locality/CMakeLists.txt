cmake_minimum_required(VERSION 3.23)
project(concurrency-16-numa-affinity-and-data-locality LANGUAGES CXX)

# C++20 for std::jthread/std::thread; the NUMA and affinity work itself is all
# platform API (libnuma + sched_setaffinity), which no C++ standard abstracts.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

# libnuma ships with numactl-devel (installed in the lab guest by demo.sh); it
# provides numa.h/numaif.h and libnuma.so. There is no standard CMake module
# for it, so locate the library by name and fail loudly if it is missing.
find_library(NUMA_LIB numa REQUIRED)
find_package(Threads REQUIRED)

add_executable(numa_locality src/numa_locality.cpp)
target_link_libraries(numa_locality PRIVATE ${NUMA_LIB} Threads::Threads)

install(TARGETS numa_locality RUNTIME DESTINATION bin)
