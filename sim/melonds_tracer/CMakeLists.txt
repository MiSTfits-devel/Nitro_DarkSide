# Headless melonDS tracer for the M3 differential trace (docs/TRACE_DIFF.md).
# Consumes the melonDS core as a subproject; point MELONDS_DIR at a checkout
# of melonDS 0.9.5 with tracer.patch applied (build.sh does all of this).
cmake_minimum_required(VERSION 3.15)
project(melonds_tracer CXX C)

set(MELONDS_DIR "" CACHE PATH "Path to melonDS 0.9.5 source checkout")
if (NOT MELONDS_DIR)
    message(FATAL_ERROR "set -DMELONDS_DIR=/path/to/melonDS")
endif()

list(APPEND CMAKE_MODULE_PATH "${MELONDS_DIR}/cmake")

set(BUILD_QT_SDL OFF CACHE BOOL "" FORCE)
set(ENABLE_JIT OFF CACHE BOOL "" FORCE)
set(ENABLE_OGLRENDERER OFF CACHE BOOL "" FORCE)
set(ENABLE_LTO_RELEASE OFF CACHE BOOL "" FORCE)

add_subdirectory(${MELONDS_DIR} melonds-core EXCLUDE_FROM_ALL)

add_executable(melonds_tracer main.cpp Platform.cpp)
target_include_directories(melonds_tracer PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(melonds_tracer PRIVATE core)
