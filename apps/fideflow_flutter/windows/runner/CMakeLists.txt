cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "desktop_controls.cpp"
  "main.cpp"
  "single_instance.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "comctl32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib" "shcore.lib" "shlwapi.lib")
target_compile_features(${BINARY_NAME} PRIVATE cxx_std_20)
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Opt-in native integration probe; never included in the distributable bundle.
add_executable(ff_desktop_probe EXCLUDE_FROM_ALL
  "desktop_controls_probe.cpp" "desktop_controls.cpp")
apply_standard_settings(ff_desktop_probe)
target_compile_features(ff_desktop_probe PRIVATE cxx_std_20)
target_compile_options(ff_desktop_probe PRIVATE /utf-8)
target_compile_definitions(ff_desktop_probe PRIVATE NOMINMAX)
target_link_libraries(ff_desktop_probe PRIVATE flutter flutter_wrapper_app windowsapp shcore shlwapi dwmapi)
set_target_properties(ff_desktop_probe PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${FF_REPO_ROOT}/native/build/windows-desktop-probe")

add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass
    -File "${FF_REPO_ROOT}/tooling/native/windows/stage.ps1"
    -StageDir "$<TARGET_FILE_DIR:${BINARY_NAME}>" -Configuration "$<CONFIG>"
  VERBATIM)
