cmake_minimum_required(VERSION 3.20)

project(nextcar-recorder LANGUAGES CXX)

if (NOT WIN32)
    message(FATAL_ERROR "The nEXTcAR recorder DLL currently supports Windows x64 only")
endif ()

# The recorder is an explicit offline build. Keep UI and unrelated integration
# features disabled while retaining the scripting compiler required for .mr files.
set(DTV OFF CACHE BOOL "Enable video output" FORCE)
set(DISCORD_ENABLED OFF CACHE BOOL "Enable Discord Rich Presence" FORCE)
set(PIRANHA_ENABLED ON CACHE BOOL "Enable scripting input" FORCE)

set(ENGINE_SIM_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
add_subdirectory(
    "${ENGINE_SIM_ROOT}"
    "${CMAKE_BINARY_DIR}/engine-sim-source")

add_library(esrecord-lib SHARED
    esrecord_api.h
    esrecord_internal.h
    esrecord_engine.cpp
    esrecord_record.cpp)

target_link_libraries(esrecord-lib
    PRIVATE
        engine-sim
        engine-sim-script-interpreter
        delta-basic)

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

add_executable(nextcar-recorder-abi-test
    tests/abi_layout.cpp)

target_include_directories(nextcar-recorder-abi-test
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

set_target_properties(nextcar-recorder-abi-test PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)

enable_testing()
add_test(NAME nextcar-recorder-abi COMMAND nextcar-recorder-abi-test)
