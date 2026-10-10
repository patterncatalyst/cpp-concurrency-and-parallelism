cmake_minimum_required(VERSION 3.23)
project(concurrency-14-par-sort-reduce LANGUAGES CXX)

# C++20 per the repo convention. The execution policies this example
# exercises (seq/par/par_unseq) are C++17; par_unseq's sibling `unseq` is
# C++20, but this example only compares the three C++17 policies, per the
# chapter's own headline fact that nothing in the C++20/23/26 window
# introduced them.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(TBB REQUIRED)
find_package(Threads REQUIRED)

add_executable(par_sort_reduce src/par_sort_reduce.cpp)

# TBB::tbb must be linked (not just TBB headers visible to <execution>) for
# std::execution::par to actually dispatch across threads rather than
# silently falling back to sequential execution -- the chapter's own warning
# about a parallel backend that "compiles, runs, and produces a correct but
# non-parallel result with no diagnostic that anything was skipped."
target_link_libraries(par_sort_reduce PRIVATE fmt::fmt TBB::tbb Threads::Threads)

install(TARGETS par_sort_reduce RUNTIME DESTINATION bin)
