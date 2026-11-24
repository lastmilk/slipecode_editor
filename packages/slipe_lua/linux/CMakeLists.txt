cmake_minimum_required(VERSION 3.13)
project(slipe_lua LANGUAGES C ASM)

if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
  message(FATAL_ERROR "slipe_lua currently supports only Linux x64")
endif()

set(SLIPE_LUA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(LUAJIT_DIR "${SLIPE_LUA_DIR}/src/luajit")
set(LUAJIT_GENERATED "${LUAJIT_DIR}/generated/linux_x64")

add_library(slipe_lua SHARED
  "${SLIPE_LUA_DIR}/src/bridge/slipe_lua.c"
  "${SLIPE_LUA_DIR}/src/bridge/json.c"
  "${LUAJIT_DIR}/src/ljamalg.c"
  "${LUAJIT_GENERATED}/lj_vm.S"
)

target_include_directories(slipe_lua PRIVATE
  "${SLIPE_LUA_DIR}/src/bridge"
  "${LUAJIT_GENERATED}"
  "${LUAJIT_DIR}/src"
  "${LUAJIT_DIR}/dynasm"
)
target_compile_definitions(slipe_lua PRIVATE
  LUAJIT_DISABLE_FFI
  LUAJIT_UNWIND_EXTERNAL
  _FILE_OFFSET_BITS=64
  _LARGEFILE_SOURCE
)
target_compile_options(slipe_lua PRIVATE
  -fno-strict-aliasing
  -fPIC
  -U_FORTIFY_SOURCE
)
set_target_properties(slipe_lua PROPERTIES
  OUTPUT_NAME slipe_lua
  POSITION_INDEPENDENT_CODE ON
  C_STANDARD 99
  C_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES
)
target_link_libraries(slipe_lua PRIVATE m dl)

# Flutter 的 ffiPlugin 会把该目标复制到应用 bundle 的 lib/。
set(slipe_lua_bundled_libraries "$<TARGET_FILE:slipe_lua>" PARENT_SCOPE)
