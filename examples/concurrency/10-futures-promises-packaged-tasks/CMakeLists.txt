cmake_minimum_required(VERSION 3.23)
project(concurrency-10-futures-promises-packaged-tasks LANGUAGES CXX)

# C++20 per the repo convention. std::async/std::future/std::promise/
# std::packaged_task are all pre-C++20 facilities -- nothing here needs the
# standard past C++11/17 -- but every example in this project targets C++20.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-O2)

find_package(fmt REQUIRED)
find_package(Threads REQUIRED)

add_executable(launch_policy src/launch_policy.cpp)
target_link_libraries(launch_policy PRIVATE fmt::fmt Threads::Threads)

add_executable(worker_pool src/worker_pool.cpp)
target_link_libraries(worker_pool PRIVATE fmt::fmt Threads::Threads)

install(TARGETS launch_policy worker_pool RUNTIME DESTINATION bin)
