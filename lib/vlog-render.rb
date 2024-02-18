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
require 'numeric_utils'
require 'phone'
require 'process_utils'

require 'concurrent'
require 'fileutils'
require 'io/console'
require 'json'
require 'mkmf'
require 'optparse'

PREVIEW_WIDTH = 320 # TODO: increase preview size for nvidia
CONFIG_FILENAME = 'render.conf'.freeze
RENDER_DEFAULT_SPEED = '1.00'

def parse(filename, options)
  File.open filename do |f|
    f.reject { |line| line.start_with? '#' }
     .map { |line| line.split("\t") }
     .map
     .with_index do |cols, index|
      if cols[0] == "\n" then { index: index, empty: true }
      else
        video_filename, speed, start_position, end_position, text = cols
        text = text.sub(/#.*$/, '')
        words = text.split(' ').length

        final_speed = clamp_speed(speed.to_f * options[:speed])
        min_speed = 1.0 # FIXME: set min speed to 44.1/48?
        if final_speed < min_speed
          print("segment #{video_filename} has speed #{final_speed} < 1; forcing speed #{min_speed}\n")
          final_speed = min_speed
        end

        {
          index: index,
          video_filename: video_filename,
          speed: final_speed,
          start_position: start_position.to_f,
          end_position: end_position.to_f,
          words: words,
          empty: false
        }
      end
    end
  end
end

def apply_delays(segments)
  print("computing delays\n")

  delay_time = 1.0

  start_correction = 0.3
  end_correction = 0.3

  video_durations = {}

  segments
    .reverse
    .inject([0, []]) do |(delays, acc), seg|
      if seg[:empty] then [delays + 1, acc]
      else
        [0, acc + [[seg, delays]]] end
    end[1]
    .reverse
    .reject { |(seg, _delays)| seg[:empty] }
    .map do |(seg, delays)|
    if video_durations[seg[:video_filename]].nil?
      video_durations[seg[:video_filename]] = get_duration seg[:video_filename]
    end
    duration = video_durations[seg[:video_filename]]

    new_start_position = [seg[:start_position] - start_correction, 0.0].max
    new_end_position = [seg[:end_position] + delays * delay_time + end_correction, duration].min
    seg.merge(start_position: new_start_position)
    seg.merge(end_position: new_end_position)
  end
end

def in_segment?(position, segment)
  (segment[:start_position]..segment[:end_position]).cover? position
end

def segments_overlap?(a, b)
  in_segment?(a[:start_position], b) || in_segment?(a[:end_position], b)
end

def merge_small_pauses(segments, min_pause_between_shots)
  segments.inject([]) do |acc, seg|
    if acc.empty?
      acc.append(seg.clone)
    else
      prev = acc.last
      dt = seg[:start_position] - prev[:end_position]
      has_overlap = segments_overlap?(seg, prev)
      is_successor = (seg[:video_filename] == prev[:video_filename]) && (dt < min_pause_between_shots || has_overlap)
      if is_successor
        prev[:start_position] = [seg[:start_position], prev[:start_position]].min
        prev[:start_position] = 0.0 if prev[:start_position] < 0.2
        prev[:end_position] = [seg[:end_position], prev[:end_position]].max
        prev[:speed] = [seg[:speed], prev[:speed]].max
      else
        acc.append(seg.clone)
      end
      acc
    end
  end
end

def rotation_filter(basename)
  rotation = basename.split('_')[2]
  rotation =
    if rotation.nil?
      Phone::LANDSCAPE_FRONT_CAMERA_ON_LEFT
    else
      rotation.split('.')[0].to_i
    end
  if rotation == Phone::PORTRAIT
    'transpose=dir=cclock'
  elsif rotation == Phone::REVERSED_PORTRAIT
    'transpose=dir=clock'
  elsif rotation == Phone::LANDSCAPE_FRONT_CAMERA_ON_LEFT
    ''
  elsif rotation == Phone::LANDSCAPE_FRONT_CAMERA_ON_RIGHT
    'transpose=dir=clock,transpose=dir=clock'
  else
    raise 'unexpected rotation'
  end
end

def remove_file_if_empty(filename)
  return unless File.exist?(filename) && File.size(filename) == 0

  File.delete(filename)
end

def process_and_split_videos(segments, options, output_dir, temp_dir)
  video_codec =
    if nvenc_supported?('hevc_nvenc')
      'hevc_nvenc -preset p1 -cq 18 -qp 18'
    else
      'libx265 -preset ultrafast -crf 18'
    end

  print("processing video clips\n")

  fps = options[:fps]
  preview = options[:preview]

  media_thread_pool = Concurrent::FixedThreadPool.new(Concurrent.processor_count)

  temp_videos = segments.map.with_index do |seg, index|
    # FIXME: make less confusing paths, perhaps with hashing, also .cache extension
    ext = '.mp4'
    line_in_config = seg[:index] + 1
    basename = File.basename seg[:video_filename]

    base_output_filename = (seg.reject { |key|
      key == :index
    }.values.map(&:to_s) + [preview.to_s]).join('_')
    output_filename = File.join(preview ? temp_dir : output_dir, base_output_filename + ext)
    temp_cut_output_filename = File.join(temp_dir, base_output_filename + '.cut' + ext)

    media_thread_pool.post do
      audio_filters = "atempo=#{seg[:speed]}"
      video_filters = [
        rotation_filter(basename),
        options[:video_filters],
        "fps=#{fps}",
        "setpts=(1/#{seg[:speed]})*PTS" # TODO: is it correct?
      ].reject { |i| i.empty? }.join(',')
      if preview
        video_filters = [
          "scale=#{PREVIEW_WIDTH}:-1",
          "#{video_filters}",
          "drawtext=fontcolor=white:x=#{PREVIEW_WIDTH / 3}:text=#{basename}/L#{line_in_config}"
        ].join(',')
      end

      # might be uneeded step anymore,
      # but still might be useful for NLE video editors
      dt = seg[:end_position] - seg[:start_position]
      command = FFMPEG_NO_OVERWRITE + [
        '-threads', Concurrent.processor_count,
        '-ss', seg[:start_position],
        '-i', seg[:video_filename],
        '-to', dt,
        '-strict', '-2',
        '-codec', 'copy',
        '-movflags', 'faststart',
        temp_cut_output_filename
      ]
      remove_file_if_empty(temp_cut_output_filename)
      system command.shelljoin_wrapped

      command = FFMPEG_NO_OVERWRITE + [
        '-threads', Concurrent.processor_count,
        '-i', temp_cut_output_filename,
        '-vcodec', video_codec,
        '-vf', video_filters,
        '-af', audio_filters,
        '-strict', '-2',
        '-acodec', 'flac',
        '-movflags', 'faststart',
        output_filename
      ]
      remove_file_if_empty(output_filename)
      system command.shelljoin_wrapped

      print("#{basename} (#{index + 1}/#{segments.length})\n")

      FileUtils.rm_f temp_cut_output_filename if options[:cleanup]
    rescue StandardError => e
      print("exception for segment #{seg}: #{e} #{e.backtrace}\n")
    end

    output_filename
  end

  media_thread_pool.shutdown
  media_thread_pool.wait_for_termination

  temp_videos
end

def concat_videos(temp_videos, output_filename)
  print("rendering to #{output_filename}\n")

  parts = temp_videos.map { |f| "file 'file:#{f}'" }
                     .join "\n"

  # TODO: migrate async to aresample
  command = FFMPEG + [
    '-async', 1,
    '-f', 'concat',
    '-safe', 0,
    '-protocol_whitelist', 'file,pipe',
    '-i', '-',
    '-codec', 'copy',
    '-movflags', 'faststart',
    '-strict', '-2',
    output_filename
  ]

  IO.popen(command.shelljoin_wrapped, 'w') do |f|
    f.puts parts
    f.close_write
  end

  print("done\n")
end

def optimize_for_youtube(output_filename, options, temp_dir)
  print("reencoding for youtube\n")

  output_basename_no_ext = "#{File.basename(output_filename, File.extname(output_filename))}.youtube"
  temp_youtube_flac_h264_filename = File.join(temp_dir, "#{output_basename_no_ext}.flac.h264.mp4")
  temp_youtube_opus_filename = File.join(temp_dir, "#{output_basename_no_ext}.opus")
  temp_youtube_wav_filename = File.join(temp_dir, "#{output_basename_no_ext}.wav")
  output_youtube_filename = File.join(options[:project_dir], "#{output_basename_no_ext}.mp4")

  video_codec =
    if nvenc_supported?('h264_nvenc')
      'h264_nvenc -preset slow -cq 18'
    else
      'libx264 -preset ultrafast -crf 18'
    end

  command =
    FFMPEG + [
      '-threads', Concurrent.processor_count,
      '-i', output_filename,
      '-vcodec', video_codec,
      '-acodec', 'flac',
      '-pix_fmt', 'yuv420p',
      '-movflags', 'faststart',
      '-strict', '-2',
      temp_youtube_flac_h264_filename
    ]
  system command.shelljoin_wrapped

  command = FFMPEG + [
    '-i', temp_youtube_flac_h264_filename,
    temp_youtube_wav_filename
  ]
  system command.shelljoin_wrapped

  print("encoding to opus\n")
  system [
    'opusenc',
    '--quiet',
    '--bitrate', 510,
    temp_youtube_wav_filename,
    temp_youtube_opus_filename
  ].shelljoin_wrapped

  print("producing youtube output\n")
  command = FFMPEG + [
    '-an',
    '-i', temp_youtube_flac_h264_filename,
    '-i', temp_youtube_opus_filename,
    '-c', 'copy',
    '-strict', '-2',
    output_youtube_filename
  ]
  system command.shelljoin_wrapped

  if options[:cleanup]
    FileUtils.rm_f [temp_youtube_flac_h264_filename, temp_youtube_wav_filename,
                    temp_youtube_opus_filename]
  end

  output_youtube_filename
end

def compute_player_position(segments, options)
  segments.filter { |seg| seg[:index] < options[:line_in_file] - 1 }
          .map { |seg| seg[:end_position] - seg[:start_position] }
          .sum / clamp_speed(options[:speed])
end

def nvidia_cuda_ready?
  if (find_executable 'nvcc').nil?
    print("nvidia-cuda-toolkit is not installed\n")
    false
  elsif !File.exist?('/dev/nvidia0')
    print("nvidia module is not loaded\n")
    false
  else
    true
  end
end

def nvenc_supported?(encoder)
  command = FFMPEG + ['--help', "encoder=#{encoder}"]
  if `#{command.shelljoin_wrapped}`.include?('is not recognized')
    print("ffmpeg was built without #{encoder} support\n")
    false
  else
    nvidia_cuda_ready?
  end
end

# FIXME: move tests to some proper place
def test_segments_overlap
  raise unless segments_overlap?({ start_position: 0.0, end_position: 5.0 }, start_position: 4.0, end_position: 6.0)
  raise unless segments_overlap?({ start_position: 0.0, end_position: 5.0 }, start_position: 5.0, end_position: 6.0)
  raise if segments_overlap?({ start_position: 0.0, end_position: 5.0 }, start_position: 6.0, end_position: 7.0)

  raise unless segments_overlap?({ start_position: 4.0, end_position: 6.0 }, start_position: 0.0, end_position: 5.0)
  raise unless segments_overlap?({ start_position: 5.0, end_position: 6.0 }, start_position: 0.0, end_position: 5.0)
  raise if segments_overlap?({ start_position: 6.0, end_position: 7.0 }, start_position: 0.0, end_position: 5.0)
end

def test_merge_small_pauses
  min_pause_between_shots = 2.0

  segments = [
    { index: 0, video_filename: 'a.mp4', start_position: 0.0, end_position: 5.0, speed: 1.0 },
    { index: 1, video_filename: 'a.mp4', start_position: 5.5, end_position: 10.0, speed: 1.5 },
    { index: 2, video_filename: 'b.mp4', start_position: 1.0, end_position: 3.0, speed: 1.0 },
    { index: 3, video_filename: 'b.mp4', start_position: 10.0, end_position: 20.0, speed: 1.0 },
    { index: 3, video_filename: 'b.mp4', start_position: 19.0, end_position: 22.0, speed: 1.8 },
    { index: 4, video_filename: 'b.mp4', start_position: 6.0, end_position: 8.0, speed: 1.0 },
    { index: 4, video_filename: 'b.mp4', start_position: 3.0, end_position: 7.0, speed: 1.0 }
  ]

  expected = [
    { index: 0, video_filename: 'a.mp4', start_position: 0.0, end_position: 10.0, speed: 1.5 },
    { index: 2, video_filename: 'b.mp4', start_position: 1.0, end_position: 3.0, speed: 1.0 },
    { index: 3, video_filename: 'b.mp4', start_position: 3.0, end_position: 22.0, speed: 1.8 }
  ]

  result = merge_small_pauses(segments, min_pause_between_shots)
  raise unless result == expected
end

def generate_config(options)
  # TODO: add commit hash to header
  render_conf_filename = File.join(options[:project_dir], 'render.conf')
  exists = File.exist?(render_conf_filename)
  File.open(render_conf_filename, exists ? 'r+' : 'w') do |render_conf_file|
    video_filenames = Dir.glob("#{options[:project_dir]}#{File::SEPARATOR}0*.mp4").sort
    if exists
      # skip all clips listed in the config (including commented ones),
      # don't write already removed subclips
      last_line = render_conf_file.readlines.last
      first_column = last_line.split("\t")[0]
      last_recorded_filename = first_column.split('#').last.strip
      last_recorded_clip = filename_to_clip(last_recorded_filename)
      print("last_recorded_clip = #{last_recorded_clip}\n")
      skip_clips = video_filenames.filter { |i| filename_to_clip(i) <= last_recorded_clip }.length
      video_filenames = video_filenames.drop(skip_clips)
    else
      write_columns(render_conf_file, ['#filename', 'speed', 'start', 'end', 'text'])
    end

    sound_with_single_channel_filenames = video_filenames.map { |i| prepare_for_vad(i) }
    if sound_with_single_channel_filenames.empty?
      print("nothing to transcribe\n")
    else
      command = [
        './main',
        '--output-json'
      ] + [options[:whisper_cpp_args]] + sound_with_single_channel_filenames
      Dir.chdir options[:whisper_cpp_dir] do
        print("#{command}\n")
        system command.shelljoin_wrapped
      end
    end

    # TODO: jsons and vad.wavs are supposed to be in tmp
    for i, sound_with_single_channel_filename in video_filenames.zip(sound_with_single_channel_filenames)
      FileUtils.rm_f sound_with_single_channel_filename

      transcribed_json = "#{sound_with_single_channel_filename}.json"
      for transcription in JSON.parse(File.read(transcribed_json))['transcription']
        offsets = transcription['offsets']
        line = [
          File.basename(i),
          RENDER_DEFAULT_SPEED,
          ms_to_sec(offsets['from']),
          ms_to_sec(offsets['to']),
          transcription['text']
        ]
        write_columns(render_conf_file, line)
      end

      FileUtils.rm_f transcribed_json
    end
  end

  exists
end

def filename_to_clip(filename)
  # 000123_000000.mp4 => 123 is clip, 0 is subclip
  basename = File.basename(filename)
  basename.split('_').first.to_i
end

def write_columns(file, columns)
  file.write(columns.join("\t") + "\n")
end

def ms_to_sec(ms)
  ms.to_f / 1000.0
end

def parse_options!(options, args)
  parser = OptionParser.new do |opts|
    opts.set_banner('Usage: vlog-render -p project_dir/ -w path/to/whisper.cpp/ [other options]')
    opts.set_summary_indent('  ')
    opts.on('-p', '--project <dir>', 'Project directory') { |p| options[:project_dir] = p }
    opts.on('-L', '--line <num>',
            "Line in #{CONFIG_FILENAME} file, to play by given position (default: #{options[:line_in_file]})") do |l|
      options[:line_in_file] = l
    end
    opts.on('-P', '--preview <true|false>',
            "Preview mode. It will also start a video player by a given position (default: #{options[:preview]})") do |p|
      options[:preview] = p == 'true'
    end
    opts.on('-f', '--fps <num>', "Constant frame rate (default: #{options[:fps]})") { |f| options[:fps] = f.to_i }
    opts.on('-S', '--speed <num>', "Speed factor (default: #{options[:speed]})") { |s| options[:speed] = s.to_f }
    opts.on('-V', '--video-filters <filters>', "ffmpeg video filters (default: \"#{options[:video_filters]}\")") do |v|
      options[:video_filters] = v
    end
    opts.on('-c', '--cleanup <true|false>',
            "Remove temporary files, instead of reusing them in future (default: #{options[:cleanup]})") do |c|
      options[:cleanup] = c == 'true'
    end
    opts.on('-w', '--whisper-cpp-dir <dir>', 'whisper.cpp directory') do |w|
      options[:whisper_cpp_dir] = w
    end
    opts.on('-W', '--whisper-cpp-args <dir>',
            "Additional whisper.cpp arguments (default: \"#{options[:whisper_cpp_args]}\")") do |w|
      options[:whisper_cpp_args] += " #{w}"
    end
    opts.on('-y', '--youtube <true|false>',
            "Additionally optimize for youtube (default: #{options[:youtube]})") do |y|
      options[:youtube] = y == 'true'
    end
    # TODO: iOS: ffmpeg -threads 16 -i output.mp4 -vcodec h264_nvenc -preset slow -cq 18 -to 10 -acodec alac -movflags faststart -strict -2 test4.mov
  end

  parser.parse!(args)

  return unless options[:project_dir].nil?

  print(parser.help)
  exit 1
end

def main(argv)
  test_merge_small_pauses
  test_segments_overlap

  options = {
    fps: 30,
    speed: 1.2,
    video_filters: 'hqdn3d,hflip,vignette',
    min_pause_between_shots: 0.1,
    preview: true,
    line_in_file: 1,
    cleanup: false,
    whisper_cpp_args: '--model models/ggml-base.bin --language auto',
    youtube: false
  }

  parse_options!(options, argv)

  project_dir = options[:project_dir]
  config_filename = File.join project_dir, CONFIG_FILENAME

  old_config = generate_config(options)
  unless old_config
    print("Configuration file is ready! 🎉\n")
    print("Now edit #{config_filename} and restart this script to finish\n")
    exit 0
  end

  output_postfix = options[:preview] ? '_preview' : ''
  output_filename = File.join project_dir, "output#{output_postfix}.mp4"

  Dir.chdir project_dir

  min_pause_between_shots = 0.1
  segments = merge_small_pauses apply_delays(parse(config_filename, options)), min_pause_between_shots

  output_dir = File.join project_dir, 'output'
  temp_dir = File.join project_dir, 'tmp'
  FileUtils.mkdir_p [output_dir, temp_dir]

  temp_videos = process_and_split_videos segments, options, output_dir, temp_dir
  concat_videos temp_videos, output_filename

  words_per_second = segments.map do |seg|
    dt = seg[:end_position] - seg[:start_position]
    duration = dt / seg[:speed]
    seg[:words] / duration
  end.sum / segments.length

  print("average words per second = #{words_per_second}\n")

  if options[:preview]
    player_position = compute_player_position segments, options
    print("player_position = #{player_position}\n")
    command = MPV + ["--start=#{player_position}", '--no-fs', output_filename]
    system command.shelljoin_wrapped
  else
    output_youtube_filename = optimize_for_youtube(output_filename, options, temp_dir) if options[:youtube]

    print("done 🎉\n")
    print("you can run:\n\n")
    mpv_args = ['mpv', '--no-resume-playback', '--af=scaletempo2', '--speed=1', '--fs']
    command = mpv_args + [output_filename]
    print(command.shelljoin_wrapped + "\n\n")
    print((mpv_args + [output_youtube_filename]).shelljoin_wrapped + "\n\n") if options[:youtube]

    # TODO: --play? --preview true?
    # if options[:play]
    system(command.shelljoin_wrapped)
    # end
  end

  # TODO: add --gc flag to remove no longer needed tmp/output files
end

main(ARGV)
