cmake_minimum_required(VERSION 3.23)
project(concurrency-25-concurrent-grpc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

# Static gRPC/protobuf/abseil archives reference each other circularly;
# --start-group/--end-group lets the linker resolve that regardless of
# link-line order. Same fix the sibling statelessness tutorial's
# 10-grpc-microservices example applies for the identical trio.
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> \
     <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

find_package(gRPC     CONFIG REQUIRED)
find_package(Protobuf CONFIG REQUIRED)
find_package(absl     CONFIG REQUIRED)
find_package(Threads  REQUIRED)

# ── gRPC codegen for echo.proto (protoc + grpc_cpp_plugin, both from
#    Conan) run at build time in the builder stage. ──
set(GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})

get_target_property(GRPC_CPP_PLUGIN_EXECUTABLE gRPC::grpc_cpp_plugin LOCATION)
get_target_property(PROTOC_EXECUTABLE protobuf::protoc LOCATION)

add_custom_command(
    OUTPUT ${GENERATED_DIR}/echo.pb.cc ${GENERATED_DIR}/echo.pb.h
           ${GENERATED_DIR}/echo.grpc.pb.cc ${GENERATED_DIR}/echo.grpc.pb.h
    COMMAND ${PROTOC_EXECUTABLE}
            --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/proto
            --cpp_out=${GENERATED_DIR}
            --grpc_out=${GENERATED_DIR}
            --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/proto/echo.proto
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/proto/echo.proto
    COMMENT "Generating gRPC C++ code from echo.proto"
    VERBATIM)

# ── async_server: the raw CompletionQueue async server (Doc 25) ──
add_executable(async_server
    src/async_server.cpp
    ${GENERATED_DIR}/echo.pb.cc ${GENERATED_DIR}/echo.grpc.pb.cc)
target_include_directories(async_server PRIVATE ${GENERATED_DIR} src)
target_link_libraries(async_server PRIVATE
    gRPC::grpc++ protobuf::libprotobuf Threads::Threads)

# ── concurrent_client: many simultaneous ServerStreamEcho calls ──
add_executable(concurrent_client
    src/concurrent_client.cpp
    ${GENERATED_DIR}/echo.pb.cc ${GENERATED_DIR}/echo.grpc.pb.cc)
target_include_directories(concurrent_client PRIVATE ${GENERATED_DIR} src)
target_link_libraries(concurrent_client PRIVATE
    gRPC::grpc++ protobuf::libprotobuf Threads::Threads)

install(TARGETS async_server concurrent_client RUNTIME DESTINATION bin)
