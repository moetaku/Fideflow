#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/bin:/bin:$PATH
export PKG_CONFIG_LIBDIR="$FF_FFMPEG_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=
# Upstream MSVC installers do not emit pkg-config metadata. Describe only
# libraries built in this prefix; no system or MinGW libraries are searched.
mkdir -p "$PKG_CONFIG_LIBDIR"
cat > "$PKG_CONFIG_LIBDIR/soxr.pc" <<EOF
prefix=$FF_FFMPEG_PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: soxr
Description: Pinned MSVC soxr
Version: 0.1.3
Libs: -L\${libdir} -lsoxr
Cflags: -I\${includedir}
EOF
cd "$FF_FFMPEG_BUILD"
args=(--toolchain=msvc --arch=x86_64 --target-os=win64
      "--prefix=$FF_FFMPEG_PREFIX" --enable-shared --disable-static
      --disable-everything --disable-autodetect --disable-programs --disable-doc
      --disable-debug --disable-avdevice --disable-avfilter --disable-postproc
      --disable-gpl --disable-nonfree --disable-version3 --disable-network
      --disable-openssl --disable-schannel --disable-securetransport --enable-libsoxr --enable-swresample
      "--extra-cflags=-I$FF_FFMPEG_PREFIX/include"
      "--extra-ldflags=-LIBPATH:$(cygpath -m "$FF_FFMPEG_PREFIX/lib")")
while IFS=: read -r kind names; do
    [[ "$kind" == \#* || -z "$kind" ]] && continue
    case "$kind" in
      demuxer|decoder|parser) for name in $names; do args+=("--enable-$kind=$name"); done ;;
      protocol-base) for name in $names; do args+=("--enable-protocol=$name"); done ;;
    esac
done < "$FF_FFMPEG_COMPONENTS"
"$FF_FFMPEG_SOURCE/configure" "${args[@]}"
make clean
make -j4
make install
