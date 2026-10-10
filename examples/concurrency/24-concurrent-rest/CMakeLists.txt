cmake_minimum_required(VERSION 3.23)
project(concurrency-24-concurrent-rest LANGUAGES CXX)

# C++20 per the repo convention -- also the version that matters here: the
# session/request-handling coroutines in both binaries use
# boost::asio::awaitable, which is built on native compiler C++20
# coroutine support (co_await/co_return), not Boost.Context.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(Boost REQUIRED CONFIG COMPONENTS system)
find_package(Threads REQUIRED)

add_executable(rest_server src/rest_server.cpp)
target_link_libraries(rest_server PRIVATE Boost::boost Boost::system Threads::Threads)

add_executable(rest_client src/rest_client.cpp)
target_link_libraries(rest_client PRIVATE Boost::boost Boost::system Threads::Threads)

install(TARGETS rest_server rest_client RUNTIME DESTINATION bin)
