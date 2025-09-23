#!/usr/bin/env dash
# generate-toolchain-baremetal.sh
set -eu

OUT="/home/builder/libarchive/toolchain-baremetal.cmake"
LLVM_BINDIR="/home/builder/llvm/bin"
LLD="${LLVM_BINDIR}/lld"
CLANG="${LLVM_BINDIR}/clang"
CLANGPP="${LLVM_BINDIR}/clang++"
AR="${LLVM_BINDIR}/llvm-ar"
RANLIB="${LLVM_BINDIR}/llvm-ranlib"
STRIP="${LLVM_BINDIR}/llvm-strip"

uname_m="$(uname -m 2>/dev/null || echo unknown)"

case "$uname_m" in
  x86_64|amd64)
    CMAKE_PROC="x86_64"
    TRIPLE="x86_64-none-musl"
    ;;
  aarch64|arm64)
    CMAKE_PROC="aarch64"
    TRIPLE="aarch64-none-musl"
    ;;
  armv7l|armv7)
    CMAKE_PROC="armv7"
    TRIPLE="arm-none-musleabihf"
    ;;
  *)
    CMAKE_PROC="$uname_m"
    TRIPLE="${uname_m}-none-musl"
    ;;
esac

if [ ! -x "$CLANG" ]; then
  echo "Warning: $CLANG not found or not executable. The generated file will still be written." >&2
fi

cat > "$OUT" <<EOF
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR ${CMAKE_PROC})
set(CMAKE_C_COMPILER ${CLANG})
set(CMAKE_CXX_COMPILER ${CLANGPP})
set(CMAKE_AR ${AR})
set(CMAKE_RANLIB ${RANLIB})
set(CMAKE_STRIP ${STRIP})
set(CMAKE_LINKER ${LLD})
set(CMAKE_C_COMPILER_TARGET ${TRIPLE})
set(CMAKE_CXX_COMPILER_TARGET ${TRIPLE})
set(CMAKE_EXE_LINKER_FLAGS "-static -nostdlib -fPIC -fuse-ld=lld")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_CROSSCOMPILING TRUE)

# Adjust the search paths
set(CMAKE_FIND_ROOT_PATH /home/builder/llvm/)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

## refuse these:
set(NETTLE_FOUND FALSE)
set(MBEDTLS_FOUND FALSE)
set(HAVE_LIBMBEDCRYPTO FALSE)

EOF

echo "Wrote $OUT (processor=${CMAKE_PROC}, target=${TRIPLE})"
