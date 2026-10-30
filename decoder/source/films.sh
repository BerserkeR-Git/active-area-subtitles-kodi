#!/bin/bash
# Makes the check films the decoder builds are smoke-tested on: a
# grey picture between black bars of known height, 320x180, one per demuxer and decoder the build enables (VC-1
# has no encoder, so no VC-1 film). Run in the test image, which has FFmpeg with x265 and libvpx:
#   sudo -n docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/tools/ffmpeg_ship":/ship activearea-test:local \
#     bash /ship/films.sh /ship/films
set -euo pipefail
OUT=$1
mkdir -p "$OUT"
cd "$OUT"
film() {   # film NAME PICTURE_ROWS DECODER CODEC_ARGS...
  local name=$1 rows=$2 decoder=$3; shift 3
  local top=$(( (180 - rows) / 2 / 2 * 2 ))
  ffmpeg -v error -y -f lavfi -i "color=c=0x808080:size=320x${rows}:rate=25:duration=1" \
    -vf "pad=320:180:0:${top}:black" -g 12 "$@" "$name"
  printf '%s %s %d %d\n' "$name" "$decoder" "$top" $(( 180 - rows - top )) >> films.txt
}
: > films.txt
film check.mkv 136 hevc -c:v libx265 -pix_fmt yuv420p10le -x265-params log-level=none
film check-h264.mp4 120 h264 -c:v libx264 -pix_fmt yuv420p
film check-mpeg2.ts 100 mpeg2video -c:v mpeg2video -q:v 2
film check-mpeg2.mpg 140 mpeg2video -c:v mpeg2video -q:v 2 -f vob
film check-mpeg4.avi 80 mpeg4 -c:v mpeg4 -q:v 2
film check-vp9.mkv 160 vp9 -c:v libvpx-vp9 -b:v 0 -crf 30
python3 - <<'EOF'
import json
films = {}
for line in open('films.txt'):
    name, decoder, top, bottom = line.split()
    films[name] = {'decoder': decoder, 'width': 320, 'height': 180, 'top': int(top), 'bottom': int(bottom)}
json.dump(films, open('films.json', 'w'), indent=1, sort_keys=True)
EOF
rm films.txt
ls -l
