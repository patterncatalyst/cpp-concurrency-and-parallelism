cmake_minimum_required(VERSION 3.23)
project(concurrency-29-observing-concurrency LANGUAGES CXX)

# C++20: std::latch (synchronizing a request's fan-out of pool tasks) is
# the only C++20-specific feature this example uses; opentelemetry-cpp
# itself only requires C++14/17, but the project standardizes examples on
# C++20 per the repo convention.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)
find_package(opentelemetry-cpp REQUIRED)

add_executable(instrumented_pool src/instrumented_pool.cpp)

# Component names match opentelemetry-cpp's Conan package_info() exactly
# (one CMake target per library); CMakeDeps resolves the transitive deps
# each component declares (libcurl, openssl, protobuf, abseil, nlohmann_json)
# automatically -- nothing else needs to be linked explicitly here.
target_link_libraries(instrumented_pool PRIVATE
    opentelemetry-cpp::opentelemetry_trace
    opentelemetry-cpp::opentelemetry_metrics
    opentelemetry-cpp::opentelemetry_exporter_otlp_http
    opentelemetry-cpp::opentelemetry_exporter_otlp_http_metric
    opentelemetry-cpp::opentelemetry_resources
    opentelemetry-cpp::opentelemetry_common
    fmt::fmt
    Threads::Threads
)

install(TARGETS instrumented_pool RUNTIME DESTINATION bin)
