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
  MEDIA_PLAYER = 'mpv --no-terminal'.freeze

  def initialize(options, temp_dir, logger)
    @project_dir = options[:project_dir]
    @temp_dir = temp_dir
    @trim_duration = options[:trim_duration]
    @use_camera = options[:use_camera]
    @logger = logger

    @recording = false
    @clip_num = get_last_clip_num
    @logger.debug "clip_num is #{@clip_num}"

    arecord_args = options[:arecord_args]
    @microphone = Microphone.new(temp_dir, arecord_args, logger)

    @phone = Phone.new(temp_dir, options, logger)
    @phone.set_brightness(0)

    @thread_pool = Concurrent::FixedThreadPool.new(Concurrent.processor_count)
    @saving_clips = Set.new

    logger.info('initialized')
  end

  def get_last_clip_num
    Dir.glob("{#{@temp_dir},#{@project_dir}}#{File::SEPARATOR}*.{wav,mp4,mkv,flac}")
       .map { |f| f.gsub(/.*#{File::SEPARATOR}0*/, '').gsub(/\..*$/, '').to_i }.max || 0
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

  def delete_clip
    unless @saving_clips.include? @clip_num
      @microphone.delete_clip @clip_num
      @phone.delete_clip @clip_num
    end
  end

  def save_clip
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
          processed_sound_filename = process_sound(camera_filename, sound_filename)
          @logger.debug "save_clip: processed_sound_filename=#{processed_sound_filename}"

          processed_sound_duration = get_duration(processed_sound_filename)
          duration = @use_camera ? [get_duration(camera_filename), processed_sound_duration].min
                                 : processed_sound_duration
          end_position = duration - @trim_duration

          if @use_camera
            if @trim_duration >= end_position
              @logger.info "skipping too short clip #{clip_num}"
            else
              command = "#{FFMPEG} -i '#{processed_sound_filename}' -an -i '#{camera_filename}' -ss #{@trim_duration} -to #{end_position} -shortest -codec copy '#{output_filename}'"
              @logger.debug command
              system command
            end
            temp_files = [camera_filename, sound_filename, processed_sound_filename]
          else
            command = "#{FFMPEG} -i '#{processed_sound_filename}' -ss #{@trim_duration} -to #{end_position} -codec copy '#{output_filename}'"
            @logger.debug command
            system command
            temp_files = [sound_filename, processed_sound_filename]
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

  def get_output_filename(clip_num)
    extension = @use_camera ? '.mkv' : '.flac'
    File.join @project_dir, clip_num.with_leading_zeros + extension
  end

  def get_duration(filename)
    `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 '#{filename}'`.to_f
  end

  def process_sound(camera_filename, sound_filename)
    flac_output_filename = "#{sound_filename}.flac"

    if @use_camera
      wav_output_filename = "#{sound_filename}.sync.wav"
      wav_camera_filename = "#{camera_filename}.wav"
      command = "#{FFMPEG} -i #{camera_filename} -vn #{wav_camera_filename} && \
              sync-audio-tracks.sh #{sound_filename} #{wav_camera_filename} #{wav_output_filename} && \
              #{FFMPEG} -i #{wav_output_filename} -af 'pan=mono|c0=c0' #{flac_output_filename}"
      @logger.debug command
      system command, out: File::NULL

      temp_files = [wav_output_filename, wav_camera_filename]
      @logger.debug "removing #{temp_files}"
      FileUtils.rm_f temp_files
    else
      command = "#{FFMPEG} -i '#{sound_filename}' -af 'pan=mono|c0=c0' '#{flac_output_filename}'"
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
      save_clip
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
    output_filename = get_output_filename @clip_num
    @logger.debug "play: #{output_filename}"
    @logger.debug "play: #{@saving_clips.include?(@clip_num)} #{File.file?(output_filename)}"
    if @saving_clips.include?(@clip_num) && File.file?(output_filename)
      command = "#{MEDIA_PLAYER} #{output_filename}"
      @logger.debug command
      system command
    end
  end
end

def show_help
  puts 'r - (RE)START recording'
  puts 's - STOP and SAVE current clip'
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
      devices.delete_clip
      devices.start_recording
    when 's'
      devices.stop_recording
      devices.save_clip
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
  end.parse!

  p options

  raise OptionParser::MissingArgument if options[:project_dir].nil?
end

options = {
  trim_duration: 0.15,
  arecord_args: ' --device=default --format=dat',
  android_id: '',
  opencamera_dir: '/mnt/sdcard/DCIM/OpenCamera',
  use_camera: true
}
parse_options!(options)

begin
  project_dir = options[:project_dir]
  temp_dir = File.join project_dir, 'tmp'
  FileUtils.mkdir_p(temp_dir)

  logger = Logger.new File.join(project_dir, 'log.txt')
  # logger.level = Logger::WARN

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
