#!/bin/bash
# Builds the decoder library for one system inside the build image, with no network. Mounts:
#   /src        the add-on's source tree (read-only: this folder and the add-on's libav.py)
#   /downloads  the pinned FFmpeg archive (read-only; checked against pin.json before it is unpacked)
#   /work       scratch space for the build
#   /out        where resources/decoder/ for each system is written (/out/SYSTEM)
#   /films      the check films (read-only)
# Usage (make.sh runs it): build.sh SYSTEM
#
# One configure line for every system: FFmpeg's libavformat, libavcodec and libavutil, decode only, six video
# decoders, five demuxers (plus the raw video ones a program stream needs to tell its video codec), the file
# protocol and nothing else (no network, no external libraries, no programs), LGPL 2.1 as FFmpeg's default. The three static libraries are linked into one shared library that exports
# exactly the functions the add-on calls (libav.EXPORTS) and keeps everything else private.
set -euo pipefail
SYSTEM=$1
SHIP=/src/tools/ffmpeg_ship
eval "$(python3 "$SHIP/ship.py" target "$SYSTEM")"
ARCHIVE=/downloads/$(basename "$FFMPEG_URL")
WORK=/work/$SYSTEM
PREFIX=$WORK/prefix
OUT=/out/$SYSTEM
export SOURCE_DATE_EPOCH=1767225600          # 2026-01-01: no build time inside the library
JOBS=${JOBS:-4}

python3 "$SHIP/ship.py" verify "$ARCHIVE" "$FFMPEG_SHA256"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/src" "$PREFIX" "$OUT"
tar -xJf "$ARCHIVE" -C "$WORK/src" --strip-components=1

HARDEN="-ffunction-sections -fdata-sections -ffile-prefix-map=$WORK=."
case "$TOOLCHAIN" in
  gcc)
    CC=gcc; TOOL=(); STRIP=(strip --strip-unneeded)
    CFLAGS="$HARDEN -fstack-protector-strong -D_FORTIFY_SOURCE=2"
    LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack -Wl,--gc-sections"
    ;;
  gcc-aarch64)
    CC=aarch64-linux-gnu-gcc; TOOL=(--cross-prefix=aarch64-linux-gnu- --enable-cross-compile)
    STRIP=(aarch64-linux-gnu-strip --strip-unneeded)
    CFLAGS="$HARDEN -fstack-protector-strong -D_FORTIFY_SOURCE=2"
    LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack -Wl,--gc-sections"
    ;;
  mingw)
    # No stack protector or fortify here: on mingw both pull in libssp, a dependency the DLL must not have.
    CC=x86_64-w64-mingw32-gcc; TOOL=(--cross-prefix=x86_64-w64-mingw32- --enable-cross-compile)
    STRIP=(x86_64-w64-mingw32-strip --strip-unneeded)
    CFLAGS="$HARDEN"
    LDFLAGS="-Wl,--dynamicbase,--nxcompat,--high-entropy-va -Wl,--gc-sections -static-libgcc"
    ;;
  zig)
    # FFmpeg's configure always adds -Wl,-dynamic,-search_paths_first for macOS, which zig's linker refuses (both
    # are its defaults anyway): a wrapper leaves them out.
    CC=$WORK/zigcc
    printf '%s\n' '#!/bin/bash' 'args=()' 'for arg in "$@"; do' \
      '  case "$arg" in -Wl,-dynamic,-search_paths_first|-Wl,-dynamic|-Wl,-search_paths_first) ;; *) args+=("$arg") ;; esac' \
      'done' "exec zig cc -target $ZIG_TARGET.$MACOS_MINIMUM \"\${args[@]}\"" > "$CC"
    chmod +x "$CC"
    TOOL=(--cc="$CC" --ar="zig ar" --ranlib="zig ranlib" --nm=llvm-nm --enable-cross-compile)
    STRIP=()                                  # zig signs the arm64 library at link time; stripping would break it
    CFLAGS="$HARDEN -fstack-protector-strong"
    LDFLAGS="-Wl,-dead_strip"
    ;;
  *) echo "unknown toolchain $TOOLCHAIN"; exit 1 ;;
esac

