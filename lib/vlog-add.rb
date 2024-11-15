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
require 'set'

def parse_options!(options, args)
  parser = OptionParser.new do |opts|
    opts.set_banner("Usage: vlog-add -p project_dir/ [other options]\nProject directory must contain inputvoice_000001.mp4, inputother_000002.mp4 ... as input files (also optionally inputvoice_000001.wav, inputother_000002.wav ... with highest audio quality)")
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

def prepare_sync_sound(camera_filename)
  sound_filename = "#{camera_filename.gsub(/\.mp4$/, '')}.wav"
  command = FFMPEG_NO_OVERWRITE + [
    '-i', camera_filename,
    '-af', EXTRACT_LEFT_CHANNEL_FILTER,
    '-vn',
    sound_filename
  ]
  system "#{command.shelljoin_wrapped}"

  sync_offset, sync_sound_filename = synchronize_sound(camera_filename, sound_filename)
  [sync_offset, sync_sound_filename]
end

# TODO: ~identical to vlog-record implementation
def detect_segments(sync_sound_filename, camera_filename, sync_offset, options, trim_noise)
  sync_sound_duration = get_duration(sync_sound_filename)
  duration = [get_duration(camera_filename), sync_sound_duration].min

  start_position = [0.0, sync_offset.abs].max
  end_position = duration

  segments = []

  max_output_duration = end_position - start_position
  if max_output_duration < MIN_SHOT_SIZE
    print("skipping #{sync_sound_filename}, too short clip, duration=#{duration}, max_output_duration=#{max_output_duration}\n")
    return segments
  end

  if trim_noise
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
  end

  segments = [[start_position, end_position]] if segments.empty?

  print("detect_segments: #{segments.join(',')}\n")
  segments
end

def process_clip(clip_num, camera_filename, options)
  print("process_clip #{clip_num} #{camera_filename}\n")

  print("clip_num=#{clip_num} preparing sync sound\n")
  sync_offset, sync_sound_filename = prepare_sync_sound(camera_filename)
  print("clip_num=#{clip_num} sync_offset=#{sync_offset}\n")
  trim_noise = File.basename(camera_filename).start_with?('inputvoice_0')
  print("clip_num=#{clip_num} trim_noise=#{trim_noise}\n")
  segments = detect_segments(sync_sound_filename, camera_filename, sync_offset, options, trim_noise)
  print("clip_num=#{clip_num} segments=#{segments}\n")
  processed_sound_filenames = process_sound(sync_sound_filename, segments)
  print("clip_num=#{clip_num} processed_sound_filenames=#{processed_sound_filenames}\n")

  processed_video_filenames = process_video(camera_filename, segments)
  print("clip_num=#{clip_num} processed_video_filenames=#{processed_video_filenames}\n")

  output_filenames = merge_media(processed_sound_filenames, processed_video_filenames, clip_num, options[:rotation],
                                 options[:project_dir])
  print("clip_num=#{clip_num} output_filenames=#{output_filenames}\n")

  FileUtils.rm_f [sync_sound_filename] + processed_sound_filenames + processed_video_filenames
  print("clip_num=#{clip_num} ok\n")
end

def main(argv)
  # TODO: extract?
  options = {
    min_pause_between_shots: 2.0,
    aggressiveness: 0.4,
    rotation: '90' # TODO: detect from width and height; overwritable with options
  }

  parse_options!(options, argv)

  project_dir = options[:project_dir]
  temp_dir = File.join project_dir, 'tmp'
  FileUtils.mkdir_p(temp_dir)

  min_pause_between_shots = options[:min_pause_between_shots]
  aggressiveness = options[:aggressiveness]

  media_thread_pool = Concurrent::FixedThreadPool.new(Concurrent.processor_count)

  camera_filenames = Dir.glob("#{project_dir}#{File::SEPARATOR}input{voice,other}_0*.mp4")
  processed_clips = Dir.glob("#{project_dir}#{File::SEPARATOR}0*.mp4").map { |i| filename_to_clip(i) }.to_set

  clip_nums_and_camera_filenames = camera_filenames.map do |camera_filename|
    clip_num = File.basename(camera_filename).split('_')[1].to_i
    [clip_num, camera_filename]
  end

  unless clip_nums_and_camera_filenames.map { |clip_num, _camera_filename| clip_num }.unique_items?
    raise 'input files contain non-unique clip numbers'
  end

  unprocessed_items = clip_nums_and_camera_filenames.filter do |clip_num, _camera_filename|
    !processed_clips.include?(clip_num)
  end
  print("adding #{unprocessed_items.length} inputs (total inputs: #{camera_filenames.length})\n")

  unprocessed_items.each do |i|
    clip_num, camera_filename = i
    print("scheduling #{clip_num} (#{camera_filename})\n")
    media_thread_pool.post do
      print("processing #{clip_num} (#{camera_filename})\n")
      process_clip(clip_num, camera_filename, options)
      print("#{camera_filename} (#{clip_num}/#{camera_filenames.length})\n")
    rescue SystemExit, Interrupt
    rescue StandardError => e
      puts e
    end
  end

  media_thread_pool.shutdown
  media_thread_pool.wait_for_termination
  STDOUT.flush

  print("splitting is finished 🎉\n")
end

main(ARGV)
