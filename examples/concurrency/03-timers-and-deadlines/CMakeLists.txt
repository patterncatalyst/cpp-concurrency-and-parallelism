cmake_minimum_required(VERSION 3.23)
project(concurrency-03-timers-and-deadlines LANGUAGES CXX)

# C++20 per the repo convention; the deadline-propagation chain and the
# vDSO probe only use <chrono>/<thread>/<atomic>, all available well before
# C++20, but the project standardizes examples on C++20 throughout.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(Threads REQUIRED)

add_executable(deadline_chain src/deadline_chain.cpp)
target_link_libraries(deadline_chain PRIVATE Threads::Threads)

add_executable(clockprobe src/clockprobe.cpp)
target_link_libraries(clockprobe PRIVATE Threads::Threads)

install(TARGETS deadline_chain clockprobe RUNTIME DESTINATION bin)
