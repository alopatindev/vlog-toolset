FFMPEG = 'ffmpeg -y -hide_banner -loglevel error'.freeze
FFMPEG_NO_OVERWRITE = 'ffmpeg -n -hide_banner -loglevel panic'.freeze

def get_duration(filename)
  `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{filename}`.to_f
end

def prepare_for_vad(filename)
  output_filename = "#{filename}.vad.wav"
  system "#{FFMPEG} -i #{filename} -af 'pan=mono|c0=c0' -ar 48000 -vn #{output_filename}"
  output_filename
end

def clamp_speed(speed)
  speed.clamp(0.5, 2.0)
end