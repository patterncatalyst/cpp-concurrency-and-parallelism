cmake_minimum_required(VERSION 3.23)
project(concurrency-33-ingest-match-publish LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(pipeline src/pipeline.cpp)
target_link_libraries(pipeline PRIVATE fmt::fmt Threads::Threads)

install(TARGETS pipeline RUNTIME DESTINATION bin)
