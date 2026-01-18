# YAGE Core Native Library CMake Configuration
cmake_minimum_required(VERSION 3.16)
project(yage_core C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Build shared library
add_library(yage_core SHARED
    yage_core.c
    yage_core.h
)

# Export symbols on Windows
if(WIN32)
    target_compile_definitions(yage_core PRIVATE YAGE_EXPORTS)
endif()

# Find mGBA library
# Users need to build mGBA first and set MGBA_DIR to point to the build
if(NOT MGBA_DIR)
    message(FATAL_ERROR "MGBA_DIR not set. Please set it to the mGBA build directory.")
endif()

# Include mGBA headers
target_include_directories(yage_core PRIVATE
    ${MGBA_DIR}/include
    ${MGBA_DIR}/src
)

# Link mGBA library
if(WIN32)
    target_link_libraries(yage_core PRIVATE
        ${MGBA_DIR}/mgba.lib
    )
elseif(APPLE)
    target_link_libraries(yage_core PRIVATE
        ${MGBA_DIR}/libmgba.dylib
    )
else()
    target_link_libraries(yage_core PRIVATE
        ${MGBA_DIR}/libmgba.so
    )
endif()

# Set output directory
set_target_properties(yage_core PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

# Install targets
install(TARGETS yage_core
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION lib
)

