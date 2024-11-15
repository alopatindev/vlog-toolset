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
require 'os_utils'
require 'phone'
require 'process_utils'

require 'concurrent'
require 'digest/crc32'
require 'fileutils'
require 'io/console'
require 'json'
require 'mkmf'
require 'mpv'
require 'neovim'
require 'optparse'
require 'parallel'

CONFIG_FILENAME = 'render.conf'
RENDER_DEFAULT_SPEED = '1.00'

AMPLITUDE_METER = '--lavfi-complex=[aid1]asplit[ao][a];[a]showvolume=rate=30:p=1:w=100:h=18:t=0:m=p:f=0:dm=0:dmc=yellow:v=0:ds=log:b=5:p=0.5:s=1,scale=iw/3:-1[vv];[vid1][vv]overlay=x=(W-w)/2:y=(H-h)*0.88[vo]'

SUPPORTED_COLOR_STANDARDS = ['BT.709', 'BT.2020']

class Renderer
  def initialize(config_filename, config_in_nvim, nvim_socket, options, terminal_window_id)
    @config_filename = config_filename
    @config_in_nvim = config_in_nvim
    @nvim_socket = nvim_socket
    @segments = []
    @options = options
    @video_durations = {}
    @terminal_window_id = terminal_window_id
    @mpv_socket = File.join(@options[:project_dir], 'mpv.sock')
    @output_filename = nil
  end

  def render(rerender = false)
    print("rendering#{@options[:preview] ? '' : ' FINAL OUTPUT'}\n")

    rerender_postfix = rerender ? '_rerender' : ''
    @output_filename = File.join(@options[:project_dir], "output#{output_postfix(@options)}#{rerender_postfix}.mp4")

    min_pause_between_shots = 0.1 # FIXME: should be in @options, but -P is already used?
    @segments = parse_config(@config_filename, @options)
    apply_delays
    @segments = merge_small_pauses(@segments, min_pause_between_shots) # TODO

    raise 'Empty video?' if @segments.empty?

    output_dir, temp_dir = dirs(@options)

    temp_videos = process_and_split_videos(output_dir, temp_dir)
    concat_videos(temp_videos, @output_filename)

    words_per_second = @segments.map do |seg|
      dt = seg[:end_position] - seg[:start_position]
      duration = dt / seg[:speed]
      seg[:words] / duration
    end.sum / @segments.length

    print("finished rendering\n")
    print("average words per second = #{words_per_second}\n")

    @output_filename
  end

  def apply_delays
    print("computing delays\n")

    delay_time = 1.0

    start_correction = 0.3
    end_correction = 0.3

    segments_and_delays =
      @segments
      .reverse
      .inject([0, []]) do |(delays, acc), seg|
        if seg[:empty] then [delays + 1, acc]
        else
          [0, acc + [[seg, delays]]] end
      end[1]
      .reverse
      .reject { |(seg, _delays)| seg[:empty] }
      .to_a

    video_filenames = segments_and_delays.map { |(seg, _)| seg[:video_filename] }.to_set
    @video_durations = @video_durations.merge(
      Parallel.map(video_filenames.reject { |i| @video_durations.include?(i) }) do |i|
        [i, get_duration(i)]
      end.to_h
    )

    @segments = segments_and_delays.map do |(seg, delays)|
      duration = @video_durations[seg[:video_filename]]
      new_start_position = [seg[:start_position] - start_correction, 0.0].max
      new_end_position = [seg[:end_position] + delays * delay_time + end_correction, duration].min
      seg.merge(start_position: new_start_position)
      seg.merge(end_position: new_end_position)
    end
  end

  def run_preview_loop(nvim)
    if @config_in_nvim
      buffer = nvim.current.buffer

      toggle_fullscreen = prepare_mpv_command(%w[cycle fullscreen])
      quit_mpv = prepare_mpv_command(['quit'])
      pause_mpv = prepare_mpv_command(['set_property', 'pause', true])
      pause_mpv_and_update_toggle_playback_flag = "#{pause_mpv}:let g:allow_playback = !g:allow_playback<Enter>"

      nvim.command("nnoremap f #{toggle_fullscreen}")
      nvim.command("nnoremap q #{quit_mpv}")
      nvim.command("nnoremap <Esc> #{pause_mpv_and_update_toggle_playback_flag}")
      nvim.command("nnoremap <Space> #{pause_mpv_and_update_toggle_playback_flag}")
      nvim.command('let g:allow_playback = v:true')
      for i in 'hjkl'.each_char
        nvim.command("nnoremap #{i} #{pause_mpv}:let g:allow_playback = v:false<Enter>#{i}")
      end
    end

    @restart_mpv = true
    @mpv_speed = 1.0
    loop do
      if @config_in_nvim
        line_in_config = buffer.line_number
        if buffer.get_name == @config_filename
          print("current nvim line is #{line_in_config}\n")
          @options[:line_in_config] = [@segments.first[:line_in_config], line_in_config - 1].max
        end
      end

      player_position = compute_player_position(@options[:line_in_config])
      print("player_position = #{player_position}\n")

      if @restart_mpv
        command = MPV_COMMAND + [
          '--pause',
          "--start=#{player_position}",
          "--input-ipc-server=#{@mpv_socket}",
          "--speed=#{@mpv_speed}",
          '--volume=130',
          '--no-fs',
          '--geometry=30%+0+0',
          '--title=vlog-preview',
          '--script-opts-append=osc-visibility=always',
          '--no-terminal'
        ] + (@options[:preview] ? [AMPLITUDE_METER] : []) + [@output_filename]
        system command.shelljoin_wrapped + ' &'
      end

      sleep 0.5

      switch_to_window(@terminal_window_id) if @restart_mpv

      break unless @config_in_nvim && File.socket?(@nvim_socket) && File.socket?(@mpv_socket)

      run_mpv_loop(nvim)
      break if @segments.empty?
    end
  end

  def run_mpv_loop(nvim)
    print("run_mpv_loop\n")
    begin
      config_crc32 = checksum(@config_filename)
      config_mtime = File.mtime(@config_filename)

      output_crc32 = File.exist?(@output_filename) ? checksum(@output_filename) : ''

      mpv = MPV::Client.new(@mpv_socket)

      loop do
        break unless mpv.alive?

        rewritten_config = File.mtime(@config_filename) != config_mtime && checksum(@config_filename) != config_crc32

        update_mpv_playback(mpv, nvim, rewritten_config)

        if rewritten_config
          new_output_filename = render(rerender = true)
          new_mpv_speed = mpv.get_property('speed')
          @mpv_speed = new_mpv_speed unless new_mpv_speed.nil?
          print("mpv speed was #{@mpv_speed}\n")
          @restart_mpv =
            if checksum(new_output_filename) == output_crc32
              print("no changes in the rendered output, skipping\n")
              FileUtils.rm_f new_output_filename
              nvim.command('let g:allow_playback = v:true')
              false
            else
              print("restarting player\n")
              mpv.quit!
              File.rename(new_output_filename, @output_filename)
              true
            end
          return
        else
          sleep 0.1
        end
      end
    rescue StandardError => e
      print("closing player due to error: #{e} #{e.backtrace}\n")
      mpv.quit! unless mpv.nil?
    end
    @restart_mpv = false
    @segments = []
    @video_durations = {}
  end

  def process_and_split_videos(output_dir, temp_dir)
    video_codec = h265_video_codec
    nv_hw_accelerated = video_codec.include?('_nvenc')
    preview_width =
      if nv_hw_accelerated
        480
      else
        320
      end

    scale_filter = nv_hw_accelerated ? "hwupload_cuda,scale_cuda=#{preview_width}:-2" : "scale=#{preview_width}:-2"

    video_color_infos = @segments
                        .map { |seg| seg[:video_filename] }
                        .to_set
                        .map { |filename| get_color_info(filename) }
                        .to_set
                        .to_a

    print("colors: #{video_color_infos}\n")

    raise 'no color infos' if video_color_infos.empty?

    colorspace_filter =
      if @options[:force_colorspace]
        #      if video_color_infos.length > 1 || (@options[:force_colorspace] && SUPPORTED_COLOR_STANDARDS.any? do |standard|
        #                                            video_color_infos[0][:standard].include?(standard)
        #                                          end)
        standard =
          if video_color_infos.any? { |info| info[:standard].include?('BT.2020') }
            'bt2020'
          else
            'bt709'
          end
        print("forcing colorspace #{standard}\n")
        ["colorspace=all=#{standard}:itrc=srgb:fast=0:format=yuv444p10"]
      else
        print("using the same colorspace\n")
        []
      end

    print("processing video clips (applying filters, etc.)\n")

    fps = @options[:fps]
    preview = @options[:preview]
    desired_brightness = @options[:desired_brightness]

    print("preview_width=#{preview_width}\n") if preview

    processed_segments = 0
    processed_segments_mutex = Mutex.new

    media_thread_pool = Concurrent::FixedThreadPool.new(Concurrent.processor_count)

    temp_videos = @segments.map do |seg|
      # FIXME: make less confusing paths, perhaps with hashing, also .cache extension
      #        output dir: line in file + (clip/subclip?) + hash, always identify by hash, rename the line
      ext = '.mp4'
      line_in_config = seg[:line_in_config]
      basename = File.basename seg[:video_filename]

      hash_key = (seg.reject { |key|
        key == :line_in_config
      }.values.map(&:to_s) + [preview.to_s]).join('_')
      hash_value = Digest::SHA256.hexdigest(hash_key)

      temp_cut_output_filename = File.join(temp_dir, hash_value + ext)
      base_output_filename = "#{line_in_config.with_leading_zeros}_#{hash_value}"

      output_filename = File.join(preview ? temp_dir : output_dir, base_output_filename + ext)

      old_output_filename = Dir.glob("#{preview ? temp_dir : output_dir}#{File::SEPARATOR}0*_#{hash_value}#{ext}").first
      if !old_output_filename.nil? && output_filename != old_output_filename
        print("renaming #{old_output_filename} => #{output_filename}\n")
        File.rename(old_output_filename, output_filename)
      end

      # TODO: split using -f segment -segment_time 10 ?

      remove_file_if_empty(temp_cut_output_filename)
      remove_file_if_empty(output_filename)

      unless File.exist?(output_filename)
        media_thread_pool.post do
          brightness_filter =
            if desired_brightness > 0.0
              mean_color = get_mean_color(seg[:video_filename])
              delta_brightness = desired_brightness - get_luminance(mean_color)
              delta_saturation = 1.0 - get_saturation(mean_color)
              ["eq=brightness=#{delta_brightness}:saturation=#{delta_saturation}"]
            else
              []
            end

          audio_filters = "atempo=#{seg[:speed]},asetpts=PTS-STARTPTS"
          video_filters = [
            rotation_filter(basename)
          ] + colorspace_filter + brightness_filter + [
            @options[:video_filters],
            "fps=#{fps}",
            "setpts=(1/#{seg[:speed]})*PTS" # TODO: is it correct?
          ]
          video_filters = [scale_filter] + video_filters if preview

          video_filters = video_filters.reject { |i| i.empty? }.join(',')

          # -filter_complex '[0:a]showvolume=rate=60:p=1,scale=1920/5:1080/36[vv];[0:v][vv]overlay=x=(W-w)/2:y=h/2[v]' -map '[v]' -map '0:a'

          # TODO: do second audio sync for individually cut fragments to avoid audio drift? best moment for that

          threads = [0, Concurrent.processor_count - @segments.length].max + 1
          dt = seg[:end_position] - seg[:start_position]

          # might be uneeded step anymore,
          # but still might be useful for NLE video editors
          command = FFMPEG_NO_OVERWRITE + [
            '-threads', threads,
            '-fflags', '+genpts+igndts',
            '-ss', seg[:start_position],
            '-i', seg[:video_filename],
            '-to', dt,
            '-codec', 'copy',
            '-movflags', 'faststart',
            '-strict', '-2',
            temp_cut_output_filename
          ]
          system command.shelljoin_wrapped

          command = FFMPEG_NO_OVERWRITE + [
            '-threads', threads,
            '-fflags', '+genpts+igndts',
            '-i', temp_cut_output_filename,
            '-vsync', 'cfr',
            '-sample_fmt', FLAC_SAMPLING_FORMAT,
            '-vcodec', video_codec,
            '-vf', video_filters,
            '-af', audio_filters,
            '-acodec', 'flac',
            # '-pix_fmt', 'yuv422p', # TODO: optional?
            '-movflags', 'faststart',
            '-strict', '-2',
            output_filename
          ]
          system command.shelljoin_wrapped

          FileUtils.rm_f temp_cut_output_filename if @options[:cleanup]

          processed_segments_value = processed_segments_mutex.synchronize do
            processed_segments += 1
            processed_segments
          end
          progress = ((processed_segments_value.to_f / @segments.length.to_f) * 100.0).round(1)
          print("#{basename} (#{progress}%)\n")
        rescue StandardError => e
          print("exception for segment #{seg}: #{e} #{e.backtrace}\n")
        end
      end

      output_filename
    end

    media_thread_pool.shutdown
    media_thread_pool.wait_for_termination

    unless preview
      outdated_temp_files = (Dir.glob("#{output_dir}#{File::SEPARATOR}0*.mp4").to_set - temp_videos.to_set).to_a
      print("#{outdated_temp_files.length} outdated_temp_files: #{outdated_temp_files}\n")
      if @options[:cleanup]
        print("removing them\n")
        FileUtils.rm_f outdated_temp_files
      else
        print("skipping removal\n")
      end
    end

    temp_videos
  end

  def concat_videos(temp_videos, output_filename)
    print("concatenating output\n")

    parts = temp_videos.map { |f| "file 'file:#{f}'" }
                       .join "\n"

    command = FFMPEG + [
      # '-async', '1', # NOTE: does nothing for ffmpeg 4.4.4?
      '-fflags', '+genpts+igndts',
      '-f', 'concat',
      '-segment_time_metadata', '1',
      '-safe', '0',
      '-protocol_whitelist', 'file,pipe,fd',
      '-i', '-',
      # '-af', 'aselect=concatdec_select,aresample=async=1', # FIXME: adds sound gaps resulting in clicking sounds
      # '-vcodec', 'copy',
      # '-acodec', 'flac',
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

  def prepare_mpv_command(command)
    send_to_mpv = "\\| socat - #{@mpv_socket} >> /dev/null<Enter><Enter>"
    json = { "command": command }.to_json
    ":!echo '#{json}'#{send_to_mpv}"
  end

  def compute_player_position(line_in_config)
    @segments.filter { |seg| seg[:line_in_config] < line_in_config }
             .map { |seg| seg[:end_position] - seg[:start_position] }
             .sum / clamp_speed(@options[:speed])
  end

  def compute_line_in_config(player_position)
    player_position_spedup = player_position * clamp_speed(@options[:speed])
    position = 0.0
    for seg in @segments
      dt = seg[:end_position] - seg[:start_position]
      return seg[:line_in_config] if player_position_spedup >= position && player_position_spedup <= position + dt

      position += dt
    end

    @segments.last[:line_in_config]
  end

  def update_mpv_playback(mpv, nvim, rewritten_config)
    nvim_context = nvim.current
    window = nvim_context.window
    buffer = nvim_context.buffer

    player_position = mpv.get_property('time-pos')
    return if player_position.nil?

    new_nvim_cursor_position = [compute_line_in_config(player_position), 0]

    unless get_current_window_id == @terminal_window_id
      is_playing = !mpv.get_property('pause')
      nvim.command("let g:allow_playback = v:#{is_playing}")
      window.cursor = new_nvim_cursor_position
      return
    end

    # TODO: do all mpv commands from Neovim/vimscript (since some of them should be done from Neovim/vimscript unavoidably)?
    allow_playback = nvim.eval('mode() == "n" && !&modified && empty(getbufinfo({"bufmodified": 1})) != 0 && g:allow_playback') == 1
    if allow_playback
      if !rewritten_config && buffer.get_name == @config_filename
        if mpv.get_property('pause')
          mpv.command('seek', compute_player_position(buffer.line_number), 'absolute')
        else
          window.cursor = new_nvim_cursor_position
        end
        mpv.set_property('pause', false)
      end
    else
      mpv.set_property('pause', true)
    end
  end
end

def parse_config(filename, options)
  File.open filename do |f|
    f.map
     .with_index { |line, index| [line, index + 1] }
     .reject { |line, _line_in_config| line.start_with?('#') || line.strip.empty? }
     .map { |line, line_in_config| [line.split("\t"), line_in_config] }
     .map do |cols, line_in_config|
       if cols[0] == "\n" then { line_in_config: line_in_config, empty: true }
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

         raise 'parse failure' if end_position.to_f == 0.0

         {
           line_in_config: line_in_config,
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

def optimize_for_youtube(output_filename, options, temp_dir)
  output_basename_no_ext = "#{File.basename(output_filename,
                                            File.extname(output_filename))}.CFR_#{options[:fps]}FPS.youtube"
  temp_youtube_flac_h264_filename = File.join(temp_dir, "#{output_basename_no_ext}.flac.h264.mp4")
  temp_youtube_opus_filename = File.join(temp_dir, "#{output_basename_no_ext}.opus")
  temp_youtube_wav_filename = File.join(temp_dir, "#{output_basename_no_ext}.wav")
  output_youtube_filename = File.join(options[:project_dir], "#{output_basename_no_ext}.mp4")

  print("reencoding for YouTube\n")
  command =
    FFMPEG + [
      '-threads', Concurrent.processor_count,
      '-fflags', '+genpts+igndts',
      '-i', output_filename,
      '-vsync', 'cfr',
      '-af', 'aresample=async=1,asetpts=PTS-STARTPTS',
      '-vcodec', h264_video_codec,
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

  print("producing YouTube output\n")
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

  verify_constant_framerate(output_youtube_filename, options)
  output_youtube_filename
end

def optimize_for_ios(output_filename, options)
  output_basename_no_ext = "#{File.basename(output_filename,
                                            File.extname(output_filename))}.CFR_#{options[:fps].to_f.pretty_fps}FPS.iOS"
  output_ios_filename = File.join(options[:project_dir], "#{output_basename_no_ext}.mov")

  # TODO: also render mov files to output/ ?

  print("reencoding for iOS video editors\n")
  command =
    FFMPEG + [
      '-threads', Concurrent.processor_count,
      '-fflags', '+genpts+igndts',
      '-i', output_filename,
      '-vsync', 'cfr',
      '-af', 'aresample=async=1,asetpts=PTS-STARTPTS',
      '-vcodec', h264_video_codec,
      '-acodec', 'alac',
      '-pix_fmt', 'yuv420p',
      '-movflags', 'faststart',
      '-strict', '-2',
      output_ios_filename
    ]
  system command.shelljoin_wrapped

  verify_constant_framerate(output_ios_filename, options)
  output_ios_filename
