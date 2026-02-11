# YAGE Libretro Wrapper + rcheevos CMake Configuration
cmake_minimum_required(VERSION 3.16)
project(yage_core C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ── rcheevos source files ──────────────────────────────────────────────
# We compile rcheevos as part of yage_core (static linking).
# Only the core sources are needed — no test/validator/hash.
set(RCHEEVOS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/rcheevos)

set(RCHEEVOS_SOURCES
    # Core rcheevos (condition parser, evaluator, runtime)
    ${RCHEEVOS_DIR}/src/rcheevos/alloc.c
    ${RCHEEVOS_DIR}/src/rcheevos/condition.c
    ${RCHEEVOS_DIR}/src/rcheevos/condset.c
    ${RCHEEVOS_DIR}/src/rcheevos/consoleinfo.c
    ${RCHEEVOS_DIR}/src/rcheevos/format.c
    ${RCHEEVOS_DIR}/src/rcheevos/lboard.c
    ${RCHEEVOS_DIR}/src/rcheevos/memref.c
    ${RCHEEVOS_DIR}/src/rcheevos/operand.c
    ${RCHEEVOS_DIR}/src/rcheevos/richpresence.c
    ${RCHEEVOS_DIR}/src/rcheevos/runtime.c
    ${RCHEEVOS_DIR}/src/rcheevos/runtime_progress.c
    ${RCHEEVOS_DIR}/src/rcheevos/trigger.c
    ${RCHEEVOS_DIR}/src/rcheevos/value.c
    # rc_client (high-level API)
    ${RCHEEVOS_DIR}/src/rc_client.c
    ${RCHEEVOS_DIR}/src/rc_compat.c
    ${RCHEEVOS_DIR}/src/rc_util.c
    ${RCHEEVOS_DIR}/src/rc_version.c
    # API request/response serialization
    ${RCHEEVOS_DIR}/src/rapi/rc_api_common.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_editor.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_info.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_runtime.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_user.c
    # Hash utilities (MD5 — required by rc_api_editor and runtime)
    ${RCHEEVOS_DIR}/src/rhash/md5.c
)

# ── Build shared library ───────────────────────────────────────────────
add_library(yage_core SHARED
    yage_libretro.c
    yage_libretro.h
    yage_rcheevos.c
    yage_rcheevos.h
    ${RCHEEVOS_SOURCES}
)

# ── Include paths ──────────────────────────────────────────────────────
target_include_directories(yage_core PRIVATE
    ${RCHEEVOS_DIR}/include
    ${RCHEEVOS_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# ── Compile definitions ───────────────────────────────────────────────
# Build rcheevos as static (compiled into yage_core shared lib).
target_compile_definitions(yage_core PRIVATE
    RC_STATIC
)

# Export symbols on Windows
if(WIN32)
    target_compile_definitions(yage_core PRIVATE YAGE_EXPORTS)
endif()

# ── Link libraries ────────────────────────────────────────────────────
if(WIN32)
    # No additional libs needed - we load libretro dynamically
elseif(ANDROID)
    # pthread is part of Bionic libc (no explicit link needed)
    # 'android' provides ANativeWindow for zero-copy texture rendering
    target_link_libraries(yage_core PRIVATE dl log OpenSLES android)
else()
    # Linux / macOS — link pthread for the native frame loop thread
    find_package(Threads REQUIRED)
    target_link_libraries(yage_core PRIVATE dl Threads::Threads)
endif()

# ── Output directory ──────────────────────────────────────────────────
set_target_properties(yage_core PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

# For Android NDK build
if(ANDROID)
    set_target_properties(yage_core PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
    )
endif()
