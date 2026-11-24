#!/usr/bin/env sh
# Regenerate the checked-in LuaJIT sources without downloading anything.
set -eu

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LUAJIT_DIR="$PACKAGE_DIR/src/luajit"
SRC="$LUAJIT_DIR/src"
WORK="$PACKAGE_DIR/build/luajit-generator"
CC=${CC:-cc}

mkdir -p "$WORK"
"$CC" -O2 -o "$WORK/minilua" "$SRC/host/minilua.c" -lm

LIB_SOURCES="
lib_base.c lib_math.c lib_bit.c lib_string.c lib_table.c
lib_io.c lib_os.c lib_package.c lib_debug.c lib_jit.c lib_ffi.c lib_buffer.c
"

generate_target() {
  name=$1
  dasc=$2
  vm_mode=$3
  shift 3

  out="$LUAJIT_DIR/generated/$name"
  target_work="$WORK/$name"
  mkdir -p "$out" "$target_work"

  "$WORK/minilua" "$SRC/host/genversion.lua" \
    "$SRC/luajit_rolling.h" "$LUAJIT_DIR/.relver" "$out/luajit.h"

  # FFI is disabled at compile time as well as being hidden by the bridge.
  "$WORK/minilua" "$LUAJIT_DIR/dynasm/dynasm.lua" -LN \
    -D ENDIAN_LE -D P64 -D JIT -D FPU -D HFABI "$@" \
    -o "$target_work/buildvm_arch.h" "$SRC/$dasc"
  if [ "$name" = windows_x64 ]; then
    cp "$target_work/buildvm_arch.h" "$out/buildvm_arch.h"
  fi

  # buildvm is a host tool which emits code for the selected target.
  # macOS and Windows targets set their target macros explicitly.
  case "$name" in
    macos_arm64)
      target_defines="-DLUAJIT_TARGET=LUAJIT_ARCH_ARM64 -DLUAJIT_OS=LUAJIT_OS_OSX -DLUAJIT_UNWIND_EXTERNAL"
      ;;
    macos_x64)
      target_defines="-DLUAJIT_TARGET=LUAJIT_ARCH_X64 -DLUAJIT_OS=LUAJIT_OS_OSX -DLUAJIT_UNWIND_EXTERNAL"
      ;;
    windows_x64)
      target_defines="-DLUAJIT_TARGET=LUAJIT_ARCH_X64 -DLUAJIT_OS=LUAJIT_OS_WINDOWS"
      ;;
    linux_x64)
      target_defines="-DLUAJIT_UNWIND_EXTERNAL"
      ;;
    *)
      target_defines=""
      ;;
  esac

  # Intentional word splitting: these are compiler flags, not user data.
  # shellcheck disable=SC2086
  "$CC" -O2 -DLUAJIT_DISABLE_FFI $target_defines \
    -I"$target_work" -I"$out" -I"$SRC" -I"$LUAJIT_DIR/dynasm" \
    -o "$target_work/buildvm" \
    "$SRC/host/buildvm.c" "$SRC/host/buildvm_asm.c" \
    "$SRC/host/buildvm_peobj.c" "$SRC/host/buildvm_lib.c" \
    "$SRC/host/buildvm_fold.c"

  absolute_libs=""
  for source in $LIB_SOURCES; do
    absolute_libs="$absolute_libs $SRC/$source"
  done

  # Intentional word splitting: buildvm expects separate source arguments.
  # shellcheck disable=SC2086
  "$target_work/buildvm" -m bcdef -o "$out/lj_bcdef.h" $absolute_libs
  # shellcheck disable=SC2086
  "$target_work/buildvm" -m ffdef -o "$out/lj_ffdef.h" $absolute_libs
  # shellcheck disable=SC2086
  "$target_work/buildvm" -m libdef -o "$out/lj_libdef.h" $absolute_libs
  # shellcheck disable=SC2086
  "$target_work/buildvm" -m recdef -o "$out/lj_recdef.h" $absolute_libs
  "$target_work/buildvm" -m folddef -o "$out/lj_folddef.h" "$SRC/lj_opt_fold.c"
  "$target_work/buildvm" -m "$vm_mode" -o "$out/lj_vm.$vm_extension"
}

# DynASM's Windows flag and output extension differ from POSIX targets.
vm_extension=S
generate_target linux_x64 vm_x64.dasc elfasm
generate_target macos_x64 vm_x64.dasc machasm
generate_target macos_arm64 vm_arm64.dasc machasm
vm_extension=asm
generate_target windows_x64 vm_x64.dasc coffasm -D WIN
