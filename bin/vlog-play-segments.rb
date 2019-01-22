#!/bin/env ruby

# This file is part of vlog-toolset.
#
# vlog-toolset is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# vlog-toolset is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with vlog-toolset. If not, see <http://www.gnu.org/licenses/>.

require 'voice/detect_voice.rb'
require 'ffmpeg_utils.rb'

require 'fileutils'
require 'optparse'

MIN_SHOT_SIZE = 1.0

def detect_segments(sound_filename, options)
  puts "detecting segments...\n"

  mode = options[:mode]
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
    case mode
    when 'silence'
      pauses_with_dt.sort_by { |dt, _start_position, _end_position| -dt }
                    .map { |_dt, start_position, end_position| [start_position, end_position] }
    when 'voice'
      voice_segments
    when 'both'
      voice_segments.zip(pauses.map { |xs| xs.map { |i| i + 0.001 } })
                    .flatten
                    .reject(&:nil?)
                    .each_slice(2)
    else
      raise "Unsupported mode #{mode}"
    end

  segments.map do |start_position, end_position|
    start_position_with_window = [start_position - time_window, 0.0].max
    end_position_with_window = [end_position + time_window, duration].min
    [start_position_with_window, end_position_with_window]
  end
end

def play_segments(options)
  video_filename = options[:video]
  mode = options[:mode]
  speed = options[:speed]

  segments = detect_segments video_filename, options

  puts "playing...\n"
  mpv_args = segments.map.with_index do |(start_position, end_position), i|
    clip_speed = i.odd? && mode == 'both' ? (speed * 4.0) : speed
    "--{ --start=#{start_position} --end=#{end_position} --speed=#{clip_speed} #{video_filename} --}"
  end.join(' ')

  system "mpv --really-quiet --hr-seek=yes #{mpv_args}"
end

def parse_options!(options)
  OptionParser.new do |opts|
    opts.banner = 'Usage: vlog-play-segments [options] -i video.mp4'
    opts.on('-i', '--i [filename]', 'Video to play') { |i| options[:video] = i }
    opts.on('-S', '--speed [num]', 'Speed factor (default: 1.5)') { |s| options[:speed] = s.to_f }
    opts.on('-m', '--mode [silence|voice|both]', 'Play silent parts starting from longest segment OR voice only OR both, but silences will be sped up (default: silence)') { |m| options[:mode] = m }
    opts.on('-P', '--pause-between-shots [seconds]', 'Minimum pause between shots (default: 2)') { |p| options[:min_pause_between_shots] = p }
    opts.on('-w', '--window [num]', 'Time window before and after the segment (default: 0)') { |w| options[:window] = w.to_f }
    opts.on('-a', '--aggressiveness [0..3]', 'How aggressively to filter out non-speech (default: 3)') { |a| options[:aggressiveness] = a.to_i }
  end.parse!

  raise OptionParser::MissingArgument if options[:video].nil?
end

options = {
  speed: 1.5,
  mode: 'silence',
  min_pause_between_shots: 0.5,
  window: 0.0,
  aggressiveness: 3
}

parse_options!(options)
play_segments(options)
