# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "fideflow")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.moetaku.fideflow")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")
set(CMAKE_BUILD_RPATH_USE_ORIGIN ON)

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# The pinned Rust host and ELF dependencies are built into the relocatable Linux
# bundle. Flutter's normal build runs this target before the install step.
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
  set(FF_LINUX_ARCH "x86_64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  set(FF_LINUX_ARCH "aarch64")
else()
  message(FATAL_ERROR "Unsupported Fideflow Linux architecture: ${CMAKE_SYSTEM_PROCESSOR}")
endif()
if(NOT CMAKE_SYSTEM_PROCESSOR STREQUAL CMAKE_HOST_SYSTEM_PROCESSOR AND
   NOT (CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64" AND CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64") AND
   NOT (CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64" AND CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "aarch64"))
  message(FATAL_ERROR "Linux native dependencies must be built on a native ${FF_LINUX_ARCH} runner")
endif()
set(FF_NATIVE_PREFIX "${CMAKE_SOURCE_DIR}/../../../native/build/third_party/linux/${FF_LINUX_ARCH}")
set(FF_NATIVE_SKIP OFF)
if(CMAKE_BUILD_TYPE STREQUAL "Debug" AND "$ENV{FF_ALLOW_MISSING_NATIVE}" STREQUAL "1")
  set(FF_NATIVE_SKIP ON)
endif()
if(NOT FF_NATIVE_SKIP)
  if(CMAKE_BUILD_TYPE STREQUAL "Release")
    set(FF_RUST_PROFILE release)
    set(FF_RUST_LIBRARY "${CMAKE_SOURCE_DIR}/../../../native/media_core/target/${FF_LINUX_ARCH}-unknown-linux-gnu/release/libff_media_core.so")
  else()
    set(FF_RUST_PROFILE debug)
    set(FF_RUST_LIBRARY "${CMAKE_SOURCE_DIR}/../../../native/media_core/target/${FF_LINUX_ARCH}-unknown-linux-gnu/debug/libff_media_core.so")
  endif()
  # Cargo's default target directory is host-triple independent; the explicit
  # target path is used only when CMake receives an architecture-specific target.
  if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64" AND CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "x86_64")
    set(FF_RUST_LIBRARY "${CMAKE_SOURCE_DIR}/../../../native/media_core/target/${FF_RUST_PROFILE}/libff_media_core.so")
  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$" AND CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
    set(FF_RUST_LIBRARY "${CMAKE_SOURCE_DIR}/../../../native/media_core/target/${FF_RUST_PROFILE}/libff_media_core.so")
  endif()
  add_custom_target(ff_media_core ALL
    COMMAND "${CMAKE_SOURCE_DIR}/../../../tooling/native/linux/rust.sh"
      --profile "${FF_RUST_PROFILE}" --prefix "${FF_NATIVE_PREFIX}"
    BYPRODUCTS "${FF_RUST_LIBRARY}"
    VERBATIM)
  add_dependencies(${BINARY_NAME} ff_media_core)
else()
  message(STATUS "FF_ALLOW_MISSING_NATIVE=1: Debug bundle will omit the unavailable native decoder")
endif()


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

# Keep the Linux runner icon beside the executable so GTK can load it from
# both `flutter run` output and the relocatable installed bundle.
set(FIDEFLOW_LINUX_ICON "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/fideflow.png")
install(FILES "${FIDEFLOW_LINUX_ICON}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/install-desktop-entry.py"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Native install rules must follow BUILD_BUNDLE_DIR cleanup and the bundle path
# initialization above, or the staged libraries are erased during install.
if(NOT FF_NATIVE_SKIP)
  install(FILES "${FF_RUST_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
  install(DIRECTORY "${FF_NATIVE_PREFIX}/lib/" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime FILES_MATCHING PATTERN "*.so*")
  install(DIRECTORY "${FF_NATIVE_PREFIX}/licenses/" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licenses"
    COMPONENT Runtime)
  string(TOLOWER "${CMAKE_BUILD_TYPE}" FF_BUNDLE_BUILD_MODE)
  install(CODE "
    execute_process(COMMAND python3 \"${CMAKE_SOURCE_DIR}/../../../tooling/native/linux/verify_bundle.py\"
      \"${CMAKE_INSTALL_PREFIX}\" --fixup --build-mode \"${FF_BUNDLE_BUILD_MODE}\" RESULT_VARIABLE bundle_verify_status)
    if(NOT bundle_verify_status EQUAL 0)
      message(FATAL_ERROR \"Linux native bundle verification failed\")
    endif()
  " COMPONENT Runtime)
endif()
