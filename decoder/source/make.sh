#!/bin/bash
# Builds the decoder libraries in docker on the build host: tools/ffmpeg_ship/out/SYSTEM/ for each system, the
# content of the add-on's resources/decoder/ in that system's zip (build_addon.py makes the zips).
#
#   tools/ffmpeg_ship/make.sh [SYSTEM ...]      default: every system of the loader's table (ship.py systems);
#                                               TWICE=1 builds each twice and compares the bytes
#
# The FFmpeg archive is downloaded once into the cache folder, with its detached signature, and checked before use:
# its sha256 against pin.json, then its signature with gpg against FFmpeg's release key (ffmpeg-devel.asc here),
# which must be pin.json's signed_by. The build containers run with no network. The cache (FFMPEG_SHIP_CACHE,
# default .ffmpeg-ship-cache) holds the archive and the build trees and is never published.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SHIP=$ROOT/tools/ffmpeg_ship
CACHE=${FFMPEG_SHIP_CACHE:-$ROOT/.ffmpeg-ship-cache}
DOCKER=${DOCKER:-sudo -n docker}
python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import check; check.refuse_when_busy(sys.argv)' \
  "$ROOT/tools" "$@"
SYSTEMS=()
for arg in "$@"; do [ "$arg" = --anyway ] || SYSTEMS+=("$arg"); done
[ ${#SYSTEMS[@]} -gt 0 ] || mapfile -t SYSTEMS < <(python3 "$SHIP/ship.py" systems)

pinned() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."): d = d[key]
print(d)' "$SHIP/pin.json" "$1"; }
FFMPEG_URL=$(pinned ffmpeg.url)
ARCHIVE=$CACHE/downloads/$(basename "$FFMPEG_URL")
mkdir -p "$CACHE/downloads" "$CACHE/work" "$SHIP/out"
if [ ! -f "$ARCHIVE" ]; then
  curl -fsSL -o "$ARCHIVE.part" "$FFMPEG_URL" && mv "$ARCHIVE.part" "$ARCHIVE"
fi
if [ ! -f "$ARCHIVE.asc" ]; then
  curl -fsSL -o "$ARCHIVE.asc.part" "$FFMPEG_URL.asc" && mv "$ARCHIVE.asc.part" "$ARCHIVE.asc"
fi
python3 "$SHIP/ship.py" verify "$ARCHIVE" "$(pinned ffmpeg.sha256)"
if [ ! -f "$SHIP/ffmpeg-devel.asc" ]; then
  echo "FFmpeg's release key is not in tools/ffmpeg_ship: download https://ffmpeg.org/ffmpeg-devel.asc there" >&2
  echo "(its fingerprint must be pin.json's signed_by; a wrong key only fails this check, it can not pass one)" >&2
  exit 1
fi
python3 "$SHIP/ship.py" signed "$ARCHIVE" "$ARCHIVE.asc" "$SHIP/ffmpeg-devel.asc" "$(pinned ffmpeg.signed_by)"

ZIG=$(pinned zig.version)
IMAGE=activearea-ffmpeg-build:zig-$ZIG
if ! $DOCKER image inspect "$IMAGE" > /dev/null 2>&1; then
  # The Dockerfile alone as the context: nothing from this folder (the cache least of all) goes to the daemon.
  $DOCKER build -t "$IMAGE" --build-arg ZIG_URL="$(pinned zig.url)" --build-arg ZIG_SHA256="$(pinned zig.sha256)" \
    - < "$SHIP/Dockerfile"
fi

build() {   # build SYSTEM OUT_FOLDER
  mkdir -p "$2"
  $DOCKER run --rm --network none --label activearea.ffmpeg-build=1 -u "$(id -u):$(id -g)" \
    -e HOME=/work/home -e JOBS="${JOBS:-4}" \
    -v "$ROOT":/src:ro -v "$CACHE/downloads":/downloads:ro -v "$CACHE/work":/work -v "$2":/out \
    -v "$SHIP/films":/films:ro "$IMAGE" bash /src/tools/ffmpeg_ship/build.sh "$1"
}

for system in "${SYSTEMS[@]}"; do
  echo "=== $system ($(date))"
  build "$system" "$SHIP/out"
  if [ "${TWICE:-}" = 1 ]; then
    build "$system" "$CACHE/again"
    library=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ship; print(ship.file_name(sys.argv[2]))' "$SHIP" "$system")
    cmp "$SHIP/out/$system/$library" "$CACHE/again/$system/$library" \
      && echo "$system: the second build gave the same bytes" \
      || { echo "$system: the second build differs"; exit 1; }
  fi
  python3 "$SHIP/ship.py" built "$system" "$SHIP/out/$system"
done
echo "done ($(date))"
