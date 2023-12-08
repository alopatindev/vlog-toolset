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
require 'microphone'
require 'numeric'
require 'os_utils'
require 'phone'
require 'shellwords_utils'
require 'voice/detect_voice'

require 'concurrent'
require 'fileutils'
require 'io/console'
require 'logger'
require 'optparse'

# TODO: `mpv -v av://v4l2:/dev/video0` says "[ffmpeg/demuxer] video4linux2,v4l2: The V4L2 driver changed the video from 1920x1080 to 640x480"
# possible solution "driver=v4l2:width=720:height=576:norm=PAL:outfmt=uyvy"

class DevicesFacade
  MIN_SHOT_SIZE = 1.0

  def initialize(options, temp_dir, logger)
    @project_dir = options[:project_dir]
    @temp_dir = temp_dir
    @trim_duration = options[:trim_duration]
    @min_pause_between_shots = options[:min_pause_between_shots]
    @aggressiveness = options[:aggressiveness]
    @mpv_args = options[:mpv_args]
    @logger = logger

    @recording = false
    @clip_num = get_last_clip_num || 0
    @logger.debug "clip_num is #{@clip_num}"

    arecord_args = options[:arecord_args]
    @microphone = Microphone.new(temp_dir, arecord_args, logger)

    @phone = Phone.new(temp_dir, options, logger)
    @phone.set_brightness(0)

    @thread_pool = Concurrent::FixedThreadPool.new(Concurrent.processor_count)
    @saving_clips = Set.new

    logger.info('initialized')
  end

  def get_clips(dirs)
    dirs_joined = dirs.join ','
    Dir.glob("{#{dirs_joined}}#{File::SEPARATOR}0*.{wav,mp4,mkv,m4a,webm}")
       .sort
  end

  def get_last_clip_num
    dirs = [@temp_dir, @project_dir]
    get_clips(dirs)
      .map { |f| parse_clip_num f }
      .max
  end

  def parse_clip_num(filename)
    filename
      .gsub(/.*#{File::SEPARATOR}0*/, '')
      .gsub(/_.*\..*$/, '')
      .to_i
  end

  def start_recording
    return if @recording

    @logger.debug 'start recording'
    toggle_recording
  end

  def stop_recording
    return unless @recording

    @logger.debug 'stop recording'
    toggle_recording
  end

  def toggle_recording
    @recording = !@recording
    @clip_num += 1 if @recording

    @logger.debug "toggle_recording to #{@recording} clip_num=#{@clip_num}"

    @microphone.toggle_recording @clip_num
    @phone.toggle_recording @clip_num, @recording
  end

  def focus
    @logger.debug 'focus'
    @phone.focus
  end

  def delete_unsaved_clip
    if @saving_clips.include? @clip_num
      false
    else
      ok = @microphone.delete_clip @clip_num
      @phone.delete_clip @clip_num
      ok
    end
  end

  def delete_clip
    @logger.debug 'delete_clip'
    if @saving_clips.include? @clip_num
      delete_last_subclip
    else
      ok = delete_unsaved_clip
      delete_last_subclip unless ok
    end
  end

  def delete_last_subclip
    @logger.debug 'delete_last_subclip'
    filename = get_clips([@project_dir]).last
    return unless !filename.nil? && (File.file? filename)

    show_status "Delete #{filename}? y/n"
    remove_files filename if STDIN.getch == 'y'
  end

  def save_clip(trim_noise)
    @logger.debug "save_clip: trim_noise = #{trim_noise}"
    clip_num = @clip_num
    phone_filename = @phone.filename(clip_num)
    sound_filename = @microphone.filename(clip_num)
    rotation = @phone.rotation

    if @saving_clips.include?(clip_num) || phone_filename.nil? || sound_filename.nil?
      @logger.debug "save_clip: skipping #{clip_num}"
    else
      @logger.info "save_clip #{clip_num}"
      @saving_clips.add(clip_num)

      @thread_pool.post do
        camera_filename = @phone.move_to_host(phone_filename, clip_num)
        @logger.debug "save_clip: camera_filename=#{camera_filename} sound_filename=#{sound_filename}"

        sync_offset, sync_sound_filename = synchronize_sound(camera_filename, sound_filename)
        @logger.debug "save_clip: sync_offset=#{sync_offset}"

        segments = detect_segments(sync_sound_filename, camera_filename, sync_offset, trim_noise)
        processed_sound_filenames = process_sound(sync_sound_filename, segments)
        @logger.debug "save_clip: processed_sound_filenames=#{processed_sound_filenames}"

        processed_video_filenames = process_video(camera_filename, segments)
        output_filenames = merge_files(processed_sound_filenames, processed_video_filenames, clip_num, rotation)
        remove_files [camera_filename, sound_filename,
                      sync_sound_filename] + processed_sound_filenames + processed_video_filenames
        @logger.info "save_clip: #{clip_num} as #{output_filenames} ok"
      rescue StandardError => e
        @logger.info "ignoring saving of #{clip_num} as #{output_filename}"
        @logger.debug e
      end
    end
  end

  def merge_files(processed_sound_filenames, processed_video_filenames, clip_num, rotation)
    processed_sound_filenames
      .zip(processed_video_filenames)
      .each_with_index
      .map do |f, subclip_num|
      @logger.debug "save_clip: merging files #{f} #{subclip_num}"

      processed_sound_filename, processed_video_filename = f
      output_filename = get_output_filename clip_num, subclip_num, rotation
      @logger.debug "save_clip: output_filename=#{output_filename}"
      command = FFMPEG + ['-i', processed_sound_filename, '-an', '-i', processed_video_filename, '-shortest',
                          '-strict', '-2', '-codec', 'copy', '-movflags', 'faststart', output_filename]
      @logger.debug command
      system command.shelljoin_wrapped

      output_filename
    end
  end

  def detect_segments(sync_sound_filename, camera_filename, sync_offset, trim_noise)
    sync_sound_duration = get_duration(sync_sound_filename)
    duration = [get_duration(camera_filename), sync_sound_duration].min

    start_position = [@trim_duration, sync_offset.abs].max
    end_position = duration - @trim_duration

    segments = []

    max_output_duration = end_position - start_position
    if max_output_duration < MIN_SHOT_SIZE
      @logger.info "skipping #{sync_sound_filename}, too short clip, duration=#{duration}, max_output_duration=#{max_output_duration}"
      return segments
    end

    if trim_noise
      voice_segments = detect_voice sync_sound_filename, MIN_SHOT_SIZE, @min_pause_between_shots, @aggressiveness
      @logger.debug "voice segments: #{voice_segments.join(',')} (aggressiveness=#{@aggressiveness})"

      unless voice_segments.empty?
        segments = voice_segments

        segments[0][0] = [start_position, segments[0][0]].max
        last = segments.length - 1
        segments[last][1] = [end_position, segments[last][1]].min

        segments = segments.select { |r| r[0] < r[1] }
      end
    end

    segments = [[start_position, end_position]] if segments.empty?

    @logger.debug "detect_segments: #{segments.join(',')}"
    segments
  end

  def process_video(camera_filename, segments)
    segments.each_with_index.map do |seg, subclip_num|
      start_position, end_position = seg
      output_filename = "#{camera_filename}_#{subclip_num}.processed.mp4"
      temp_filename = "#{camera_filename}_#{subclip_num}.cut.mp4"

      command = FFMPEG + [
        '-ss', start_position,
        '-i', camera_filename,
        '-to', end_position - start_position,
        '-an',
        '-codec', 'copy',
        temp_filename
      ]
      system command.shelljoin_wrapped
      FileUtils.mv temp_filename, output_filename, force: true

      output_filename
    end
  end

  def get_output_filename(clip_num, subclip_num, rotation)
    prefix = File.join @project_dir, "#{clip_num.with_leading_zeros}_#{subclip_num.with_leading_zeros}"
    if rotation.nil?
      Dir[prefix + '*'].first
    else
      "#{prefix}_#{rotation}.mp4"
    end
  end

  def synchronize_sound(camera_filename, sound_filename)
    output_filename = "#{sound_filename}.sync.wav"

    command = ['sync-audio-tracks.sh', sound_filename, camera_filename, output_filename]
    sync_offset = `#{command.shelljoin_wrapped}`
                  .split("\n")
                  .select { |line| line.start_with? 'offset is' }
                  .map { |line| line.sub(/^offset is /, '').sub(/ seconds$/, '').to_f }
                  .first || 0.0

    [sync_offset, output_filename]
  end

  def process_sound(sync_sound_filename, segments)
    audio_filters = [EXTRACT_LEFT_CHANNEL_FILTER]

    segments.each_with_index.map do |seg, subclip_num|
      start_position, end_position = seg
      output_filename = "#{sync_sound_filename}_#{subclip_num}.flac"

      ffmpeg_cut_args = ['-ss', start_position, '-i', sync_sound_filename, '-to', end_position - start_position,
                         '-codec', 'copy']
      ffmpeg_output_args = ['-af', "#{audio_filters.join(',')}", '-acodec', 'flac']

      temp_filename = "#{sync_sound_filename}_#{subclip_num}.cut.wav"

      command = FFMPEG + ffmpeg_cut_args + [temp_filename]
      @logger.debug command
      system command.shelljoin_wrapped, out: File::NULL

      command = FFMPEG + ['-i', temp_filename] + ffmpeg_output_args + [output_filename]
      @logger.debug command
      system command.shelljoin_wrapped, out: File::NULL

      remove_files temp_filename

      raise "Failed to process #{output_filename}" unless File.file?(output_filename)

      output_filename
    end
  end

  def close
    if @recording
      stop_recording
      save_clip true
    end

    @phone.restore_brightness
    @phone.close_opencamera

    @thread_pool.shutdown
    @thread_pool.wait_for_termination
  end

  def show_status(text)
    size = 80
    if text.nil?
      recording = @recording ? '🔴' : '⬜'
      phone_battery_level, phone_battery_temperature, free_phone_storage = @phone.get_system_info
      free_storage = parse_free_storage(`LANG=C df -Pk #{@project_dir}`)
      text = "[ #{recording} | storage: #{free_storage} ] [ battery: #{phone_battery_level} / #{phone_battery_temperature} | storage: #{free_phone_storage} ]"
    end

    spaces = size - text.length
    raise if spaces < 0

    postfix = ' ' * spaces
    print "#{text}#{postfix}\r"
    STDOUT.flush
  end

  def play
    clips = get_clips [@project_dir]
    return if clips.empty?

    last_clip_num = parse_clip_num clips.last
    @logger.debug "play clip: #{last_clip_num}"

    last_clip_filename = File.basename(get_output_filename(last_clip_num, subclip_num = 0, rotation = nil))
    rotation = last_clip_filename.split('_')[2].split('.')[0].to_i
    restored_rotation = (rotation - 90) % 360

    position_in_playlist = clips
                           .map { |f| File.basename(f) }
                           .index(last_clip_filename) || clips.length - 1

    mpv_args = @mpv_args.shellsplit + ["--video-rotate=#{restored_rotation}", "--playlist-start=#{position_in_playlist}",
                                       clips.join(' ')]

    # TODO: add current rotation to filename and use it in render?

    command = MPV + mpv_args
    @logger.debug command
    system command.shelljoin_wrapped
  end
end

def remove_files(filenames)
  temp_files = filenames
  @logger.debug "removing #{filenames}"
  FileUtils.rm_f filenames
end

def show_help
  puts 'r - (RE)START recording'
  puts 's - STOP and SAVE current clip'
  puts "S - STOP and SAVE current clip, don't use auto trimming"
  puts 'd - STOP and DELETE current clip'
  puts 'p - PLAY last saved clip'
  puts 'f - FOCUS camera on center'
  puts 'h - show HELP'
  puts 'q / Ctrl+C - QUIT'
  puts
end

def run_main_loop(devices)
  loop do
    devices.show_status nil

    case STDIN.getch
    when 'q'
      devices.show_status 'Quit? y/n'
      break if STDIN.getch == 'y'
    when 'r'
      devices.stop_recording
      devices.show_status nil
      devices.delete_unsaved_clip
      devices.start_recording
    when 's'
      devices.stop_recording
      devices.save_clip true
    when 'S'
      devices.stop_recording
      devices.save_clip false
    when 'd'
      devices.stop_recording
      devices.delete_clip
    when 'p'
      devices.play
    when 'f'
      devices.focus
    when 'h'
      show_help
    end
  end
end

def parse_options!(options, args)
  parser = OptionParser.new do |opts|
    opts.set_banner('Usage: vlog-recorder -p project_dir/ [other options]')
    opts.set_summary_indent('  ')
    opts.on('-p', '--project <dir>', 'Project directory') { |p| options[:project_dir] = p }
    opts.on('-t', '--trim <duration>',
            "Trim duration of beginning and ending of each clip (default: #{'%.1f' % options[:trim_duration]})") do |t|
      options[:trim_duration] = t.to_f
    end
    opts.on('-s', '--sound-settings <arecord-args>',
            "Additional arecord arguments (default: \"#{options[:arecord_args]}\")") do |s|
      options[:arecord_args] += " #{s}"
    end
    opts.on('-A', '--android-device <device-id>', 'Android device id') { |a| options[:android_id] = a }
    opts.on('-o', '--opencamera-dir <dir>',
            "Open Camera directory path on Android device (default: \"#{options[:opencamera_dir]}\")") do |o|
      options[:opencamera_dir] = o
    end
    opts.on('-b', '--change-brightness <true|false>',
            "Set lowest brightness to save device power (default: #{options[:change_brightness]})") do |b|
      options[:change_brightness] = b == 'true'
    end
    opts.on('-m', '--mpv-args <mpv-args>', "Additional mpv arguments (default: \"#{options[:mpv_args]})\"") do |s|
      options[:mpv_args] += " #{s}"
    end
    opts.on('-P', '--pause-between-shots <seconds>',
            "Minimum pause between shots for auto trimming (default: #{'%.1f' % options[:min_pause_between_shots]})") do |p|
      options[:min_pause_between_shots] = p
    end
    opts.on('-a',
            '--aggressiveness <0..1>', "How aggressively to filter out non-speech (default: #{options[:aggressiveness]})") do |a|
      options[:aggressiveness] = a.to_f
    end
    opts.on('-d', '--debug <true|false>', "Show debug messages (default: #{options[:debug]})") do |d|
      options[:debug] = d == 'true'
    end
  end

  parser.parse!(args)

  return unless options[:project_dir].nil?

  print parser.help
  exit 1
end

options = {
  trim_duration: 0.15,
  arecord_args: '--device=default --format=dat',
  android_id: '',
  opencamera_dir: '/storage/emulated/0/DCIM/OpenCamera',
  change_brightness: false,
  mpv_args: '--vf=hflip --volume-max=300 --volume=130 --speed=1.2',
  min_pause_between_shots: 2.0,
  aggressiveness: 0.4,
  debug: false
}
parse_options!(options, ARGV)

begin
  project_dir = options[:project_dir]
  temp_dir = File.join project_dir, 'tmp'
  FileUtils.mkdir_p(temp_dir)

  logger = Logger.new File.join(project_dir, 'log.txt')
  logger.level = Logger::WARN unless options[:debug]

  logger.debug options

  devices = DevicesFacade.new options, temp_dir, logger
  show_help
  run_main_loop(devices)
rescue SystemExit, Interrupt
rescue StandardError => e
  logger.fatal(e) unless logger.nil?
  puts e
ensure
  puts 'Exiting...'
  logger.info('exit') unless logger.nil?

  devices.close unless devices.nil?
  logger.close unless logger.nil?
end
