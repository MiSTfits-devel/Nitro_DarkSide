# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Headless melonDS 3D raster oracle for the Clash rasteriser gate.
cmake_minimum_required(VERSION 3.16)
project(nds_gx3d_oracle CXX C)

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

add_executable(nds_gx3d_oracle main.cpp Platform.cpp)
target_compile_features(nds_gx3d_oracle PRIVATE cxx_std_17)
target_include_directories(nds_gx3d_oracle PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(nds_gx3d_oracle PRIVATE core)

add_executable(nds_gx3d_frame_oracle frame_oracle.cpp Platform.cpp)
target_compile_features(nds_gx3d_frame_oracle PRIVATE cxx_std_17)
target_include_directories(nds_gx3d_frame_oracle PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(nds_gx3d_frame_oracle PRIVATE core)
