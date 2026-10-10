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

# The static opentelemetry-cpp archives reference each other circularly: the
# OTLP recordable/exporter archives reference symbols defined in
# libopentelemetry_common.a (e.g. opentelemetry::sdk::common::Base64Escape)
# and common references symbols back in the exporter set. A single-pass link
# cannot satisfy that from any one ordering. Conan exposes each component as an
# INTERFACE target (so CMake's $<LINK_GROUP:RESCAN,...> does not apply), so we
# wrap the whole link line in -Wl,--start-group/--end-group via the link
# command itself and let the linker rescan until no new symbols resolve. This
# is the identical fix the gRPC example (25) uses for the grpc/protobuf/abseil
# trio.
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> \
     <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)
find_package(opentelemetry-cpp REQUIRED)

add_executable(instrumented_pool src/instrumented_pool.cpp)

# Component names match opentelemetry-cpp's Conan package_info() exactly
# (one CMake target per library); CMakeDeps resolves the transitive deps
# each component declares (libcurl, openssl, protobuf, abseil, nlohmann_json)
# automatically. The --start-group wrapper set above resolves the circular
# references among these static archives.
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
