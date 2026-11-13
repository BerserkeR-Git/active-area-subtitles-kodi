# Build image for the decoder libraries: Debian 11 (glibc 2.31, so the Linux library loads on every current
# desktop), gcc for Linux, mingw-w64 for Windows, zig for macOS, nasm for the x86 assembly, llvm's tools to read
# Mach-O files, Wine to run the Windows checks. zig is fetched here and checked against the pinned sha256.
# Classic builder syntax only. Build: docker build -t activearea-ffmpeg-build:local --build-arg ZIG_URL=...
#   --build-arg ZIG_SHA256=... tools/ffmpeg_ship (build.sh passes the values from pin.json)
FROM debian:bullseye-slim
# Debian 11 is past its support period: its packages (security updates included) are served from the archive.
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' \
        > /etc/apt/sources.list && rm -f /etc/apt/sources.list.d/* \
    && apt-get -o Acquire::Check-Valid-Until=false update && apt-get install -y --no-install-recommends \
        build-essential nasm pkg-config python3 xz-utils curl ca-certificates \
        gcc-mingw-w64-x86-64 binutils-mingw-w64-x86-64 llvm wine wine64 \
    && rm -rf /var/lib/apt/lists/*
# zig 0.13: later releases fail on this build host's kernel (4.4) with a cache error on every target.
ARG ZIG_URL
ARG ZIG_SHA256
RUN test -n "$ZIG_URL" && test -n "$ZIG_SHA256" \
    && curl -fsSL -o /tmp/zig.tar.xz "$ZIG_URL" \
    && echo "$ZIG_SHA256  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig && zig version
