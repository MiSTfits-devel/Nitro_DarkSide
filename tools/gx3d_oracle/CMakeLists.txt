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

add_executable(nds_gx3d_scene_oracle scene_oracle.cpp Platform.cpp)
target_compile_features(nds_gx3d_scene_oracle PRIVATE cxx_std_17)
target_include_directories(nds_gx3d_scene_oracle PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(nds_gx3d_scene_oracle PRIVATE core)

add_executable(nds_gx3d_unit_oracle unit_oracle.cpp Platform.cpp)
target_compile_features(nds_gx3d_unit_oracle PRIVATE cxx_std_17)
target_include_directories(nds_gx3d_unit_oracle PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(nds_gx3d_unit_oracle PRIVATE core)

add_executable(nds_gx3d_geometry_oracle geometry_oracle.cpp Platform.cpp)
target_compile_features(nds_gx3d_geometry_oracle PRIVATE cxx_std_17)
target_include_directories(nds_gx3d_geometry_oracle PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(nds_gx3d_geometry_oracle PRIVATE core)

add_executable(nds_gx3d_polygon_oracle polygon_oracle.cpp Platform.cpp)
target_compile_features(nds_gx3d_polygon_oracle PRIVATE cxx_std_17)
target_include_directories(nds_gx3d_polygon_oracle PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(nds_gx3d_polygon_oracle PRIVATE core)

add_executable(nds_gx3d_render_oracle render_oracle.cpp Platform.cpp)
target_compile_features(nds_gx3d_render_oracle PRIVATE cxx_std_17)
target_include_directories(nds_gx3d_render_oracle PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(nds_gx3d_render_oracle PRIVATE core)

add_executable(nds_gx3d_gxfront_oracle gxfront_oracle.cpp Platform.cpp)
target_compile_features(nds_gx3d_gxfront_oracle PRIVATE cxx_std_17)
target_include_directories(nds_gx3d_gxfront_oracle PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(nds_gx3d_gxfront_oracle PRIVATE core)

# Apple clang 21 at -O2/-O3 miscompiles ClearBuffers' rear-plane image loop
# (GPU3D_Soft.cpp ~3798): the loop vectorizer widens the u8 X/Y scroll
# counters, so the image stops wrapping at 256 (reproduced standalone; GCC 16
# -O3, clang -O1 and UBSan all wrap, and the source has no UB there). The
# oracle must run the source as written, so the loop vectorizer is off for
# that one file.
set_source_files_properties(${MELONDS_DIR}/src/GPU3D_Soft.cpp
    TARGET_DIRECTORY core
    PROPERTIES COMPILE_OPTIONS "$<$<CXX_COMPILER_ID:AppleClang,Clang>:-fno-vectorize>")

add_executable(nds_gx3d_chip_oracle chip_oracle.cpp Platform.cpp)
target_compile_features(nds_gx3d_chip_oracle PRIVATE cxx_std_17)
target_include_directories(nds_gx3d_chip_oracle PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(nds_gx3d_chip_oracle PRIVATE core)
