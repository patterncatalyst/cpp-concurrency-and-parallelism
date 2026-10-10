cmake_minimum_required(VERSION 3.23)
project(concurrency-12-asio-strand LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Boost REQUIRED COMPONENTS system)
find_package(Threads REQUIRED)

add_executable(asio_strand src/asio_strand.cpp)
target_link_libraries(asio_strand PRIVATE fmt::fmt Boost::system Threads::Threads)

install(TARGETS asio_strand RUNTIME DESTINATION bin)
