# vlog-recorder
This tool set is designed to record clipping videos for Vlogs

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
cd vlog-recorder

RUBYOPT="-Ilib" ./bin/vlog-recorder.rb -h
Usage: vlog-recorder.rb -p project_dir/ [other options]
    -p, --project [dir]              Project directory
    -t, --trim [duration]            Trim duration of beginning and ending of each clip (default: 0.15)
    -s [arecord-args],               Additional arecord arguments (default: " --device=default --format=dat"
        --sound-settings
    -A, --android-device [device-id] Android device id
    -o, --opencamera-dir [dir]       Open Camera directory path on Android device (default: "/mnt/sdcard/DCIM/OpenCamera")
    -b [true|false],                 Set lowest brightness to save device power (default: false)
        --change-brightness
    -S, --speed [num]                Speed factor for player (default: 1.2)
    -m, --mirror [true|false]        Enable mirror effect for player (default: true)
    -P [seconds],                    Minimum pause between shots for auto trimming (default: 2)
        --pause-between-shots
    -a, --aggressiveness [0..3]      How aggressively to filter out non-speech (default: 1)
    -d, --debug [true|false]         Show debug messages (default: false)

RUBYOPT="-Ilib" ./bin/vlog-recorder.rb -p ~/video/new-cool-video-project
r - (RE)START recording
s - STOP and SAVE current clip
S - STOP and SAVE current clip, don't use auto trimming
d - STOP and DELETE current clip
p - PLAY last saved clip
f - FOCUS camera on center
h - show HELP
q / Ctrl+C - QUIT
```

## render
- applies some effects to video clips
    - speed/tempo change
    - forced constant frame rate
        - which is useful for video editors that don't support variable frame rate (like Blender)
    - video denoiser, mirror, vignette and/or whatever you specify
- renders video clips to a final video
- plays a video by a given position

```
RUBYOPT="-Ilib" ./bin/render.rb -h
Usage: render.rb -p project_dir/ [other options]
    -p, --project [dir]              Project directory
    -L, --line [num]                 Line in video.meta file, to play by given position (default: 1)
    -P, --preview [true|false]       Preview mode. It will also start a video player by a given position (default: true)
    -f, --fps [num]                  Constant frame rate (default: 30)
    -S, --speed [num]                Speed factor (default: 1.2)
    -V, --video-filters [filters]    ffmpeg video filters (default: "atadenoise,hflip,vignette")
    -c, --cleanup [true|false]       Remove temporary files, instead of reusing them in future (default: false)
    -l, --language [en|ru|...]       Language for voice recognition (default: en)

RUBYOPT="-Ilib" ./bin/render.rb -p ~/video/new-cool-video-project --preview false
```

- it also runs voice recognition in a selected language
- makes more precise clips segmentation
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

## play-segments
- plays longest pauses
    - to check the quality of video montage (useful if you do it manually, with video editors)
- plays parts with voice only
- or plays both voiced + silent parts
    - silent parts will be sped up

```
RUBYOPT="-Ilib" ./bin/play-segments.rb -h
Usage: play-segments.rb [options] -i video.mp4
    -i, --i [filename]               Video to play
    -S, --speed [num]                Speed factor (default: 1.5)
    -m, --mode [silence|voice|both]  Play silent parts starting from longest segment OR voice only OR both, but silences will be sped up (default: silence)
    -P [seconds],                    Minimum pause between shots (default: 2)
        --pause-between-shots
    -w, --window [num]               Time window before and after the segment (default: 0)
    -a, --aggressiveness [0..3]      How aggressively to filter out non-speech (default: 3)

RUBYOPT="-Ilib" ./bin/play-segments.rb -i ~/video/new-cool-video-project/output.mp4
```

## Installation
`git clone git@github.com:alopatindev/vlog-recorder.git && cd vlog-recorder`

### Dependencies
- GNU/Linux
    - ruby (tested with 2.5.1)
    - python3 (tested with 3.6.5)
    - pip (tested with 9.0.1)
    - ffmpeg (tested with 3.4.4)
    - [sync-audio-tracks](https://github.com/alopatindev/sync-audio-tracks) (should be in your PATH environment variable)
    - alsa-utils (tested with 1.1.2)
    - mpv (tested with 0.27.2)
    - android-tools (tested with 6.0.1)
        - USB Debugging should be [enabled](https://github.com/alopatindev/qdevicemonitor/blob/master/TROUBLESHOOTING.md#android-devices-are-not-recognized)
    - webrtcvad (tested with 2.0.10)
        - `pip3 install --user webrtcvad`
    - autosub
        - `pip3 install --user autosub # to install dependencies`
        - `git clone git@github.com:agermanidis/autosub.git lib/autosub`
- Android device
    - Open Camera (from [F-Droid](https://f-droid.org/en/packages/net.sourceforge.opencamera/) or [Google Play](https://play.google.com/store/apps/details?id=net.sourceforge.opencamera))
