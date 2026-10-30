# Decoder source

The decoder library inside the Windows, macOS and Linux versions of Active Area Subtitles is a build of FFmpeg 7.1.5 (libavformat, libavcodec and libavutil), licensed under the GNU Lesser General Public License version 2.1 or later.

- `ffmpeg-7.1.5.tar.xz`: the unmodified FFmpeg source, sha256 in `ffmpeg-7.1.5.tar.xz.sha256`, as published at https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz
- `make.sh`, `build.sh`, `Dockerfile`, `pin.json`: the build. `make.sh` runs `build.sh` once per system in the Docker image the `Dockerfile` describes; `build.sh` holds the one configure line and the link step for every system.
- `ship.py`: writes the export list and the structure checks from the add-on's own tables (the add-on's source is needed beside it, as in the add-on's zip).
- `smoke.c`, `films.sh`: the checks each build passes before it is packaged.
