cmake_minimum_required(VERSION 3.23)
project(concurrency-01-execution-models LANGUAGES CXX)

# C++20 per the repo convention. std::popcount (<bit>) is C++20; the four
# execution models themselves (jthread, execution policies, atomics) only
# need C++17, but the project standardizes on C++20 throughout.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(TBB REQUIRED)
find_package(Threads REQUIRED)

add_executable(execution_models src/execution_models.cpp)
target_link_libraries(execution_models PRIVATE TBB::tbb Threads::Threads)

install(TARGETS execution_models RUNTIME DESTINATION bin)
