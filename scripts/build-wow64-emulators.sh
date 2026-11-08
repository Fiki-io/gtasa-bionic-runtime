#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${1:-$(pwd)/build-work}"
OUTPUT_DIR="${2:-$(pwd)/out-dlls}"
HANGOVER_TAG="${HANGOVER_TAG:-hangover-11.16}"
HANGOVER_VER="${HANGOVER_TAG#hangover-}"

MSTORSJO_VER="20261104"
MSTORSJO_TAR="llvm-mingw-${MSTORSJO_VER}-ucrt-ubuntu-22.04-x86_64.tar.xz"
MSTORSJO_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${MSTORSJO_VER}/${MSTORSJO_TAR}"

HANGOVER_DLLS_URL="https://github.com/AndreRH/hangover/releases/download/${HANGOVER_TAG}/hangover_${HANGOVER_VER}_dlls.tar"

mkdir -p "${WORKDIR}" "${OUTPUT_DIR}"
cd "${WORKDIR}"

if [ ! -d "${WORKDIR}/llvm-mingw" ]; then
    curl -fL --retry 3 -o "${MSTORSJO_TAR}" "${MSTORSJO_URL}"
    mkdir -p "${WORKDIR}/llvm-mingw"
    tar -xf "${MSTORSJO_TAR}" -C "${WORKDIR}/llvm-mingw" --strip-components=1
fi

export PATH="${WORKDIR}/llvm-mingw/bin:${PATH}"

if ! command -v aarch64-w64-mingw32-clang >/dev/null 2>&1; then
    echo "ERROR: aarch64-w64-mingw32-clang not found in PATH" >&2
    exit 1
fi

if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    echo "ERROR: aarch64-linux-gnu-gcc not found in PATH" >&2
    exit 1
fi

if [ ! -d "${WORKDIR}/hangover" ]; then
    git clone --branch "${HANGOVER_TAG}" --depth 1 "${HANGOVER_GIT_URL:-https://github.com/AndreRH/hangover.git}" "${WORKDIR}/hangover"
    cd "${WORKDIR}/hangover"
    git submodule update --init --recursive --depth 1 box64
fi

cd "${WORKDIR}/hangover"
if [ -f "box64/src/build_info.h" ]; then
    sed -i "s/GITREV/\"(Hangover ${HANGOVER_VER})\"/g" box64/src/build_info.h
fi

mkdir -p "${WORKDIR}/hangover/box64/build_pe"
cd "${WORKDIR}/hangover/box64/build_pe"
cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
      -DARM_DYNAREC=ON \
      -DWOW64=ON \
      ..
make -j"$(nproc)" wowbox64

WOWBOX64_FOUND="$(find "${WORKDIR}/hangover/box64/build_pe" -name "wowbox64.dll" -type f | head -n 1)"
if [ -z "${WOWBOX64_FOUND}" ] || [ ! -s "${WOWBOX64_FOUND}" ]; then
    echo "ERROR: wowbox64.dll build failed or produced empty binary" >&2
    exit 1
fi
aarch64-w64-mingw32-strip --strip-unneeded "${WOWBOX64_FOUND}"
cp -f "${WOWBOX64_FOUND}" "${OUTPUT_DIR}/wowbox64.dll"

mkdir -p "${WORKDIR}/upstream-dlls"
cd "${WORKDIR}/upstream-dlls"
curl -fL --retry 3 -o "hangover_dlls.tar" "${HANGOVER_DLLS_URL}"
tar -xf "hangover_dlls.tar"

if [ ! -s "${WORKDIR}/upstream-dlls/libwow64fex.dll" ]; then
    echo "ERROR: libwow64fex.dll not found in upstream hangover_dlls.tar" >&2
    exit 1
fi
cp -f "${WORKDIR}/upstream-dlls/libwow64fex.dll" "${OUTPUT_DIR}/libwow64fex.dll"

DXVK_TAR="$(find "${WORKDIR}/upstream-dlls" -name "dxvk*.tar.gz" -type f | head -n 1)"
if [ -n "${DXVK_TAR}" ] && [ -s "${DXVK_TAR}" ]; then
    cp -f "${DXVK_TAR}" "${OUTPUT_DIR}/dxvk-hangover.tar.gz"
fi

sha256sum "${OUTPUT_DIR}"/* > "${OUTPUT_DIR}/SHA256SUMS"
cat "${OUTPUT_DIR}/SHA256SUMS"
