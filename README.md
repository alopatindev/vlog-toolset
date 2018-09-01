# vlog-recorder
This tool is designed to record clipping videos for Vlogs or audios for Podcasts

## How it works
- records video (using camera of Android-based device)
- records audio (using microphone, connected to GNU/Linux machine)
- detects voice (to trim the output, so it will contain only last shot with voice)
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
    -t, --trim [duration]            Trim duration of beginning and ending of each clip (default 0.15)
    -s [arecord-args],               Additional arecord arguments (default " --device=default --format=dat"
        --sound-settings
    -a, --android-device [device-id] Android device id
    -o, --opencamera-dir [dir]       Open Camera directory path on Android device (default "/mnt/sdcard/DCIM/OpenCamera")
    -u, --use-camera [true|false]    Whether we use Android device at all (default "true")
    -b [true|false],                 Set lowest brightness to save device power (default "false")
        --change-brightness
    -f, --fps [num]                  Constant frame rate (default "30")
    -S, --speed [num]                Speed factor (default "1.2")
    -V, --video-filters [filters]    ffmpeg video filters (default "hflip,atadenoise,vignette")
    -C [options],                    libx264 options (default " -preset ultrafast -crf 18")
        --video-compression
    -P [seconds],                    Minimum pause between shots for auto trimming (default 3)
        --pause-between-shots

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

### You've got bunch of files, now what?
Concatenate them
```
cd ~/video/new-cool-video-project
printf "file '%s'\n" ./0*.flac | ffmpeg -y -f concat -safe 0 -protocol_whitelist file,pipe -i - output.flac
```

## Installation
`git clone git@github.com:alopatindev/vlog-recorder.git`

### Dependencies
- GNU/Linux
- ruby (tested with 2.5.1)
- ffmpeg (tested with 3.3.6)
- [sync-audio-tracks](https://github.com/alopatindev/sync-audio-tracks) (should be in your PATH variable)
- alsa-utils
- Open Camera (from [F-Droid](https://f-droid.org/en/packages/net.sourceforge.opencamera/) or [Google Play](https://play.google.com/store/apps/details?id=net.sourceforge.opencamera))
- mpv (tested with 0.27.2)
- android-tools (tested with 6.0.1)
    - USB Debugging should be [enabled](https://github.com/alopatindev/qdevicemonitor/blob/master/TROUBLESHOOTING.md#android-devices-are-not-recognized)

#### vadnet
`git clone git@github.com:hcmlab/vadnet.git vlog-recorder/lib/voice/vadnet && pip3 install --user tensorflow librosa termcolor`

Which also requires
- python (tested with 3.6.5)
- pip
