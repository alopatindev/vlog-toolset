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

# TODO: `mpv -v av://v4l2:/dev/video0` says "[ffmpeg/demuxer] video4linux2,v4l2: The V4L2 driver changed the video from 1920x1080 to 640x480"
# possible solution "driver=v4l2:width=720:height=576:norm=PAL:outfmt=uyvy"

# TODO: rename
class DevicesController
  MIN_SILENCE_SIZE = 10.0

  WAIT_AFTER_REC_STARTED = 5.0
  WAIT_AFTER_REC_STOPPED = 2.0

  WAIT_SILENCE_REC = 20.0
  SILENCE_PADDING = 2.0

  def show_help
    clear
    puts "Project: #{@project_dir}"
    puts
    puts '----------------------------------------------------------------------'
    puts '        R - (RE)START clip recording (loses unsaved clip)'
    puts '        S - STOP and SAVE current clip'
    puts "Shift + S - STOP and SAVE current clip, DON'T use auto silence removal"
    puts '        D - STOP and DELETE current clip'
    puts '        P - PLAY last saved clip'
    puts '        F - FOCUS camera on center'
    puts '----------------------------------------------------------------------'
    puts 'Shift + R - (RE)START SILENCE recording attempt'
    puts '----------------------------------------------------------------------'
    puts '        H - show HELP'
    puts '        Q - QUIT'
    puts
  end

  def run_main_loop
    loop do
      show_status nil

      case STDIN.getch
      when 'q'
        show_status 'Quit? y/n'
        break if STDIN.getch == 'y'
      when 'R'
        stop_recording
        show_status nil
        start_silence_recording
      when 'r'
        if silence_recorded?
          stop_recording
          show_status nil
          delete_unsaved_clip
          start_recording
        else
          show_status 'You need to record SILENCE first, press "Shift + R"'
          sleep 3.0
        end
      when 's'
        stop_recording
        save_clip true
      when 'S'
        stop_recording
        save_clip false
      when 'd'
        stop_recording
        delete_clip
      when 'p'
        play
      when 'f'
        focus
      when 'h'
        show_help
      end
    end
  end

  def initialize(options, temp_dir, logger)
    @project_dir = options[:project_dir]
    @temp_dir = temp_dir
    @trim_duration = options[:trim_duration]
    @min_pause_between_shots = options[:min_pause_between_shots]
    @aggressiveness = options[:aggressiveness]
    @mpv_args = options[:mpv_args]
    @logger = logger

    @clip_num = get_last_clip_num || 0
    @logger.debug "clip_num is #{@clip_num}"

    @status_mutex = Mutex.new
    @media_thread_pool = Concurrent::FixedThreadPool.new(Concurrent.processor_count)
    @saving_clips = Set.new
    @wait_for_rec_startup_or_finalization = 0
    @recording = false

    arecord_args = options[:arecord_args]
    @mic = Mic.new(temp_dir, arecord_args, logger)

    @phone = Phone.new(temp_dir, options, logger)
    @phone.set_brightness(0)

    logger.info('initialized')

    print("\r")
    STDOUT.flush
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

  def get_last_silence_clip
    get_clips([@project_dir]).filter { |i| i.include?('_silence.wav') }.first
  end

  def silence_recorded?
    !get_last_silence_clip.nil?
  end

  def parse_clip_num(filename)
    filename
      .gsub(/.*#{File::SEPARATOR}0*/, '')
      .gsub(/_.*\..*$/, '')
      .to_i
  end

  def start_recording
    return if @status_mutex.synchronize { @recording }

    if @phone.connected? && @mic.connected?
      raise 'Unexpected state: Open Camera is not the active window' unless @phone.opencamera_running?

      @phone.run_opencamera
      @mic.force_invalidate_connection
      show_status nil

      @logger.debug 'start recording'
      toggle_recording
    else
      @mic.force_invalidate_connection
      show_status nil
    end
  end

  def start_silence_recording
    clip_num = @clip_num
    @logger.info "start_silence_recording #{clip_num}"
    return if @status_mutex.synchronize { @recording } || !@mic.connected?

    @mic.force_invalidate_connection
    @mic.toggle_recording clip_num
    @status_mutex.synchronize { @recording = true }
    wait_rec(WAIT_SILENCE_REC)

    @mic.toggle_recording clip_num
    sound_filename = @mic.filename(clip_num)

    @status_mutex.synchronize do
      @recording = false
      @saving_clips.add(clip_num)
      @logger.debug "saving_clips.length=#{@saving_clips.length}"
    end
    show_status nil

    sound_duration = get_duration(sound_filename)
    if sound_duration < WAIT_SILENCE_REC
      message = "unexpected duration #{sound_duration}"
      raise message
    end

    first_filename = File.join(@temp_dir, 'silence_a.wav')
    command = FFMPEG + [
      '-i', sound_filename,
      '-ss', SILENCE_PADDING,
      '-t', MIN_SILENCE_SIZE,
      '-c', 'copy',
      first_filename
    ]
    @logger.debug command
    system(command.shelljoin_wrapped)

    second_filename = File.join(@temp_dir, 'silence_b.wav')

    command = FFMPEG + [
      '-i', sound_filename,
      '-ss', sound_duration - SILENCE_PADDING - MIN_SILENCE_SIZE,
      '-t', MIN_SILENCE_SIZE,
      '-c', 'copy',
      second_filename
    ]
    @logger.debug command
    system(command.shelljoin_wrapped)

    status_message = nil
    files = [first_filename, second_filename]

    volume_adjustments = files.map { |i| get_volume_adjustment(i) }.filter { |i| !i.nil? && i > 10.0 }
    @logger.debug "volume_adjustments=#{volume_adjustments}, larger means sound is quieter"
    if volume_adjustments.empty?
      status_message = 'Failed to record silence! Too noisy environment? Mic failure?'.red
    else
      quietest_index = volume_adjustments.argmax
      @logger.debug "quieter file index #{quietest_index}"
      quietest_filename = files[quietest_index]
      output_silence_filename = File.join(@project_dir, "#{clip_num.with_leading_zeros}_silence.wav")
      remove_files([output_silence_filename])
      File.rename(quietest_filename, output_silence_filename)
      @logger.info "save_silence_clip: #{clip_num} as #{output_silence_filename} ok"
    end

    remove_files(files)

    @status_mutex.synchronize do
      @saving_clips.delete(clip_num)
    end
    show_status(status_message)
    sleep 3.0 unless status_message.nil?
  end

  def stop_recording
    return unless @status_mutex.synchronize { @recording }

    @logger.debug 'stop recording'
    toggle_recording
  end

  def toggle_recording
    recording = @status_mutex.synchronize do
      @recording = !@recording
      @recording
    end

    if recording
      @clip_num += 1
    else
      wait_rec(WAIT_AFTER_REC_STOPPED)
    end

    @logger.debug "toggle_recording to #{@recording} clip_num=#{@clip_num}"

    @mic.toggle_recording @clip_num
    @phone.toggle_recording @clip_num, recording

    return unless recording

    wait_rec(WAIT_AFTER_REC_STARTED)
  end

  def focus
    @logger.debug 'focus'
    @phone.focus
  end

  def delete_unsaved_clip
    if saving_current_clip?
      false
    else
      ok = @mic.delete_clip @clip_num
      @phone.delete_clip @clip_num
      ok
    end
  end

  def delete_clip
    @logger.debug 'delete_clip'
    if saving_current_clip?
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
    sound_filename = @mic.filename(clip_num)
    rotation = @phone.rotation

    if saving_current_clip? || phone_filename.nil? || sound_filename.nil?
      @logger.debug "save_clip: skipping #{clip_num}"
    else
      @logger.info "save_clip #{clip_num}"
      @status_mutex.synchronize do
        @saving_clips.add(clip_num)
        @logger.debug "saving_clips.length=#{@saving_clips.length}"
      end
      show_status nil

      @media_thread_pool.post do
        camera_filename = @phone.move_to_host(phone_filename, clip_num)
        @logger.debug "save_clip: camera_filename=#{camera_filename} sound_filename=#{sound_filename}"

        status_message = nil
        # TODO: wav
        # if get_volume_adjustment(camera_filename).nil?
        #  status_message = 'Failed to record sound using PHONE. Mic failure?'.red
        # end
        status_message = 'Failed to record sound. Mic failure?'.red if get_volume_adjustment(sound_filename).nil?
        if status_message.nil?
          show_status(status_message)
          sleep 3.0
        end

        sync_offset, sync_sound_filename = synchronize_sound(camera_filename, sound_filename)
        @logger.debug "save_clip: sync_offset=#{sync_offset}"

        segments = detect_segments(sync_sound_filename, camera_filename, sync_offset, trim_noise)
        processed_sound_filenames = process_sound(sync_sound_filename, segments)
        @logger.debug "save_clip: processed_sound_filenames=#{processed_sound_filenames}"

        processed_video_filenames = process_video(camera_filename, segments)
        output_filenames = merge_files(processed_sound_filenames, processed_video_filenames, clip_num, rotation,
                                       @project_dir)
        remove_files [camera_filename, sound_filename,
                      sync_sound_filename] + processed_sound_filenames + processed_video_filenames
        @logger.info "save_clip: #{clip_num} as #{output_filenames} ok"

        @status_mutex.synchronize do
          @saving_clips.delete(clip_num)
        end
        show_status nil
      rescue StandardError => e
        @logger.info "ignoring saving of #{clip_num} as #{output_filename}"
        @logger.debug e
      ensure
        @logger.debug 'media task has finished'
      end
    end
  end

  def saving_current_clip?
    clip_num = @clip_num
    @status_mutex.synchronize do
      @saving_clips.include?(clip_num)
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
      voice_segments = detect_voice(sync_sound_filename, MIN_SHOT_SIZE, @min_pause_between_shots, @aggressiveness)
      @logger.debug "voice segments: #{voice_segments.join(',')} (aggressiveness=#{@aggressiveness})"

      unless voice_segments.empty?
        segments = voice_segments

        segments[0][0] = [start_position, segments[0][0]].max
        last = segments.length - 1
        segments[last][1] = [end_position, segments[last][1]].min

        segments = segments.filter { |r| r[0] < r[1] }
      end
    end

    segments = [[start_position, end_position]] if segments.empty?

    @logger.debug "detect_segments: #{segments.join(',')}"
    segments
  end

  def synchronize_sound(camera_filename, sound_filename)
    output_filename = "#{sound_filename}.sync.wav"

    command = ['sync-audio-tracks.sh', sound_filename, camera_filename, output_filename]
    sync_offset = `#{command.shelljoin_wrapped}`
                  .split("\n")
                  .filter { |line| line.start_with? 'offset is' }
                  .map { |line| line.sub(/^offset is /, '').sub(/ seconds$/, '').to_f }
                  .first || 0.0

    [sync_offset, output_filename]
  end

  def close
    if @status_mutex.synchronize { @recording }
      stop_recording
      save_clip true
    end

    @phone.restore_display_settings
    @phone.close_opencamera

    @media_thread_pool.shutdown
    @media_thread_pool.wait_for_termination
  end

  def show_status(text)
    @status_mutex.synchronize do
      size = 80
      if text.nil?
        recording =
          if @wait_for_rec_startup_or_finalization > 0
            'WAIT'.red + "(#{@wait_for_rec_startup_or_finalization.to_i}) ⌛❗"
          elsif @recording
            '🔴 '
          else
            '⬜ '
          end
        media_processing = @saving_clips.empty? ? '' : "| 🔁 (#{@saving_clips.length}) "

        phone_status, free_phone_storage =
          if @phone.connected?
            phone_battery_level, phone_battery_temperature, free_phone_storage = @phone.get_system_info
            [" | #{phone_battery_level} / #{phone_battery_temperature} | 💾 #{free_phone_storage}",
             free_phone_storage.to_f]
          else
            ['❌', nil]
          end

        mic_status = @mic.connected? ? '' : ' | 🎙️❌'
        free_storage = parse_free_storage(`LANG=C df -Pk #{@project_dir}`, free_phone_storage)
        text = "[ #{recording}#{media_processing}] [ 💻 | 💾 #{free_storage}#{mic_status} ] [ 📞#{phone_status} ]"
      end

      spaces = size - text.length
      if spaces < 0
        @logger.error "unexpected spaces=#{spaces}"
        spaces = 1
      end

      postfix = ' ' * spaces
      print("#{text}#{postfix}\r")
      STDOUT.flush
    end
  end

  def play
    # TODO: don't play silence wav?

    clips = get_clips [@project_dir]
    return if clips.empty?

    last_clip_num = parse_clip_num clips.last
    @logger.debug "play clip: #{last_clip_num}"

    last_clip_filename = File.basename(get_output_filename(last_clip_num, subclip_num = 0, rotation = nil,
                                                           project_dir = @project_dir))
    rotation = last_clip_filename.split('_')[2].split('.')[0].to_i
    restored_rotation = (rotation - 90) % 360

    position_in_playlist = clips
                           .map { |f| File.basename(f) }
                           .index(last_clip_filename) || clips.length - 1

    mpv_args = @mpv_args.shellsplit + ["--video-rotate=#{restored_rotation}",
                                       "--playlist-start=#{position_in_playlist}"] + clips

    command = MPV + mpv_args
    @logger.debug command
    system command.shelljoin_wrapped
  end

  def wait_rec(pause)
    @status_mutex.synchronize do
      @wait_for_rec_startup_or_finalization = pause
    end

    loop do
      break if @status_mutex.synchronize { @wait_for_rec_startup_or_finalization } <= 0

      show_status nil
      sleep 1.0
      @status_mutex.synchronize do
        @wait_for_rec_startup_or_finalization -= 1
      end
    end
    show_status nil
  end
end

def remove_files(filenames)
  @logger.debug "removing #{filenames}"
  FileUtils.rm_f filenames
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

  print(parser.help)
  exit 1
end

def show_cursor
  print("\e[?25h")
end

def hide_cursor
  print("\e[?25l")
end

def clear
  print("\e[2J\e[f")
end

def main(argv)
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
  parse_options!(options, argv)

  begin
    hide_cursor
    print("Initializing...\n")

    project_dir = options[:project_dir]
    temp_dir = File.join project_dir, 'tmp'
    FileUtils.mkdir_p(temp_dir)

    logger = Logger.new File.join(project_dir, 'log.txt')
    logger.level = Logger::WARN unless options[:debug]

    logger.debug options

    devices = DevicesController.new(options, temp_dir, logger)
    devices.show_help
    devices.run_main_loop
  rescue SystemExit, Interrupt
  rescue StandardError => e
    logger.fatal(e) unless logger.nil?
    puts e
  ensure
    puts 'Exiting...'
    logger.info('exit') unless logger.nil?

    devices.close unless devices.nil?
    logger.close unless logger.nil?

    STDOUT.flush
    show_cursor
  end
end

main(ARGV)
