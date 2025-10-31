cmake_minimum_required(VERSION 3.16)
project(matrix-mul LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if (CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(MPI_CXX_HEADER_DIR "C:/Program Files (x86)/Microsoft SDKs/MPI/Include")
    set(MPI_CXX_LIB_NAMES "msmpi")
    set(MPI_msmpi_LIBRARY "C:/Program Files (x86)/Microsoft SDKs/MPI/Lib/x64/msmpi.lib")
endif()

# Use Release by default (can be overridden with -DCMAKE_BUILD_TYPE=Debug)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

find_package(MPI REQUIRED)

include_directories(${CMAKE_SOURCE_DIR}/src)
include_directories(${CMAKE_SOURCE_DIR}/extern)

add_executable(matrix-mul
        src/main.cpp
        src/io_utils.cpp
        src/linear.cpp
        src/multithreaded.cpp
        src/parallel_mpi.cpp
        extern/mpi/mpi.h
        src/io_utils.cpp
)

target_link_libraries(matrix-mul PRIVATE MPI::MPI_CXX)

# optimize
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    target_compile_options(matrix-mul PRIVATE -O3 -march=native -DNDEBUG)
endif()
