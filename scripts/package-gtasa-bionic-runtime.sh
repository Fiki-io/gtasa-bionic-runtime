#!/usr/bin/env bash
set -euo pipefail

DEB_DIR="${1:-$(pwd)/debs}"
DLL_DIR="${2:-$(pwd)/out-dlls}"
OUTPUT_DIR="${3:-$(pwd)/dist}"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

mkdir -p "${OUTPUT_DIR}" "${STAGING_DIR}/rootfs"

if [ ! -f "${DLL_DIR}/wowbox64.dll" ] || [ ! -f "${DLL_DIR}/libwow64fex.dll" ]; then
    echo "ERROR: Missing wowbox64.dll or libwow64fex.dll in ${DLL_DIR}" >&2
    exit 1
fi

shopt -s nullglob
DEB_FILES=("${DEB_DIR}"/*.deb)
if [ "${#DEB_FILES[@]}" -eq 0 ]; then
    echo "ERROR: No .deb packages found in ${DEB_DIR}" >&2
    exit 1
fi

for deb in "${DEB_FILES[@]}"; do
    dpkg-deb -x "${deb}" "${STAGING_DIR}/extracted"
done

USR_ROOT="${STAGING_DIR}/extracted/data/data/com.termux/files/usr"
if [ ! -d "${USR_ROOT}" ]; then
    echo "ERROR: Expected Bionic usr root not found at ${USR_ROOT}" >&2
    exit 1
fi

cp -a "${USR_ROOT}/." "${STAGING_DIR}/rootfs/"

WINE_ROOT="${STAGING_DIR}/rootfs/opt/hangover-wine"
if [ ! -d "${WINE_ROOT}" ]; then
    WINE_ROOT="${STAGING_DIR}/rootfs"
fi

WINE_AARCH64_WIN="${WINE_ROOT}/lib/wine/aarch64-windows"
if [ ! -d "${WINE_AARCH64_WIN}" ]; then
    echo "ERROR: Wine aarch64-windows directory not found at ${WINE_AARCH64_WIN}" >&2
    exit 1
fi

cp -f "${DLL_DIR}/wowbox64.dll" "${WINE_AARCH64_WIN}/wowbox64.dll"
cp -f "${DLL_DIR}/libwow64fex.dll" "${WINE_AARCH64_WIN}/libwow64fex.dll"

if [ -f "${DLL_DIR}/dxvk-hangover.tar.gz" ]; then
    mkdir -p "${STAGING_DIR}/rootfs/share/gtasa-runtime/dxvk"
    tar -xzf "${DLL_DIR}/dxvk-hangover.tar.gz" -C "${STAGING_DIR}/rootfs/share/gtasa-runtime/dxvk" --strip-components=1 || \
    tar -xzf "${DLL_DIR}/dxvk-hangover.tar.gz" -C "${STAGING_DIR}/rootfs/share/gtasa-runtime/dxvk"
fi

rm -rf "${STAGING_DIR}/rootfs/include" \
       "${WINE_ROOT}/include" \
       "${STAGING_DIR}/rootfs/share/man" \
       "${WINE_ROOT}/share/man" \
       "${STAGING_DIR}/rootfs/share/doc" \
       "${STAGING_DIR}/rootfs/share/info" \
       "${STAGING_DIR}/rootfs/lib/pkgconfig"

find "${STAGING_DIR}/rootfs" -name "*.a" -type f -delete

UNUSED_PE_BINS=(
    "wordpad.exe"
    "notepad.exe"
    "winemine.exe"
    "iexplore.exe"
    "wmplayer.exe"
    "oleview.exe"
    "winedbg.exe"
    "powershell.exe"
    "wscript.exe"
    "cscript.exe"
)

for bin in "${UNUSED_PE_BINS[@]}"; do
    find "${WINE_ROOT}/lib/wine" -name "${bin}" -type f -delete
done

REQUIRED_GTA_SA_MODULES=(
    "ntdll.dll"
    "kernel32.dll"
    "kernelbase.dll"
    "user32.dll"
    "gdi32.dll"
    "advapi32.dll"
    "winmm.dll"
    "dsound.dll"
    "dinput.dll"
    "dinput8.dll"
    "d3d8.dll"
    "d3d9.dll"
    "ddraw.dll"
    "wined3d.dll"
    "ws2_32.dll"
    "wsock32.dll"
    "iphlpapi.dll"
    "wininet.dll"
    "imm32.dll"
    "ole32.dll"
    "oleaut32.dll"
    "rpcrt4.dll"
    "shlwapi.dll"
    "shell32.dll"
    "comctl32.dll"
    "comdlg32.dll"
    "version.dll"
    "setupapi.dll"
    "msvcrt.dll"
    "ucrtbase.dll"
    "winex11.drv"
    "wowbox64.dll"
    "libwow64fex.dll"
)

for mod in "${REQUIRED_GTA_SA_MODULES[@]}"; do
    FOUND_MOD="$(find "${WINE_ROOT}/lib/wine" -name "${mod}" -type f | head -n 1)"
    if [ -z "${FOUND_MOD}" ] || [ ! -s "${FOUND_MOD}" ]; then
        echo "ERROR: Mandatory GTA SA / SA-MP Wine module missing: ${mod}" >&2
        exit 1
    fi
done

echo "Verifying Bionic ELF DT_NEEDED dependencies for Wine unix libraries..."
ANDROID_SYSTEM_LIBS="^(libc\.so|libm\.so|libdl\.so|liblog\.so|libandroid\.so|libEGL\.so|libGLESv1_CM\.so|libGLESv2\.so|libGLESv3\.so|libvulkan\.so|libOpenSLES\.so|libaaudio\.so|libjnigraphics\.so|libmediandk\.so|libnativewindow\.so|libsync\.so|libz\.so)$"
MISSING_ELF_DEPS=0

for elf in "${WINE_ROOT}/bin/wine" "${WINE_ROOT}/lib/wine/aarch64-unix"/*.so; do
    [ -f "${elf}" ] || continue
    NEEDED_LIBS="$(readelf -d "${elf}" 2>/dev/null | awk '/\(NEEDED\)/ {gsub(/\[|\]/, "", $5); print $5}')"
    for needed in ${NEEDED_LIBS}; do
        if [[ "${needed}" =~ ${ANDROID_SYSTEM_LIBS} ]]; then
            continue
        fi
        if [ ! -e "${STAGING_DIR}/rootfs/lib/${needed}" ] && \
           [ ! -e "${WINE_ROOT}/lib/${needed}" ] && \
           [ ! -e "${WINE_ROOT}/lib/wine/aarch64-unix/${needed}" ]; then
            echo "ERROR: ${elf} requires missing Bionic library: ${needed}" >&2
            MISSING_ELF_DEPS=1
        fi
    done
done

if [ "${MISSING_ELF_DEPS}" -ne 0 ]; then
    echo "ERROR: ELF dependency verification failed" >&2
    exit 1
fi
echo "All Bionic ELF DT_NEEDED dependencies verified."

mkdir -p "${STAGING_DIR}/rootfs/share/gtasa-runtime"

cat << 'EOF' > "${STAGING_DIR}/rootfs/share/gtasa-runtime/gtasa-mali.reg"
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\Software\Microsoft\Wow64\x86]
@="wowbox64.dll"

[HKEY_CURRENT_USER\Software\Wine\Direct3D]
"DirectDrawRenderer"="opengl"
"csmt"=dword:00000003
"MaxVersionGL"=dword:00030002
"VideoMemorySize"="512"
"OffscreenRenderingMode"="fbo"
"AlwaysOffscreen"="enabled"
"StrictDrawOrdering"="disabled"

[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"MouseWarpOverride"="enable"
"Decorated"="N"
"Managed"="N"
"UseTakeFocus"="N"
"ClientSideWithRender"="Y"

[HKEY_CURRENT_USER\Software\Wine\Drivers]
"Audio"="pulse,alsa"
EOF

cat << 'EOF' > "${STAGING_DIR}/rootfs/share/gtasa-runtime/env-mali.conf"
# Box64 Dynarec Tuning for GTA SA (RenderWare D3D9 + samp.dll hooks)
BOX64_DYNAREC=1
BOX64_DYNAREC_SAFEFLAGS=1
BOX64_DYNAREC_FASTNAN=1
BOX64_DYNAREC_FASTROUND=1
BOX64_DYNAREC_X87DOUBLE=0
BOX64_DYNAREC_BIGBLOCK=2
BOX64_DYNAREC_STRONGMEM=1
BOX64_DYNAREC_FORWARD=512
BOX64_DYNAREC_CALLRET=1
BOX64_DYNAREC_BLEEDING_EDGE=0
BOX64_AVX=0
BOX64_SSE42=1
BOX64_NOBANNER=1
BOX64_LOG=0

# Wine & Bionic Environment
WINEDEBUG=-all
WINEESYNC=1
WINEESYNC_TERMUX=1
HODLL=wowbox64.dll

# Mali Graphics Profiles (virgl-gles or zink-vulkan)
MESA_GL_VERSION_OVERRIDE=3.3COMPAT
MESA_GLES_VERSION_OVERRIDE=3.2
MESA_NO_ERROR=1
EOF

ARCHIVE_NAME="gtasa-bionic-runtime-arm64.tar.xz"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"

XZ_OPT="-T0 -6" tar -C "${STAGING_DIR}/rootfs" -cJf "${ARCHIVE_PATH}" .

if [ ! -s "${ARCHIVE_PATH}" ]; then
    echo "ERROR: Failed to create runtime archive at ${ARCHIVE_PATH}" >&2
    exit 1
fi

ARCHIVE_SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
ARCHIVE_SIZE="$(stat -c%s "${ARCHIVE_PATH}")"
echo "${ARCHIVE_SHA256}  ${ARCHIVE_NAME}" > "${ARCHIVE_PATH}.sha256"

cat << EOF > "${OUTPUT_DIR}/runtime-manifest.json"
{
  "name": "gtasa-bionic-runtime-arm64",
  "version": "11.16",
  "architecture": "arm64-v8a",
  "executionMode": "bionic-hangover-zero-proot",
  "wineBinaryRelativePath": "opt/hangover-wine/bin/wine",
  "emulators": [
    "wowbox64.dll",
    "libwow64fex.dll"
  ],
  "graphicsBackends": [
    "virgl-gles32-mali",
    "zink-vulkan-mali"
  ],
  "archiveFileName": "${ARCHIVE_NAME}",
  "archiveSizeBytes": ${ARCHIVE_SIZE},
  "sha256": "${ARCHIVE_SHA256}"
}
EOF
