cmake_minimum_required(VERSION 3.15)
project(slipe_lua LANGUAGES C)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "slipe_lua currently supports only Windows x64")
endif()

set(SLIPE_LUA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(LUAJIT_DIR "${SLIPE_LUA_DIR}/src/luajit")
set(LUAJIT_GENERATED "${LUAJIT_DIR}/generated/windows_x64")
set(LUAJIT_BUILDVM_ARCH "${LUAJIT_GENERATED}/buildvm_arch.h")
set(LUAJIT_VM_OBJECT "${CMAKE_CURRENT_BINARY_DIR}/lj_vm.obj")

# LuaJIT's PE/COFF VM is emitted by its host buildvm tool. The pre-generated
# coffasm source is GNU-style and must not be passed to MSVC.
add_executable(slipe_luajit_buildvm
  "${LUAJIT_DIR}/src/host/buildvm.c"
  "${LUAJIT_DIR}/src/host/buildvm_asm.c"
  "${LUAJIT_DIR}/src/host/buildvm_peobj.c"
  "${LUAJIT_DIR}/src/host/buildvm_lib.c"
  "${LUAJIT_DIR}/src/host/buildvm_fold.c"
)
target_include_directories(slipe_luajit_buildvm PRIVATE
  "${LUAJIT_GENERATED}"
  "${LUAJIT_DIR}/src"
  "${LUAJIT_DIR}/dynasm"
)
target_compile_definitions(slipe_luajit_buildvm PRIVATE
  LUAJIT_DISABLE_FFI
  LUAJIT_TARGET=LUAJIT_ARCH_X64
  LUAJIT_OS=LUAJIT_OS_WINDOWS
)

add_custom_command(
  OUTPUT "${LUAJIT_VM_OBJECT}"
  COMMAND slipe_luajit_buildvm -m peobj -o "${LUAJIT_VM_OBJECT}"
  DEPENDS slipe_luajit_buildvm
    "${LUAJIT_BUILDVM_ARCH}"
    "${LUAJIT_DIR}/src/vm_x64.dasc"
  COMMENT "Generating LuaJIT Windows x64 VM object"
  VERBATIM
)
set_source_files_properties("${LUAJIT_VM_OBJECT}" PROPERTIES
  GENERATED TRUE
  EXTERNAL_OBJECT TRUE
)

add_library(slipe_lua SHARED
  "${SLIPE_LUA_DIR}/src/bridge/slipe_lua.c"
  "${SLIPE_LUA_DIR}/src/bridge/json.c"
  "${SLIPE_LUA_DIR}/src/bridge/slipe_lua.h"
  "${LUAJIT_DIR}/src/ljamalg.c"
  "${LUAJIT_VM_OBJECT}"
)
target_include_directories(slipe_lua PRIVATE
  "${SLIPE_LUA_DIR}/src/bridge"
  "${LUAJIT_GENERATED}"
  "${LUAJIT_DIR}/src"
  "${LUAJIT_DIR}/dynasm"
)
target_compile_definitions(slipe_lua PRIVATE
  LUAJIT_DISABLE_FFI
  _CRT_SECURE_NO_WARNINGS
)
set_target_properties(slipe_lua PROPERTIES
  OUTPUT_NAME slipe_lua
  PREFIX ""
  C_STANDARD 99
)

set(slipe_lua_bundled_libraries "$<TARGET_FILE:slipe_lua>" PARENT_SCOPE)
