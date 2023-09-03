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

require 'ffmpeg_utils'
require 'shellwords_utils'
require 'voice/detect_voice'

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
    ['--{', "--start=#{start_position}", "--end=#{end_position}", "--speed=#{clip_speed}", video_filename, '--}']
  end.flatten

  # TODO: use MPV?
  command = ['mpv', '--really-quiet', '--hr-seek=yes'] + mpv_args
  system command.shelljoin_wrapped
end

def parse_options!(options, args)
  parser = OptionParser.new do |opts|
    opts.set_banner('Usage: vlog-play-segments [options] -i video.mp4')
    opts.set_summary_indent('  ')
    opts.on('-i', '--i <filename>', 'Video to play') { |i| options[:video] = i }
    opts.on('-S', '--speed <num>', "Speed factor (default: #{'%.1f' % options[:speed]})") do |s|
      options[:speed] = s.to_f
    end
    opts.on('-m', '--mode <silence|voice|both>',
            "Play silent parts starting from longest segment OR voice only OR both, but silences will be sped up (default: #{options[:mode]})") do |m|
      options[:mode] = m
    end
    opts.on('-P', '--pause-between-shots <seconds>',
            "Minimum pause between shots (default: #{'%.1f' % options[:min_pause_between_shots]})") do |p|
      options[:min_pause_between_shots] = p
    end
    opts.on('-w', '--window <num>',
            "Time window before and after the segment (default: #{'%.1f' % options[:window]})") do |w|
      options[:window] = w.to_f
    end
    opts.on('-a', '--aggressiveness <0..3>',
            "How aggressively to filter out non-speech (default: #{options[:aggressiveness]})") do |a|
      options[:aggressiveness] = a.to_i
    end
  end

  parser.parse!(args)

  return unless options[:video].nil?

  print parser.help
  exit 1
end

options = {
  speed: 1.5,
  mode: 'silence',
  min_pause_between_shots: 0.5,
  window: 0.0,
  aggressiveness: 3
}

parse_options!(options, ARGV)
play_segments(options)
