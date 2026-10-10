cmake_minimum_required(VERSION 3.23)
project(concurrency-13-fiber-worker-pool LANGUAGES CXX)

# C++20 per the repo convention; Boost.Fiber and Boost.Context themselves
# only need C++11.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(Boost REQUIRED COMPONENTS fiber context)
find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(fiber_worker_pool src/fiber_worker_pool.cpp)
target_link_libraries(fiber_worker_pool PRIVATE
    Boost::fiber
    Boost::context
    fmt::fmt
    Threads::Threads
)

install(TARGETS fiber_worker_pool RUNTIME DESTINATION bin)
