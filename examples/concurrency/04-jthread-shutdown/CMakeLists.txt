cmake_minimum_required(VERSION 3.23)
project(concurrency-04-jthread-shutdown LANGUAGES CXX)

# C++20: std::jthread and std::stop_token are both C++20 library additions
# (the entire subject of this example), and the project standardizes
# examples on C++20 throughout.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(Threads REQUIRED)

add_executable(jthread_shutdown src/jthread_shutdown.cpp)
target_link_libraries(jthread_shutdown PRIVATE Threads::Threads)

install(TARGETS jthread_shutdown RUNTIME DESTINATION bin)
