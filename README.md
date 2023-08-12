# vlog-toolset
Designed to record vlogs with classical jump cuts
using camera of Android-based device and microphone of GNU/Linux machine.
I [use it](https://alopatindev.github.io/2019/02/05/video-recording-with-automatic-jump-cuts-using-open-source-and-coding/) with Pitivi for my [YouTube channel](https://www.youtube.com/channel/UCjNAnQpPQydNLTHcVz0s44A).

## Installation
`git clone git@github.com:alopatindev/vlog-toolset.git && cd vlog-toolset && ./configure`

### Dependencies
- GNU/Linux
    - ruby (tested with 2.5.1)
    - python3 (tested with 3.6.5)
    - pip (tested with 9.0.1)
    - ffmpeg (tested with 3.4.4)
    - [sync-audio-tracks](https://github.com/alopatindev/sync-audio-tracks) (should be in your PATH environment variable)
    - alsa-utils (tested with 1.1.2)
    - mpv (tested with 0.27.2)
    - android-tools (tested with 8.1.0_p1, adb version is 1.0.39)
        - USB Debugging should be [enabled](https://github.com/alopatindev/qdevicemonitor/blob/master/TROUBLESHOOTING.md#android-devices-are-not-recognized)

- not yet used
    - torch (tested with 2.0.1), torchaudio (tested with 2.0.2)
        - `pip install --user --break-system-packages torch torchaudio -f https://download.pytorch.org/whl/cpu/torch_stable.html`
    - maturin (1.0.1), poetry (1.5.1)
        - ` pip install --user --break-system-packages maturin poetry`
    - DeepFilterNet (tested with 0.2.4)
        - `pip install --user --break-system-packages deepfilternet`
    - `cargo install --features="bin" --force --git https://github.com/Rikorose/DeepFilterNet --rev aaf19c4e deep_filter`

```
VIRTUAL_ENV=$(python3 -c 'import sys; print(sys.base_prefix)') maturin develop --release -m pyDF/Cargo.toml
```

- Android device
    - Open Camera (from [F-Droid](https://f-droid.org/en/packages/net.sourceforge.opencamera/) or [Google Play](https://play.google.com/store/apps/details?id=net.sourceforge.opencamera))

## vlog-recorder
- records video
    - using camera of Android-based device
- records audio
    - using microphone, connected to GNU/Linux machine
- detects voice (to trim silence)
    - if you save clip without auto trimming — it will just remove beginning and ending of each clip
        - which typically contain the button click sound
- synchronizes audio
- combines stuff together to produce MP4 video clips
    - which contain
        - H.264/MPEG-4 AVC video taken from camera
        - ALAC audio recorded with GNU/Linux machine
- plays lastly recorded video clips
    - with optional mirror effect

```
cd vlog-toolset

./bin/vlog-recorder -h
Usage: vlog-recorder -p project_dir/ [other options]
    -p, --project <dir>              Project directory
    -t, --trim <duration>            Trim duration of beginning and ending of each clip (default: 0.15)
    -s <arecord-args>,               Additional arecord arguments (default: " --device=default --format=dat"
        --sound-settings
    -A, --android-device <device-id> Android device id
    -o, --opencamera-dir <dir>       Open Camera directory path on Android device (default: "/mnt/sdcard/DCIM/OpenCamera")
    -b <true|false>,                 Set lowest brightness to save device power (default: false)
        --change-brightness
    -S, --speed <num>                Speed factor for player (default: 1.2)
    -m, --mirror <true|false>        Enable mirror effect for player (default: true)
    -P <seconds>,                    Minimum pause between shots for auto trimming (default: 2)
        --pause-between-shots
    -a, --aggressiveness <0..3>      How aggressively to filter out non-speech (default: 1)
    -d, --debug <true|false>         Show debug messages (default: false)

./bin/vlog-recorder -p ~/video/new-cool-video-project
r - (RE)START recording
s - STOP and SAVE current clip
S - STOP and SAVE current clip, don't use auto trimming
d - STOP and DELETE current clip
p - PLAY last saved clip
f - FOCUS camera on center
h - show HELP
q / Ctrl+C - QUIT
```

## vlog-render
- applies some effects to video clips
    - speed/tempo change
    - forced constant frame rate
        - which is useful for video editors that don't support variable frame rate (like Blender)
    - video denoiser, mirror, vignette and/or whatever you [specify](https://ffmpeg.org/ffmpeg-filters.html#Video-Filters)
- renders video clips to a final video
- plays a video by a given position

```
./bin/vlog-render -h
Usage: vlog-render -p project_dir/ [other options]
    -p, --project <dir>              Project directory
    -L, --line <num>                 Line in render.conf file, to play by given position (default: 1)
    -P, --preview <true|false>       Preview mode. It will also start a video player by a given position (default: true)
    -f, --fps <num>                  Constant frame rate (default: 30)
    -S, --speed <num>                Speed factor (default: 1.2)
    -V, --video-filters <filters>    ffmpeg video filters (default: 'hqdn3d,hflip,vignette')
    -c, --cleanup <true|false>       Remove temporary files, instead of reusing them in future (default: false)
    -l, --language <en|ru|...>       Language for voice recognition (default: 'en')

./bin/vlog-render -p ~/video/new-cool-video-project --preview false
```

- it also runs voice recognition in a selected language
- makes more precise clips segmentation
- produces media output
    - clips are located in `project_dir/output/`
    - concatenation of all clips is located at `project_dir/output.mp4`
- produces a configuration file
    - the columns in the config are:
        - clip filename
        - speed multiplier
        - start position (in seconds)
        - end position (in seconds)
        - recognized text (to figure out which clips can be removed / reordered)
    - you can edit the config
        - put `#` in the beginning of line you want to ignore (or just remove the entire line)
        - add empty newlines to increase delay *after* clip
        - change speed of individual clips

```
vi ~/video/new-cool-video-project/render.conf
```

## vlog-play-segments
- plays longest pauses
    - to check the quality of video montage (useful if you do it manually, with video editors)
- plays parts with voice only
- or plays both voiced + silent parts
    - silent parts will be sped up

```
./bin/vlog-play-segments -h
Usage: vlog-play-segments [options] -i video.mp4
    -i, --i <filename>               Video to play
    -S, --speed <num>                Speed factor (default: 1.5)
    -m, --mode <silence|voice|both>  Play silent parts starting from longest segment OR voice only OR both, but silences will be sped up (default: silence)
    -P <seconds>,                    Minimum pause between shots (default: 2)
        --pause-between-shots
    -w, --window <num>               Time window before and after the segment (default: 0)
    -a, --aggressiveness <0..3>      How aggressively to filter out non-speech (default: 3)

./bin/vlog-play-segments -i ~/video/new-cool-video-project/output.mp4
```

## Known issues/limitations
- it's just a dumb dirty PoC, it's not necessarily gonna work on your hardware
    - I'm using ~~Meizu MX4~~ Xiaomi Mi 8
        - front camera faces at me
        - autorotation is enabled
        - the device is at landscape position (counterclockwise from normal position)
            - if auto-rotate is broken — try to reboot your phone
- paths with spaces and weird characters are unsupported
- cuts precision accuracy is pretty poor
    - better approach would be something like [roughcut](https://graphics.stanford.edu/papers/roughcut/)

## RIIR?
- [adb](https://github.com/kpcyrd/forensic-adb/blob/736f7c43d116b6334af3c1d8c4a41f9ae06ff812/src/lib.rs#L754)
    - `pull` performance comparing `android-tools`? for USB 2 and 3

## License
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

This program comes with ABSOLUTELY NO WARRANTY.
This is free software, and you are welcome to redistribute it
under certain conditions; read LICENSE.txt for details.

Copyright (C) 2018—2023  Alexander Lopatin <alopatindev ät gmail dot com>
