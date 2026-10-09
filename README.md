# Active Area Subtitles for Kodi

Kodi repository for Active Area Subtitles, an add-on that shows text subtitles just inside the picture of widescreen films instead of in the black bars.

The picture is measured once at the start of playback, then the add-on stays out of the way for the rest of the film, and your own subtitle settings are restored when playback ends. On PCs it uses a few small screen captures; on CoreELEC boxes it reads a few frames of the video file. When CoreELEC already keeps the subtitles inside the picture, the add-on leaves them to it.

Subtitles sit right on the picture's edge; Small gap from the black bar lifts them slightly. On CoreELEC, Correct faulty Dolby Vision Level 5 fixes Dolby Vision films whose Level 5 data does not match the picture.

- Made for Kodi 21 (Omega).
- The subtitle position must be Bottom of screen (Kodi's default) or Bottom of video, not Manual.
- Text subtitles only: image-based subtitles (such as PGS) cannot be moved.

## Installing

1. Settings > File manager > Add source, and enter `https://berserker-git.github.io/active-area-subtitles-kodi/`.
2. Add-ons > Install from zip file > that source > `repository.activeareasubtitles-1.0.0.zip`.
3. Add-ons > Install from repository > Active Area Subtitles Repository > Services > Active Area Subtitles.

Kodi then keeps Active Area Subtitles up to date by itself. To check straight away, open Add-ons > Program add-ons > Active Area Subtitles and choose Check for updates.
