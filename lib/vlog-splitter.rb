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

require 'media_utils'
require 'mic'
require 'numeric_utils'
require 'os_utils'
require 'phone'
require 'process_utils'
require 'voice/detect_voice'

require 'colorize'
require 'concurrent'
require 'fileutils'
require 'io/console'
require 'logger'
require 'optparse'

def parse_options!(options, args)
  parser = OptionParser.new do |opts|
    opts.set_banner("Usage: vlog-splitter -p project_dir/ [other options]\nProject directory must contain input_000001.mp4, input_000002.mp4 ... as input files\n")
    opts.set_summary_indent('  ')
    opts.on('-p', '--project <dir>', 'Project directory') { |p| options[:project_dir] = p }
    opts.on('-P', '--pause-between-shots <seconds>',
            "Minimum pause between shots for auto trimming (default: #{'%.1f' % options[:min_pause_between_shots]})") do |p|
      options[:min_pause_between_shots] = p
    end
    opts.on('-a',
            '--aggressiveness <0..1>', "How aggressively to filter out non-speech (default: #{options[:aggressiveness]})") do |a|
      options[:aggressiveness] = a.to_f
    end
  end

  parser.parse!(args)

  return unless options[:project_dir].nil?

  print(parser.help)
  exit 1
end

def prepare_sync_sound(filename)
  output_filename = "#{filename}.wav"
  command = FFMPEG + [
    '-i', filename,
    '-af', EXTRACT_LEFT_CHANNEL_FILTER,
    # '-ar', 48_000, # TODO: extract?
    # '-ar', 44_100, # TODO: extract? remove?
    '-vn',
    output_filename
  ]
  system "#{command.shelljoin_wrapped}"
  output_filename
end

def detect_segments(sync_sound_filename, camera_filename, options)
  sync_sound_duration = get_duration(sync_sound_filename)
  duration = [get_duration(camera_filename), sync_sound_duration].min

  start_position = 0.0
  end_position = duration

  segments = []

  max_output_duration = end_position - start_position
  if max_output_duration < MIN_SHOT_SIZE
    print("skipping #{sync_sound_filename}, too short clip, duration=#{duration}, max_output_duration=#{max_output_duration}\n")
    return segments
  end

  voice_segments = detect_voice(sync_sound_filename, MIN_SHOT_SIZE, options[:min_pause_between_shots],
                                options[:aggressiveness])
  print("voice segments: #{voice_segments.join(',')} (aggressiveness=#{options[:aggressiveness]})\n")

  unless voice_segments.empty?
    segments = voice_segments

    segments[0][0] = [start_position, segments[0][0]].max
    last = segments.length - 1
    segments[last][1] = [end_position, segments[last][1]].min

    segments = segments.filter { |r| r[0] < r[1] }
  end

  segments = [[start_position, end_position]] if segments.empty?

  print("detect_segments: #{segments.join(',')}\n")
  segments
end

def main(argv)
  # TODO: extract?
  options = {
    min_pause_between_shots: 2.0,
    aggressiveness: 0.4
  }

  parse_options!(options, argv)
  project_dir = options[:project_dir]
  temp_dir = File.join project_dir, 'tmp'
  FileUtils.mkdir_p(temp_dir)

  min_pause_between_shots = options[:min_pause_between_shots]
  aggressiveness = options[:aggressiveness]

  clip_num = 1
  rotation = 90
  camera_filename = File.join project_dir, "input_00000#{clip_num}.mp4" # TODO: leading zeros
  sync_sound_filename = prepare_sync_sound(camera_filename)

  segments = detect_segments(sync_sound_filename, camera_filename, options)
  print("segments=#{segments}\n")
  processed_sound_filenames = process_sound(sync_sound_filename, segments)
  print("processed_sound_filenames=#{processed_sound_filenames}\n")
  processed_video_filenames = process_video(camera_filename, segments)
  print("processed_video_filenames=#{processed_video_filenames}\n")
  output_filenames = merge_files(processed_sound_filenames, processed_video_filenames, clip_num, rotation, project_dir)
  print("output_filenames=#{output_filenames}\n")
  FileUtils.rm_f [sync_sound_filename] + processed_sound_filenames + processed_video_filenames
  print("removed files\n")
end

main(ARGV)