end

# TODO: DaVinci Resolve: ffmpeg -i input.mp4 -c:v dnxhd -profile:v dnxhr_hq -pix_fmt yuv422p -c:a pcm_s16le -f mov out.mov

def in_segment?(position, segment)
  (segment[:start_position]..segment[:end_position]).cover? position
end

def segments_overlap?(a, b)
  in_segment?(a[:start_position], b) || in_segment?(a[:end_position], b)
end

def remove_file_if_empty(filename)
  return unless File.exist?(filename) && File.size(filename) == 0

  File.delete(filename)
end

def verify_constant_framerate(filename, _options)
  framerate = get_framerate(filename)
  raise "Unexpected framerate mode #{framerate[:mode]} for #{filename}" unless framerate[:mode] == 'CFR'
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
    { line_in_config: 0, video_filename: 'a.mp4', start_position: 0.0, end_position: 5.0, speed: 1.0 },
    { line_in_config: 1, video_filename: 'a.mp4', start_position: 5.5, end_position: 10.0, speed: 1.5 },
    { line_in_config: 2, video_filename: 'b.mp4', start_position: 1.0, end_position: 3.0, speed: 1.0 },
    { line_in_config: 3, video_filename: 'b.mp4', start_position: 10.0, end_position: 20.0, speed: 1.0 },
    { line_in_config: 3, video_filename: 'b.mp4', start_position: 19.0, end_position: 22.0, speed: 1.8 },
    { line_in_config: 4, video_filename: 'b.mp4', start_position: 6.0, end_position: 8.0, speed: 1.0 },
    { line_in_config: 4, video_filename: 'b.mp4', start_position: 3.0, end_position: 7.0, speed: 1.0 }
  ]

  expected = [
    { line_in_config: 0, video_filename: 'a.mp4', start_position: 0.0, end_position: 10.0, speed: 1.5 },
    { line_in_config: 2, video_filename: 'b.mp4', start_position: 1.0, end_position: 3.0, speed: 1.0 },
    { line_in_config: 3, video_filename: 'b.mp4', start_position: 3.0, end_position: 22.0, speed: 1.8 }
  ]

  result = merge_small_pauses(segments, min_pause_between_shots)
  raise unless result == expected
