cmake_minimum_required( VERSION 3.17 )
project(PackageTest CXX)

find_package(Threads REQUIRED)
find_package(p2300 CONFIG REQUIRED)

add_executable(test_stdexec test.cpp)
target_link_libraries(test_stdexec p2300::p2300)
