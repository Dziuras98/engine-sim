cmake_minimum_required(VERSION 3.20)

project(nextcar-recorder LANGUAGES CXX)

if (NOT WIN32)
    message(FATAL_ERROR "The nEXTcAR recorder DLL currently supports Windows x64 only")
endif ()

# The frozen engine-sim dependency graph contains legacy projects whose policy
# declarations predate CMake 3.5. CMake 4 requires an explicit compatibility
# floor before those projects are configured.
set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING
    "Minimum policy compatibility for frozen engine-sim dependencies" FORCE)

# The recorder is an explicit offline build. Keep UI and unrelated integration
# features disabled while retaining the scripting compiler required for .mr files.
set(ENGINE_SIM_HEADLESS ON CACHE BOOL "Build engine-sim without UI dependencies" FORCE)
set(DTV OFF CACHE BOOL "Enable video output" FORCE)
set(DISCORD_ENABLED OFF CACHE BOOL "Enable Discord Rich Presence" FORCE)
set(PIRANHA_ENABLED ON CACHE BOOL "Enable scripting input" FORCE)

# The historical core target links delta-basic even though its simulation
# sources do not use it. In a headless build, provide an empty compatibility
# target and do not configure delta-studio/SDL2.
add_library(delta-basic INTERFACE)

set(ENGINE_SIM_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
add_subdirectory(
    "${ENGINE_SIM_ROOT}"
    "${CMAKE_BINARY_DIR}/engine-sim-source")

# Piranha commit 432f0b122bb1663b686c553c7e7269300afac3bc uses the
# removed Boost.Filesystem path::is_complete() API. Replace exactly its
# path.cpp translation unit with a recorder-owned compatibility source that
# changes only that call to is_absolute(). The external submodule remains
# immutable and its remaining sources are compiled normally.
get_target_property(PIRANHA_SOURCES piranha SOURCES)
set(PIRANHA_FILTERED_SOURCES)
set(PIRANHA_PATH_SOURCE_COUNT 0)
foreach (PIRANHA_SOURCE IN LISTS PIRANHA_SOURCES)
    get_filename_component(PIRANHA_SOURCE_NAME "${PIRANHA_SOURCE}" NAME)
    if (PIRANHA_SOURCE_NAME STREQUAL "path.cpp")
        math(EXPR PIRANHA_PATH_SOURCE_COUNT "${PIRANHA_PATH_SOURCE_COUNT} + 1")
    else ()
        list(APPEND PIRANHA_FILTERED_SOURCES "${PIRANHA_SOURCE}")
    endif ()
endforeach ()

if (NOT PIRANHA_PATH_SOURCE_COUNT EQUAL 1)
    message(FATAL_ERROR
        "Expected exactly one pinned piranha path.cpp source, observed "
        "${PIRANHA_PATH_SOURCE_COUNT}")
endif ()

set_property(TARGET piranha PROPERTY SOURCES ${PIRANHA_FILTERED_SOURCES})
target_sources(piranha PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/compat/piranha_path_boost_compat.cpp")
target_include_directories(piranha PRIVATE
    "${ENGINE_SIM_ROOT}/dependencies/submodules/piranha/include")

add_library(esrecord-lib SHARED
    esrecord_api.h
    esrecord_internal.h
    esrecord_engine.cpp
    esrecord_record.cpp
    esrecord_translation_unit.cpp
    wav_reader.h
    wav_reader.cpp)

# esrecord_engine.cpp and esrecord_record.cpp are included by the single
# translation unit. Treat them as auditable source inputs, not independent
# compilation units, because frozen units.h/constants.h define externally
# linked constexpr values in headers.
set_source_files_properties(
    esrecord_engine.cpp
    esrecord_record.cpp
    PROPERTIES HEADER_FILE_ONLY TRUE)

target_link_libraries(esrecord-lib
    PRIVATE
        engine-sim
        engine-sim-script-interpreter)

target_include_directories(esrecord-lib
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${ENGINE_SIM_ROOT}
        ${ENGINE_SIM_ROOT}/include
        ${ENGINE_SIM_ROOT}/scripting/include
        ${ENGINE_SIM_ROOT}/dependencies/submodules)

target_compile_definitions(esrecord-lib
    PRIVATE
        ES_ENGINE_SIM_SOURCE_REVISION="31d09faf7b249320a8bf45e2b9bd7dfd8b7ff704"
        ES_ENGINE_SIM_COMPATIBILITY_TARGET="0.1.14a-reference-pending")

if (MSVC)
    target_compile_options(esrecord-lib PRIVATE /W4 /permissive-)
endif ()

set_target_properties(esrecord-lib PROPERTIES
    OUTPUT_NAME "esrecord-lib"
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)

add_executable(nextcar-recorder-abi-layout-test
    tests/abi_layout.cpp)
target_include_directories(nextcar-recorder-abi-layout-test
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
set_target_properties(nextcar-recorder-abi-layout-test PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)

add_executable(nextcar-recorder-abi-runtime-test
    tests/abi_runtime.cpp)
target_link_libraries(nextcar-recorder-abi-runtime-test PRIVATE esrecord-lib)
target_include_directories(nextcar-recorder-abi-runtime-test
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
set_target_properties(nextcar-recorder-abi-runtime-test PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)

enable_testing()
add_test(
    NAME nextcar-recorder-abi-layout
    COMMAND nextcar-recorder-abi-layout-test)
add_test(
    NAME nextcar-recorder-abi-runtime
    COMMAND nextcar-recorder-abi-runtime-test)
