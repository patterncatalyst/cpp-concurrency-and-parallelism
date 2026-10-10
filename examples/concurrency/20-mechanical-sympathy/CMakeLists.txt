cmake_minimum_required(VERSION 3.23)
project(concurrency-20-mechanical-sympathy LANGUAGES CXX)

# C++20: std::hardware_destructive_interference_size (<new>, C++17) plus
# the alignas/atomics this example exercises are all available since C++17,
# but the project standardizes examples on C++20 per the repo convention.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(false_sharing src/false_sharing.cpp)
target_link_libraries(false_sharing PRIVATE fmt::fmt Threads::Threads)

install(TARGETS false_sharing RUNTIME DESTINATION bin)
