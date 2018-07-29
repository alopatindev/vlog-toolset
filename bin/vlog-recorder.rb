#!/bin/env ruby

require 'phone.rb'
require 'microphone.rb'

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

    @phone = Phone.new(opencamera_dir, logger)
    @phone.set_brightness(0)

    @thread_pool = Concurrent::FixedThreadPool.new(Concurrent.processor_count)

    logger.info('initialized')
  end

  def get_last_clip_num
    Dir.glob("{#{@temp_dir},#{@project_dir}}#{File::SEPARATOR}*.{wav,mp4,mkv}")
       .map { |f| f.gsub(/.*#{File::SEPARATOR}0*/, '').gsub(/\..*$/, '').to_i }.max || 0
  end

  def clip_with_leading_zeros
    format('%016d', @clip_num)
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
    @logger.debug "toggle_recording from #{@recording}"

    @recording = !@recording
    @clip_num += 1 if @recording

    sound_filename = File.join @temp_dir, clip_with_leading_zeros + '.wav'
    @microphone.toggle_recording sound_filename
    @phone.toggle_recording
  end

  def focus
    @logger.debug 'focus'
    @phone.focus
  end

  def delete_clip
    @microphone.delete_clip
    @phone.delete_clip
  end

  def save_clip
    output_filename = File.join @project_dir, clip_with_leading_zeros + '.mkv'
    temp_clip_filename = File.join @temp_dir, clip_with_leading_zeros + '.mp4'

    sound_filename = @microphone.sound_filename
    phone_clip_filename = @phone.clip_filename
    @logger.debug "saving #{output_filename} ; sound=#{sound_filename} video=#{phone_clip_filename}"

    @thread_pool.post do
      begin
        @phone.move_file_to_host(phone_clip_filename, temp_clip_filename)
        unless File.file?(temp_clip_filename)
          raise "Failed to move #{temp_clip_filename}"
        end

        processed_sound_filename = process_sound(temp_clip_filename, sound_filename)
        unless File.file?(processed_sound_filename)
          raise "Failed to process #{processed_sound_filename}"
        end

        system("#{FFMPEG} -i #{processed_sound_filename} -an -i #{temp_clip_filename} -codec copy #{output_filename}")

        temp_files = [temp_clip_filename, sound_filename, processed_sound_filename]
        @logger.debug "removing #{temp_files}"
        FileUtils.rm_f temp_files

        @logger.info "saved #{output_filename}"
      rescue StandardError => error
        @logger.error "failed to save #{output_filename}"
        @logger.error error
      end
    end
  end

  def process_sound(clip_filename, sound_filename)
    wav_clip_filename = "#{clip_filename}.wav"
    flac_output_filename = "#{sound_filename}.flac"
    wav_output_filename = "#{sound_filename}.sync.wav"

    command = "#{FFMPEG} -i #{clip_filename} -vn #{wav_clip_filename} && \
            sync-audio-tracks.sh #{sound_filename} #{wav_clip_filename} #{wav_output_filename} && \
            #{FFMPEG} -i #{wav_output_filename} -af 'pan=mono|c0=c0' #{flac_output_filename}"
    @logger.debug "running '#{command}'"
    system command, out: File::NULL

    temp_files = [wav_output_filename, wav_clip_filename]
    @logger.debug "removing #{temp_files}"
    FileUtils.rm_f temp_files

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