cd "$WORK/src"
./configure --prefix="$PREFIX" --target-os="$TARGET_OS" --arch="$ARCH" "${TOOL[@]}" \
  --disable-all --enable-avutil --enable-avcodec --enable-avformat \
  --enable-static --disable-shared --enable-pic \
  --enable-decoder=hevc,h264,vc1,mpeg2video,mpeg4,vp9 \
  --enable-parser=hevc,h264,vc1,mpegvideo,mpeg4video,vp9 \
  --enable-demuxer=matroska,mov,mpegts,mpegps,avi,mpegvideo,h264,hevc,m4v \
  --enable-protocol=file --disable-network --disable-hwaccels --disable-autodetect \
  --disable-iconv --disable-zlib --disable-bzlib --disable-lzma --disable-debug --disable-stripping \
  --disable-programs --disable-doc --enable-runtime-cpudetect --enable-"$THREADS" \
  --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" > "$WORK/configure.log" 2>&1 \
  || { tail -40 ffbuild/config.log; exit 1; }
nice -n 10 make -j"$JOBS" > "$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log"; exit 1; }
make install > /dev/null

# One library from the three static ones: roots.txt names every export as undefined, so the linker pulls exactly
# the objects those functions reach; the export list keeps everything else private.
python3 "$SHIP/ship.py" exports "$SYSTEM" "$WORK"
LIBS=$(PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig pkg-config --static --libs libavformat)
LIBRARY_PATH_OUT=$OUT/$LIBRARY
case "$TOOLCHAIN" in
  gcc|gcc-aarch64)
    $CC -shared -o "$LIBRARY_PATH_OUT" -Wl,-soname,"$LIBRARY" -Wl,--version-script="$WORK/exports.map" \
      $(cat "$WORK/roots.txt") -Wl,-Bsymbolic -Wl,--build-id=sha1 $LDFLAGS $LIBS
    ;;
  mingw)
    $CC -shared -o "$LIBRARY_PATH_OUT" "$WORK/exports.def" $(cat "$WORK/roots.txt") -Wl,--exclude-all-symbols \
      -Wl,--no-insert-timestamp $LDFLAGS $LIBS
    ;;
  zig)
    # zig's linker takes no export list (ship.py check_exports says why that is acceptable on macOS).
    # FFmpeg's archives by path: given as -L/-l, zig hands the link to the system's linker, which knows no Mach-O.
    SYSTEM_LIBS=$(printf '%s\n' $LIBS | grep -v -e '^-L' -e '^-lav' | tr '\n' ' ')
    $CC -shared -o "$LIBRARY_PATH_OUT" $(cat "$WORK/roots.txt") -Wl,-install_name,@rpath/"$LIBRARY" $LDFLAGS \
      "$PREFIX/lib/libavformat.a" "$PREFIX/lib/libavcodec.a" "$PREFIX/lib/libavutil.a" $SYSTEM_LIBS
    ;;
esac
if [ ${#STRIP[@]} -gt 0 ]; then "${STRIP[@]}" "$LIBRARY_PATH_OUT"; fi

# The exports, exactly.
case "$TOOLCHAIN" in
  gcc) nm -D --defined-only "$LIBRARY_PATH_OUT" > "$WORK/exports.txt" ;;
  gcc-aarch64) aarch64-linux-gnu-nm -D --defined-only "$LIBRARY_PATH_OUT" > "$WORK/exports.txt" ;;
  mingw) x86_64-w64-mingw32-objdump -p "$LIBRARY_PATH_OUT" > "$WORK/exports.txt" ;;
  zig) llvm-nm -gU "$LIBRARY_PATH_OUT" > "$WORK/exports.txt" ;;
esac
python3 "$SHIP/ship.py" check-exports "$SYSTEM" "$WORK/exports.txt"

# Every structure offset the add-on reads, asserted at compile time with this system's compiler.
python3 "$SHIP/ship.py" layout-c "$SYSTEM" "$WORK/layout_check.c"
$CC -std=c11 -I"$PREFIX/include" -c "$WORK/layout_check.c" -o "$WORK/layout_check.o"
echo "layout: asserted at compile time"

