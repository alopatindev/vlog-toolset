# vlog-recorder
This tool is designed to record clipping videos for Vlogs

## How it works
- records video (using camera of Android-based device)
- records audio (using microphone, connected to GNU/Linux machine)
- synchronizes audio
- produces video clips

## Usage
```
git clone git@github.com:alopatindev/vlog-recorder.git
cd vlog-recorder
RUBYOPT="-Ilib" ./bin/vlog-recorder.rb ~/video/new-cool-video-project

r - (RE)START recording
s - STOP and SAVE current clip
d - STOP and DELETE current clip
f - FOCUS camera on center
h - show HELP
q / Ctrl+C - QUIT
```

## Dependencies
- [sync-audio-tracks](https://github.com/alopatindev/sync-audio-tracks) (should be in your PATH variable)
- alsa-utils
- Open Camera (from [F-Droid](https://f-droid.org/en/packages/net.sourceforge.opencamera/) or [Google Play](https://play.google.com/store/apps/details?id=net.sourceforge.opencamera))
