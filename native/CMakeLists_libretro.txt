# YAGE Libretro Wrapper CMake Configuration
cmake_minimum_required(VERSION 3.16)
project(yage_core C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Build shared library
add_library(yage_core SHARED
    yage_libretro.c
    yage_libretro.h
)

# Export symbols on Windows
if(WIN32)
    target_compile_definitions(yage_core PRIVATE YAGE_EXPORTS)
endif()

# Link libraries
if(WIN32)
    # No additional libs needed - we load libretro dynamically
elseif(ANDROID)
    target_link_libraries(yage_core PRIVATE dl log)
else()
    target_link_libraries(yage_core PRIVATE dl)
endif()

# Set output directory
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

