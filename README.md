# Active Area Subtitles for Kodi

Kodi repository for Active Area Subtitles, an add-on that shows text subtitles just inside the picture of widescreen content instead of in the black bars.

The picture is measured at the start of playback from a few frames of the video file, or from small captures of Kodi's video where the file can not be read, and your own subtitle settings are restored when playback ends. In films that switch between widescreen and IMAX scenes the subtitles move with the picture: on PCs in every film, on CoreELEC in Dolby Vision films on builds that report their scene shapes. It works with CoreELEC's own subtitle settings as they are, nothing there needs changing, and where CoreELEC places the subtitles itself the add-on gives it the chosen distances.

Distances set where text subtitles sit, measured from the picture's edge: one for content with black bars (right on the edge, or a small gap), one for content that fills the screen (Standard by default, Kodi's usual height, from On the edge up to High or any custom value), and one for IMAX scenes (the full-screen distance by default). On CoreELEC, Correct faulty Dolby Vision Level 5 fixes Dolby Vision content whose Level 5 data does not match the picture.

- Made for Kodi 21 (Omega).
- Subtitle position: on a PC Bottom of screen (Kodi's default), Bottom of video or Manual; on CoreELEC Bottom of screen or Bottom of video.
- Image-based subtitles (such as PGS) are kept inside the picture only on CoreELEC builds that can place them; elsewhere they stay where the disc puts them.

## Installing

1. Settings > File manager > Add source, and enter `https://berserker-git.github.io/active-area-subtitles-kodi/`.
2. Add-ons > Install from zip file > that source > `repository.activeareasubtitles-1.1.0.zip`.
3. Add-ons > Install from repository > Active Area Subtitles Repository > Services > Active Area Subtitles.

Kodi then keeps Active Area Subtitles up to date by itself. To check straight away, open Add-ons > Program add-ons > Active Area Subtitles and choose Check for updates.
