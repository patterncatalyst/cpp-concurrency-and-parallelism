cmake_minimum_required(VERSION 3.23)
project(concurrency-11-coroutines-in-depth LANGUAGES CXX)

# C++20: co_await/co_yield/co_return, promise_type, std::coroutine_handle,
# std::default_sentinel_t -- all C++20.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

# -fcoroutines defaults to on under -std=c++20 and later on modern GCC
# (it only needed to be passed explicitly on older GCC releases that
# shipped coroutines as a pre-standardization extension). Pass it anyway,
# explicitly, for GCC: harmless on a GCC new enough to default it on, and
# it documents at the build-file level that this example specifically
# depends on coroutine support being enabled. Clang needs no equivalent
# flag once -std=c++20 is set.
if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    add_compile_options(-fcoroutines)
endif()

find_package(fmt REQUIRED)

add_executable(coroutines_in_depth src/coroutines_in_depth.cpp)
target_link_libraries(coroutines_in_depth PRIVATE fmt::fmt)

install(TARGETS coroutines_in_depth RUNTIME DESTINATION bin)
