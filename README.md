# vlog-recorder
This tool is designed to record clipping videos for Vlogs or audios for Podcasts

## How it works
- records video (using camera of Android-based device)
- records audio (using microphone, connected to GNU/Linux machine)
- detects voice (to trim silence)
  - if auto trimming is disabled — just removes beginning and ending of each clip (which typically contain the button click sound)
- synchronizes audio
- applies some effects
  - speed/tempo change
  - forced constant frame rate
  - mirror, video denoiser, vignette and/or whatever you specify
- combines stuff together to produce video clips

## Usage
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
    -f, --fps [num]                  Constant frame rate (default: 30)
    -S, --speed [num]                Speed factor (default: 1.2)
    -V, --video-filters [filters]    ffmpeg video filters (default: "hflip,atadenoise,vignette")
    -C [options],                    libx264 options (default: " -preset ultrafast -crf 18")
        --video-compression
    -P [seconds],                    Minimum pause between shots for auto trimming (default: 2)
        --pause-between-shots
    -a, --aggressiveness [0..3]      How aggressively to filter out non-speech (default: 2)
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

## Play Longest Pauses After Montage
```
RUBYOPT="-Ilib" ./bin/play-segments.rb -h
Usage: play-segments.rb [options] -i video.mp4
    -i, --i [filename]               Video to play
    -s, --silence [true|false]       Play silent parts starting from longest segment (default: true)
    -P [seconds],                    Minimum pause between shots (default: 2)
        --pause-between-shots
    -w, --window [num]               Time window before and after the segment (default: 0)
    -a, --aggressiveness [0..3]      How aggressively to filter out non-speech (default: 3)

RUBYOPT="-Ilib" ./bin/play-segments.rb -i ~/video/new-cool-video-project/rendered_video.mp4
```

## Installation
`git clone git@github.com:alopatindev/vlog-recorder.git`

### Dependencies
- GNU/Linux
- ruby (tested with 2.5.1)
- python (tested with 3.6.5)
- pip (tested with 9.0.1)
- ffmpeg (tested with 3.4.4)
- [sync-audio-tracks](https://github.com/alopatindev/sync-audio-tracks) (should be in your PATH variable)
- alsa-utils (tested with 1.1.2)
- Open Camera (from [F-Droid](https://f-droid.org/en/packages/net.sourceforge.opencamera/) or [Google Play](https://play.google.com/store/apps/details?id=net.sourceforge.opencamera))
- mpv (tested with 0.27.2)
- android-tools (tested with 6.0.1)
  - USB Debugging should be [enabled](https://github.com/alopatindev/qdevicemonitor/blob/master/TROUBLESHOOTING.md#android-devices-are-not-recognized)
- webrtcvad (tested with 2.0.10)
  - `pip3 install --user webrtcvad`
