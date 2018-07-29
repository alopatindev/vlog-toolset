#!/bin/env ruby

require 'phone.rb'
require 'microphone.rb'
require 'numeric.rb'

require 'concurrent'
require 'fileutils'
require 'io/console'
require 'logger'

class DevicesFacade
  FFMPEG = 'ffmpeg -y -hide_banner -loglevel error'.freeze

  def initialize(project_dir, temp_dir, arecord_args, opencamera_dir, logger)
    @project_dir = project_dir
    @temp_dir = temp_dir
    @logger = logger

    @recording = false
    @clip_num = get_last_clip_num
    @logger.debug "clip_num is #{@clip_num}"

    @microphone = Microphone.new(temp_dir, arecord_args, logger)

    @phone = Phone.new(temp_dir, opencamera_dir, logger)
    @phone.set_brightness(0)

    @thread_pool = Concurrent::FixedThreadPool.new(Concurrent.processor_count)
    @saving_clips = Set.new

    logger.info('initialized')
  end

  def get_last_clip_num
    Dir.glob("{#{@temp_dir},#{@project_dir}}#{File::SEPARATOR}*.{wav,mp4,mkv}")
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

    if @saving_clips.include?(clip_num) || phone_filename.nil? || sound_filename.nil?
      $logger.debug "save_clip: skipping #{clip_num}"
    else
      output_filename = File.join @project_dir, clip_num.with_leading_zeros + '.mkv'
      @logger.info "save_clip #{@clip_num} as #{output_filename}"

      @thread_pool.post do
        begin
          camera_filename = @phone.move_to_host(phone_filename, clip_num)
          @logger.debug "save_clip: camera_filename=#{camera_filename} sound_filename=#{sound_filename}"
          processed_sound_filename = process_sound(camera_filename, sound_filename)
          @logger.debug "save_clip: processed_sound_filename=#{processed_sound_filename}"

          command = "#{FFMPEG} -i '#{processed_sound_filename}' -an -i '#{camera_filename}' -codec copy '#{output_filename}'"
          @logger.debug command
          system command

          temp_files = [camera_filename, sound_filename, processed_sound_filename]
          @logger.debug "save_clip: removing temp files: #{temp_files}"
          FileUtils.rm_f temp_files

          @logger.info "save_clip: #{clip_num} as #{output_filename} ok"
        rescue StandardError => error
          @logger.info "ignoring saving of #{clip_num} as #{output_filename}"
        end
      end
    end
  end

  def process_sound(camera_filename, sound_filename)
    wav_camera_filename = "#{camera_filename}.wav"
    flac_output_filename = "#{sound_filename}.flac"
    wav_output_filename = "#{sound_filename}.sync.wav"

    command = "#{FFMPEG} -i #{camera_filename} -vn #{wav_camera_filename} && \
            sync-audio-tracks.sh #{sound_filename} #{wav_camera_filename} #{wav_output_filename} && \
            #{FFMPEG} -i #{wav_output_filename} -af 'pan=mono|c0=c0' #{flac_output_filename}"
    @logger.debug command
    system command, out: File::NULL

    temp_files = [wav_output_filename, wav_camera_filename]
    @logger.debug "removing #{temp_files}"
    FileUtils.rm_f temp_files

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

  def show_status
    size = 30
    text = @recording ? 'LIVE' : 'stopped'
    postfix = ' ' * (size - text.length)
    print "[ #{text} ]#{postfix}\r"
    STDOUT.flush
  end
end

def show_help
  puts 'r - (RE)START recording'
  puts 's - STOP and SAVE current clip'
  puts 'd - STOP and DELETE current clip'
  puts 'f - FOCUS camera on center'
  puts 'h - show HELP'
  puts 'q / Ctrl+C - QUIT'
  puts
end

def run_main_loop(devices)
  loop do
    devices.show_status

    case STDIN.getch
    when 'q'
      print "Quit? y/n\r"
      break if STDIN.getch == 'y'
    when 'r'
      devices.stop_recording
      devices.show_status
      devices.delete_clip
      devices.start_recording
    when 's'
      devices.stop_recording
      devices.save_clip
    when 'd'
      devices.stop_recording
      devices.delete_clip
    when 'f'
      devices.focus
    when 'h'
      show_help
    end
  end
end

if ARGV.empty? || ARGV[0] == '-h' || ARGV[0] == '--help'
  puts 'syntax phone-and-mic-rec.rb project_dir/ [arecord-args] [opencamera-dir]'
  exit 1
end

begin
  project_dir = ARGV[0]
  temp_dir = File.join project_dir, 'tmp'
  FileUtils.mkdir_p(temp_dir)

  arecord_args = ARGV[1].nil? ? '--device=default --format=dat' : ARGV[1]
  opencamera_dir = ARGV[2].nil? ? '/mnt/sdcard/DCIM/OpenCamera' : ARGV[2]

  logger = Logger.new File.join(project_dir, 'log.txt')
  # logger.level = Logger::WARN

  devices = DevicesFacade.new project_dir, temp_dir, arecord_args, opencamera_dir, logger
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
