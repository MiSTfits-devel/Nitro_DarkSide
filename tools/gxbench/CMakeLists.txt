# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# The A9 raster bench, built against the vendored melonDS tree so the number it
# prints is the renderer the hybrid core actually runs.
cmake_minimum_required(VERSION 3.16)
project(nds_gxbench CXX C)

set(MELONDS_DIR "" CACHE PATH "Path to the vendored melonDS tree")
if (NOT MELONDS_DIR)
    message(FATAL_ERROR "set -DMELONDS_DIR=/path/to/melonDS")
endif()

list(APPEND CMAKE_MODULE_PATH "${MELONDS_DIR}/cmake")

set(BUILD_QT_SDL OFF CACHE BOOL "" FORCE)
set(ENABLE_JIT OFF CACHE BOOL "" FORCE)
set(ENABLE_OGLRENDERER OFF CACHE BOOL "" FORCE)
set(ENABLE_GDBSTUB OFF CACHE BOOL "" FORCE)
set(ENABLE_LTO_RELEASE OFF CACHE BOOL "" FORCE)

add_subdirectory(${MELONDS_DIR} melonds-core EXCLUDE_FROM_ALL)

add_executable(melonds_gxbench main.cpp Platform.cpp)
target_compile_features(melonds_gxbench PRIVATE cxx_std_17)
target_include_directories(melonds_gxbench PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(melonds_gxbench PRIVATE core)
