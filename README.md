# vlog-recorder
This tool is designed to record clipping videos for Vlogs or audios for Podcasts

## How it works
- records video (using camera of Android-based device)
- records audio (using microphone, connected to GNU/Linux machine)
- synchronizes audio
- trims beginning and ending of each clip (which typically contain the button click sound)
- produces video clips

## Usage
```
git clone git@github.com:alopatindev/vlog-recorder.git
cd vlog-recorder

RUBYOPT="-Ilib" ./bin/vlog-recorder.rb -h
Usage: vlog-recorder.rb -p project_dir/ [other options]
    -p, --project [dir]              Project directory
    -t, --trim [duration]            Trim duration of beginning and ending of each clip (default 0.15)
    -s [arecord-args],               Additional arecord arguments (default " --device=default --format=dat"
        --sound-settings
    -a, --android-device [device-id] Android device id
    -o, --opencamera-dir [dir]       Open Camera directory path on Android device (default "/mnt/sdcard/DCIM/OpenCamera")
    -u, --use-camera [true|false]    Whether we use Android device at all (default "true")

RUBYOPT="-Ilib" ./bin/vlog-recorder.rb -p ~/video/new-cool-video-project
r - (RE)START recording
s - STOP and SAVE current clip
d - STOP and DELETE current clip
p - PLAY last saved clip
f - FOCUS camera on center
h - show HELP
q / Ctrl+C - QUIT
```

## Dependencies
- ruby (tested with 2.5.1)
- ffmpeg (tested with 3.3.6)
- [sync-audio-tracks](https://github.com/alopatindev/sync-audio-tracks) (should be in your PATH variable)
- alsa-utils
- Open Camera (from [F-Droid](https://f-droid.org/en/packages/net.sourceforge.opencamera/) or [Google Play](https://play.google.com/store/apps/details?id=net.sourceforge.opencamera))
- mpv (tested with 0.27.2)