end

def generate_config(options)
  banlist = File.readlines('banlist.txt', chomp: true).map { |i| Regexp.new(i) }
  app_version = `git rev-parse HEAD`[..6]
  render_conf_filename = File.join(options[:project_dir], CONFIG_FILENAME)
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
      write_columns(render_conf_file, ["#(vlog-toolset-#{app_version})filename", 'speed', 'start', 'end', 'text'])
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
        text = transcription['text'].strip
        filename_prefix = banlist.any? { |i| i.match?(text) } ? '#' : '' # FIXME
        line = [
          filename_prefix + File.basename(i),
          RENDER_DEFAULT_SPEED,
          ms_to_sec(offsets['from']),
          ms_to_sec(offsets['to']),
          text
        ]
        write_columns(render_conf_file, line)
      end

      FileUtils.rm_f transcribed_json
    end
  end

  exists
end

def write_columns(file, columns)
  file.write(columns.join("\t") + "\n")
end

def ms_to_sec(ms)
  ms.to_f / 1000.0
end

def checksum(filename)
  Digest::CRC32.file(filename).hexdigest
end

def output_postfix(options)
  options[:preview] ? '_preview' : ''
end

def dirs(options)
  output_dir = File.join(options[:project_dir], 'output')
  temp_dir = File.join(options[:project_dir], 'tmp')
  [output_dir, temp_dir]
