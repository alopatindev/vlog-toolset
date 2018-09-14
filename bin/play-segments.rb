#!/bin/env ruby

require 'voice/detect_voice.rb'
require 'ffmpeg_utils.rb'

require 'fileutils'
require 'optparse'

MIN_SHOT_SIZE = 1.0

def convert_to_wav(video_filename)
  puts "converting sound...\n"
  sound_filename = "#{video_filename}.wav"
  system "#{FFMPEG} -i #{video_filename} -vn #{sound_filename}"
  sound_filename
end

def detect_segments(sound_filename, options)
  puts "detecting segments...\n"

  silence = options[:silence]
  min_pause_between_shots = options[:min_pause_between_shots]
  time_window = options[:window]
  aggressiveness = options[:aggressiveness]

  duration = get_duration(sound_filename)
  voice_segments = detect_voice sound_filename, MIN_SHOT_SIZE, min_pause_between_shots, aggressiveness

  pauses = voice_segments
           .flatten[1..-2]
           .each_slice(2)

  pauses_with_dt = pauses.map do |start_position, end_position|
    dt = end_position - start_position
    [dt, start_position, end_position]
  end

  pauses_duration = pauses_with_dt.map { |dt, _start_position, _end_position| dt }.sum
  voice_duration = voice_segments.map { |start_position, end_position| end_position - start_position }.sum
  pauses_percentage = (pauses_duration / duration) * 100.0
  puts "pauses take #{pauses_percentage.round(1)}% of video"

  segments =
    if silence
      pauses_with_dt.sort_by { |dt, _start_position, _end_position| -dt }
                    .map { |_dt, start_position, end_position| [start_position, end_position] }
    else
      voice_segments
    end

  segments.map do |start_position, end_position|
    start_position_with_window = [start_position - time_window, 0.0].max
    end_position_with_window = [end_position + time_window, duration].min
    [start_position_with_window, end_position_with_window]
  end
end

def play_segments(options)
  video_filename = options[:video]
  sound_filename = convert_to_wav video_filename
  segments = detect_segments sound_filename, options
  FileUtils.rm_f sound_filename

  puts "playing...\n"
  mpv_args = segments.map do |start_position, end_position|
    "--{ --start=#{start_position} --end=#{end_position} #{video_filename} --}"
  end.join(' ')

  system "mpv --really-quiet #{mpv_args}"
end

def parse_options!(options)
  OptionParser.new do |opts|
    opts.banner = 'Usage: play-segments.rb [options] -i video.mp4'
    opts.on('-i', '--i [filename]', 'Video to play') { |i| options[:video] = i }
    opts.on('-s', '--silence [true|false]', 'Play silent parts starting from longest segment (default: true)') { |s| options[:silence] = s == 'true' }
    opts.on('-P', '--pause-between-shots [seconds]', 'Minimum pause between shots (default: 2)') { |p| options[:min_pause_between_shots] = p }
    opts.on('-w', '--window [num]', 'Time window before and after the segment (default: 0)') { |w| options[:window] = w.to_f }
    opts.on('-a', '--aggressiveness [0..3]', 'How aggressively to filter out non-speech (default: 3)') { |a| options[:aggressiveness] = a.to_i }
  end.parse!

  raise OptionParser::MissingArgument if options[:video].nil?
end

options = {
  silence: true,
  min_pause_between_shots: 0.5,
  window: 0.0,
  aggressiveness: 3
}

parse_options!(options)
play_segments(options)
