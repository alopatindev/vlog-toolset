FFMPEG = 'ffmpeg -y -hide_banner -loglevel error'.freeze

def get_duration(filename)
  `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{filename}`.to_f
end