end

def parse_options!(options, args)
  parser = OptionParser.new do |opts|
    opts.set_banner('Usage: vlog-render -p project_dir/ -w path/to/whisper.cpp/ [other options]')
    opts.set_summary_indent('  ')
    opts.on('-p', '--project <dir>', 'Project directory') { |p| options[:project_dir] = p }
    opts.on('-P', '--preview <true|false>',
            "Preview mode. It will also start a video player by a given position (default: #{options[:preview]})") do |p|
      options[:preview] = p == 'true'
    end
    opts.on('-n', '--tmux-nvim <true|false>',
            "Plain text video editing: (during preview mode or when #{CONFIG_FILENAME} was just generated) open #{CONFIG_FILENAME} in Neovim via Tmux if they are available (default: #{options[:tmux_nvim]})") do |i|
      options[:tmux_nvim] = i == 'true'
    end
    opts.on('-f', '--fps <num>', "Constant frame rate (default: #{options[:fps]})") { |f| options[:fps] = f }
    opts.on('-S', '--speed <num>', "Speed factor (default: #{options[:speed]})") { |s| options[:speed] = s.to_f }
    opts.on('-b', '--desired-brightness <num>',
            "Correct brightness (supported values range [0, 1], -1.0 means disabled, default: #{options[:desired_brightness]})") do |s|
      options[:desired_brightness] = s.to_f
    end
    opts.on('-V', '--video-filters <filters>', "ffmpeg video filters (default: \"#{options[:video_filters]}\")") do |v|
      options[:video_filters] = v
    end
    opts.on('-C', '--force-colorspace <true|false>',
            "Apply adequate recent colorspace (default: #{options[:force_colorspace]})") do |c|
      options[:force_colorspace] = c == 'true'
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
            "Additionally optimize for YouTube (default: #{options[:youtube]})") do |y|
      options[:youtube] = y == 'true'
    end
    opts.on('-I', '--ios <true|false>',
            "Additionally optimize for iOS video editors (default: #{options[:ios]})") do |i|
      options[:ios] = i == 'true'
    end
  end

  parser.parse!(args)

  return unless options[:project_dir].nil?

  print(parser.help)
  exit 1
