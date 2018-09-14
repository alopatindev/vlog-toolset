require 'ffmpeg_utils.rb'
require 'fileutils'

def detect_voice(sound_filename, min_shot_size, min_pause_between_shots)
  first_segment_correction = 0.5
  start_correction = 0.1
  end_correction = 0.1
  agressiveness = 1 # 0..3

  script_filename = File.join(File.dirname(__FILE__), 'detect_voice.py')

  sound_with_single_channel_filename = prepare_for_vad(sound_filename)
  output = `#{script_filename} #{sound_with_single_channel_filename} #{agressiveness} #{min_shot_size} #{min_pause_between_shots}`

  FileUtils.rm_f sound_with_single_channel_filename

  segments = output
             .split("\n")
             .map { |line| line.split(' ') }
             .map { |r| r.map(&:to_f) }
             .select { |r| r.length == 2 }
             .map { |start_position, end_position| [start_position - start_correction, end_position + end_correction] }

  segments
end
