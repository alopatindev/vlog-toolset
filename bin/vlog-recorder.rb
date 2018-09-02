#!/bin/env ruby

require 'phone.rb'
require 'microphone.rb'
require 'numeric.rb'

require 'concurrent'
require 'fileutils'
require 'io/console'
require 'logger'
require 'optparse'

class DevicesFacade
  FFMPEG = 'ffmpeg -y -hide_banner -loglevel error'.freeze
  MPV = 'mpv --no-terminal --fs'.freeze
  VADNET_CORRECTION = 1.5

  def initialize(options, temp_dir, logger)
    @project_dir = options[:project_dir]
    @temp_dir = temp_dir
    @trim_duration = options[:trim_duration]
    @min_pause_between_shots = options[:pause_between_shots]
    @use_camera = options[:use_camera]
    @fps = options[:fps]
    @speed = options[:speed]
    @video_filters = options[:video_filters]
    @video_compression = options[:video_compression]
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
    Dir.glob("{#{dirs_joined}}#{File::SEPARATOR}0*.{wav,mp4,mkv,flac}")
       .sort
  end

  def get_last_clip_num
    dirs = [@temp_dir, @project_dir]
    get_clips(dirs)
      .map { |f| f.gsub(/.*#{File::SEPARATOR}0*/, '').gsub(/\..*$/, '').to_i }
      .max
  end

  def start_recording
    unless @recording
      @logger.debug 'start recording'
      toggle_recording
    end
  end

  def stop_recording
    if @recording
      @logger.debug 'stop recording'
      toggle_recording
    end
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
      delete_last_clip_output
    else
      ok = delete_unsaved_clip
      delete_last_clip_output unless ok
    end
  end

  def delete_last_clip_output
    @logger.debug 'delete_last_clip_output'
    clip_num = get_last_clip_num
    unless clip_num.nil?
      output_filename = get_output_filename clip_num
      if File.file? output_filename
        show_status "Delete #{output_filename}? y/n"
        if STDIN.getch == 'y'
          @logger.info "delete_last_clip_output: removing #{output_filename}"
          FileUtils.rm_f output_filename
        end
      end
    end
  end

  def save_clip(trim_noise_and_bad_shots)
    @logger.debug "save_clip: trim_noise_and_bad_shots = #{trim_noise_and_bad_shots}"
    clip_num = @clip_num
    phone_filename = @phone.filename(clip_num)
    sound_filename = @microphone.filename(clip_num)

    if @saving_clips.include?(clip_num) || (@use_camera && phone_filename.nil?) || sound_filename.nil?
      @logger.debug "save_clip: skipping #{clip_num}"
    else
      output_filename = get_output_filename clip_num
      @logger.info "save_clip #{clip_num} as #{output_filename}"
      @saving_clips.add(clip_num)

      @thread_pool.post do
        begin
          camera_filename = @phone.move_to_host(phone_filename, clip_num)
          @logger.debug "save_clip: camera_filename=#{camera_filename} sound_filename=#{sound_filename}"

          start_position, end_position = compute_cut_position(sound_filename, camera_filename, trim_noise_and_bad_shots)

          processed_sound_filename = process_sound(camera_filename, sound_filename, start_position, end_position)
          @logger.debug "save_clip: processed_sound_filename=#{processed_sound_filename}"

          if @use_camera
            if start_position >= end_position
              @logger.info "skipping too short clip #{clip_num}"
            else
              processed_video_filename = process_video(camera_filename, start_position, end_position)
              command = "#{FFMPEG} -i #{processed_sound_filename} -an -i #{processed_video_filename} -shortest -codec copy #{output_filename}"
              @logger.debug command
              system command
            end
            temp_files = [camera_filename, processed_video_filename, sound_filename, processed_sound_filename]
          else
            FileUtils.mv processed_sound_filename, output_filename, force: true
            temp_files = [sound_filename]
          end

          @logger.debug "save_clip: removing temp files: #{temp_files}"
          FileUtils.rm_f temp_files

          @logger.info "save_clip: #{clip_num} as #{output_filename} ok"
        rescue StandardError => error
          @logger.info "ignoring saving of #{clip_num} as #{output_filename}"
          @logger.debug error
        end
      end
    end
  end

  def compute_cut_position(sound_filename, camera_filename, trim_noise_and_bad_shots)
    sound_duration = get_duration(sound_filename)
    duration = @use_camera ? [get_duration(camera_filename), sound_duration].min
                           : sound_duration

    start_position = @trim_duration
    end_position = duration - @trim_duration

    if trim_noise_and_bad_shots
      shot_position = detect_last_shot sound_filename
      unless shot_position.nil?
        shot_start, shot_end = shot_position
        shot_start -= VADNET_CORRECTION
        shot_end += VADNET_CORRECTION

        start_position = [shot_start, start_position].max
        end_position = [shot_end, end_position].min
      end
      @logger.debug "detect_last_shot => #{[start_position, end_position]} duration=#{duration}"
    end

    [start_position, end_position]
  end

  def detect_last_shot(sound_filename)
    min_shot_size = 1.0
    script_filename = File.join(File.dirname(__FILE__), '..', 'lib', 'voice', 'detect_voice.py')

    ranges = `#{script_filename} #{sound_filename} #{min_shot_size} #{@min_pause_between_shots}`.split("\n")
    @logger.debug "vadnet says: #{ranges.join(',')}"

    ranges
      .map { |line| line.split(' ') }
      .map { |r| r.map(&:to_f) }
      .select { |r| r.length == 2 && r[0] < r[1] }
      .last
  end

  def process_video(camera_filename, start_position, end_position)
    output_filename = "#{camera_filename}_processed.mp4"
    video_filters = ["fps=#{@fps}", "setpts=(1/#{@speed})*PTS"] + @video_filters.split(',')
    command = "#{FFMPEG} -i #{camera_filename} -ss #{start_position} -to #{end_position} -an -vcodec libx264 #{@video_compression} -vf '#{video_filters.join(',')}' #{output_filename}"
    @logger.debug command
    system command
    output_filename
  end

  def get_output_filename(clip_num)
    extension = @use_camera ? '.mkv' : '.flac'
    File.join @project_dir, clip_num.with_leading_zeros + extension
  end

  def get_duration(filename)
    `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{filename}`.to_f
  end

  def process_sound(camera_filename, sound_filename, start_position, end_position)
    flac_output_filename = "#{sound_filename}.flac"

    audio_filters = ['pan=mono|c0=c0', "atempo=#{@speed}"]
    ffmpeg_output_args = "-ss #{start_position} -to #{end_position} -af '#{audio_filters.join(',')}' #{flac_output_filename}"

    if @use_camera
      wav_output_filename = "#{sound_filename}.sync.wav"
      wav_camera_filename = "#{camera_filename}.wav"
      command = "#{FFMPEG} -i #{camera_filename} -vn #{wav_camera_filename} && \
              sync-audio-tracks.sh #{sound_filename} #{wav_camera_filename} #{wav_output_filename} && \
              #{FFMPEG} -i #{wav_output_filename} #{ffmpeg_output_args}"
      @logger.debug command
      system command, out: File::NULL

      temp_files = [wav_output_filename, wav_camera_filename]
      @logger.debug "removing #{temp_files}"
      FileUtils.rm_f temp_files
    else
      command = "#{FFMPEG} -i #{sound_filename} #{ffmpeg_output_args}"
      @logger.debug command
      system command, out: File::NULL
    end

    unless File.file?(flac_output_filename)
      raise "Failed to process #{flac_output_filename}"
    end

    flac_output_filename
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
      recording = @recording ? 'LIVE' : 'stopped'
      battery_level, battery_temperature = @phone.get_battery_info
      text = "[ #{recording} ] [ battery: #{battery_level}% / #{battery_temperature}°C ]"
    end
    postfix = ' ' * (size - text.length)
    print "#{text}#{postfix}\r"
    STDOUT.flush
  end

  def play
    clips = get_clips [@project_dir]
    unless clips.empty?
      output_filename = clips.last
      @logger.debug "play: #{output_filename}"

      last_playlist_position = clips.length - 1
      command = "#{MPV} --playlist-start=#{last_playlist_position} #{clips.join(' ')}"
      @logger.debug command
      system command
    end
  end
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

def parse_options!(options)
  OptionParser.new do |opts|
    opts.banner = 'Usage: vlog-recorder.rb -p project_dir/ [other options]'
    opts.on('-p', '--project [dir]', 'Project directory') { |p| options[:project_dir] = p }
    opts.on('-t', '--trim [duration]', 'Trim duration of beginning and ending of each clip (default 0.15)') { |t| options[:trim_duration] = t.to_f }
    opts.on('-s', '--sound-settings [arecord-args]', 'Additional arecord arguments (default " --device=default --format=dat"') { |s| options[:arecord_args] = s }
    opts.on('-a', '--android-device [device-id]', 'Android device id') { |a| options[:android_id] = a }
    opts.on('-o', '--opencamera-dir [dir]', 'Open Camera directory path on Android device (default "/mnt/sdcard/DCIM/OpenCamera")') { |o| options[:opencamera_dir] = o }
    opts.on('-u', '--use-camera [true|false]', 'Whether we use Android device at all (default "true")') { |u| options[:use_camera] = u == 'true' }
    opts.on('-b', '--change-brightness [true|false]', 'Set lowest brightness to save device power (default "false")') { |b| options[:change_brightness] = b == 'true' }
    opts.on('-f', '--fps [num]', 'Constant frame rate (default "30")') { |f| options[:fps] = f.to_i }
    opts.on('-S', '--speed [num]', 'Speed factor (default "1.2")') { |s| options[:speed] = s.to_f }
    opts.on('-V', '--video-filters [filters]', 'ffmpeg video filters (default "hflip,atadenoise,vignette")') { |v| options[:video_filters] = v }
    opts.on('-C', '--video-compression [options]', 'libx264 options (default " -preset ultrafast -crf 18")') { |c| options[:video_compression] = c }
    opts.on('-P', '--pause-between-shots [seconds]', 'Minimum pause between shots for auto trimming (default 3)') { |p| options[:pause_between_shots] = p }
  end.parse!

  raise OptionParser::MissingArgument if options[:project_dir].nil?
end

options = {
  trim_duration: 0.15,
  arecord_args: '--device=default --format=dat',
  android_id: '',
  opencamera_dir: '/mnt/sdcard/DCIM/OpenCamera',
  use_camera: true,
  change_brightness: false,
  fps: 30,
  speed: 1.2,
  video_filters: 'hflip,atadenoise,vignette',
  video_compression: '-preset ultrafast -crf 18',
  pause_between_shots: 3.0
}
parse_options!(options)

begin
  project_dir = options[:project_dir]
  temp_dir = File.join project_dir, 'tmp'
  FileUtils.mkdir_p(temp_dir)

  logger = Logger.new File.join(project_dir, 'log.txt')
  # logger.level = Logger::WARN

  logger.debug options

  devices = DevicesFacade.new options, temp_dir, logger
  show_help
  run_main_loop(devices)
rescue SystemExit, Interrupt
rescue StandardError => error
  logger.fatal(error) unless logger.nil?
  puts error
ensure
  puts 'Exiting...'
  logger.info('exit') unless logger.nil?

  devices.close unless devices.nil?
  logger.close unless logger.nil?
end