end

def get_current_window_id
  `xdotool getactivewindow`
end

def switch_to_window(window_id)
  command = ['xdotool', 'windowfocus', window_id]
  system command.shelljoin_wrapped
end

def verify_terminal(window_id)
  command = "xdotool getwindowname #{window_id}"
  window_name = `#{command}`.strip
  # print("window_name='#{window_name}'")
  return if window_name == command || window_name == 'wezterm'

  raise "please run #{$PROGRAM_NAME} when its terminal window focused"
end

def main(argv)
  test_merge_small_pauses
  test_segments_overlap

  options = {
    fps: '30',
    speed: 1.2,
    desired_brightness: -1.0,
    video_filters: 'hqdn3d,hflip,vignette',
    force_colorspace: true,
    preview: true,
    line_in_config: 1,
    tmux_nvim: true,
    cleanup: false,
    whisper_cpp_args: '--model models/ggml-base.bin --language auto',
    youtube: false,
    ios: false
  }

  # TODO: option to render all sound channels?

  parse_options!(options, argv)

  terminal_window_id = nil
  if options[:preview]
    raise 'unsupported window system' unless ENV.include?('DISPLAY')

    terminal_window_id = get_current_window_id
    verify_terminal(terminal_window_id)
  end

  project_dir = options[:project_dir]
  config_filename = File.join(File.realpath(project_dir), CONFIG_FILENAME)

  old_config = generate_config(options)

  tmux_is_active = !ENV['TMUX'].nil?
  nvim_socket = File.join(project_dir, 'nvim.sock')

  tmux_pane_id = nil
  nvim = nil
  config_in_nvim = (!old_config || options[:preview]) && options[:tmux_nvim] && tmux_is_active && File.file?('/usr/bin/nvim')
  if config_in_nvim
    if File.socket?(nvim_socket)
      nvim = Neovim.attach_unix(nvim_socket)
      tmux_pane_id = nvim.eval('g:tmux_pane_id').strip

      command = ['tmux', 'select-pane', '-t', tmux_pane_id]
      print('switch pane: ' + command.shelljoin_wrapped + "\n")
      system(command.shelljoin_wrapped)
    else
      command = ['tmux', 'split-window', '-b', '-l', '30', '-v', "nvim --listen #{nvim_socket} #{config_filename}"]
      system(command.shelljoin_wrapped)

      sleep 0.2
      tmux_pane_id = `tmux display-message -p '\#{pane_id}'`.strip
      nvim = Neovim.attach_unix(nvim_socket)
      nvim.command("let g:tmux_pane_id = '#{tmux_pane_id}'")
    end

    print("tmux_pane_id=#{tmux_pane_id}\n")
  end

  unless old_config
    print("Configuration file is ready! 🎉\n")
    print("Now edit #{config_filename} and restart this script to finish\n")
    exit 0
  end

  Dir.chdir project_dir

  output_dir, temp_dir = dirs(options)
  FileUtils.mkdir_p [output_dir, temp_dir]

  preview = Renderer.new(config_filename, config_in_nvim, nvim_socket, options, terminal_window_id)
  output_filename = preview.render

  if options[:preview]
    preview.run_preview_loop(nvim)
  else
    output_youtube_filename = optimize_for_youtube(output_filename, options, temp_dir) if options[:youtube]
    output_ios_filename = optimize_for_ios(output_filename, options) if options[:ios]

    framerate = get_framerate(output_filename)
    new_output_filename = "output#{output_postfix(options)}.#{framerate[:mode]}_#{framerate[:fps].to_f.pretty_fps}FPS.mp4"
    File.rename(output_filename, new_output_filename)
    output_filename = new_output_filename

    print("finished rendering final video 🎉\n\n")

    print("you can run:\n\n")
    command = MPV_COMMAND + [output_filename]
    print(command.shelljoin_wrapped + "\n\n")

    if options[:youtube]
      command = MPV_COMMAND + [output_youtube_filename]
      print(command.shelljoin_wrapped + "\n\n")
    end

    if options[:ios]
      command = MPV_COMMAND + [output_ios_filename]
      print(command.shelljoin_wrapped + "\n\n")
    end
  end

  # TODO: add --gc flag to remove no longer needed tmp/output files
  # TODO: remove old/unknown "output/*.mp4" files
end

main(ARGV)
