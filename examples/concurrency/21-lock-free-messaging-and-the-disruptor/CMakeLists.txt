cmake_minimum_required(VERSION 3.23)
project(concurrency-21-lock-free-messaging-and-the-disruptor LANGUAGES CXX)

# C++20: std::atomic<T>::wait/notify (used by the producer and both
# consumer stages to block without a hand-rolled futex wrapper) requires
# C++20; the rest of the example needs nothing newer.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(disruptor_ring src/disruptor_ring.cpp)
target_link_libraries(disruptor_ring PRIVATE fmt::fmt Threads::Threads)

install(TARGETS disruptor_ring RUNTIME DESTINATION bin)