# What only this system's file can show: its dependencies, file type, and for macOS the signature.
python3 -c 'import sys; sys.path.insert(0, "/src/addon/service.activeareasubtitles/resources/lib")
from activearea import libav; print("\n".join(libav.EXPORTS))' > "$WORK/export-names.txt"
case "$TOOLCHAIN" in
  gcc)
    echo "needs: $(readelf -d "$LIBRARY_PATH_OUT" | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | tr '\n' ' ')"
    $CC -std=c11 -I"$PREFIX/include" "$WORK/layout_check.c" -o "$WORK/layout_check" && "$WORK/layout_check"
    $CC -std=gnu11 -I"$PREFIX/include" "$SHIP/smoke.c" -o "$WORK/smoke" -ldl
    : > "$WORK/smoke.txt"
    for film in /films/check*; do
      echo "$(basename "$film") $("$WORK/smoke" "$LIBRARY_PATH_OUT" "$WORK/export-names.txt" "$film")" >> "$WORK/smoke.txt"
    done
    python3 "$SHIP/ship.py" check-smoke /films/films.json "$WORK/smoke.txt"
    ;;
  mingw)
    echo "needs: $(x86_64-w64-mingw32-objdump -p "$LIBRARY_PATH_OUT" | grep 'DLL Name' | awk '{print $3}' | tr '\n' ' ')"
    $CC -std=c11 -I"$PREFIX/include" "$WORK/layout_check.c" -o "$WORK/layout_check.exe"
    $CC -std=gnu11 -I"$PREFIX/include" "$SHIP/smoke.c" -o "$WORK/smoke.exe"
    WINE=$(command -v wine64 || echo /usr/lib/wine/wine64)
    export WINEPREFIX=$WORK/wine WINEDEBUG=-all
    if timeout 300 "$WINE" "$WORK/layout_check.exe" > "$WORK/wine.txt" 2>&1; then
      echo "layout under Wine: $(tr -d '\r' < "$WORK/wine.txt")"
      : > "$WORK/smoke.txt"
      for film in /films/check*; do
        echo "$(basename "$film") $(timeout 120 "$WINE" "$WORK/smoke.exe" "$LIBRARY_PATH_OUT" "$WORK/export-names.txt" "$film" | tr -d '\r')" >> "$WORK/smoke.txt"
      done
      python3 "$SHIP/ship.py" check-smoke /films/films.json "$WORK/smoke.txt"
    else
      echo "Wine did not run here: $(tail -3 "$WORK/wine.txt" | tr '\n' ' ')"
    fi
    ;;
  zig)
    llvm-objdump --macho --private-headers "$LIBRARY_PATH_OUT" > "$WORK/headers.txt"
    echo "macOS: $(grep -A4 LC_BUILD_VERSION "$WORK/headers.txt" | grep -E 'platform|minos' | tr -s ' ' | tr '\n' ' ')"
    grep -q LC_CODE_SIGNATURE "$WORK/headers.txt" && echo "signature: present" \
      || { echo "signature: missing"; [ "$ARCH" != aarch64 ] || exit 1; }
    echo "needs: $(llvm-objdump --macho --dylibs-used "$LIBRARY_PATH_OUT" | tail -n +2 | awk '{print $1}' | tr '\n' ' ')"
    ;;
esac

# The rest of resources/decoder/: the licence, the notice with the source offer, the manifest.
cp "$WORK/src/COPYING.LGPLv2.1" "$OUT/LICENSE.txt"
cat > "$OUT/NOTICE.txt" <<EOF
$LIBRARY is a build of FFmpeg $FFMPEG (libavformat, libavcodec and libavutil), licensed under the GNU Lesser General Public License version 2.1 or later; the licence text is in LICENSE.txt. It is a separate library the add-on loads at run time, and it may be replaced with another build of the same FFmpeg release.

The complete corresponding source is published in the decoder/source folder of the Kodi repository this add-on is installed from: the unmodified FFmpeg $FFMPEG archive, its sha256, and the script and configure line that built this file.
EOF
VERSIONS=$(python3 -c 'import json, subprocess, sys
def first(command):
    try:
        return subprocess.run(command, capture_output=True, text=True).stdout.splitlines()[0].strip()
    except Exception:
        return "?"
cc = sys.argv[1].split()
print(json.dumps({"compiler": first(cc + ["--version"]) if "zig" not in cc[0] else "zig " + first(["zig", "version"]),
                  "nasm": first(["nasm", "-v"])}))' "$CC")
python3 "$SHIP/ship.py" manifest "$SYSTEM" "$OUT" "$LIBRARY_PATH_OUT" "$VERSIONS"
echo "built $SYSTEM: $(stat -c %s "$LIBRARY_PATH_OUT") bytes, sha256 $(sha256sum "$LIBRARY_PATH_OUT" | cut -c1-16)"
