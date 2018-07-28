#!/bin/env ruby

require 'phone.rb'
require 'microphone.rb'

require 'fileutils'
require 'io/console'
require 'logger'

class DevicesFacade
  def initialize(project_dir, temp_dir, logger)
    @recording = false

    @microphone = Microphone.new(project_dir, temp_dir, logger)

    @phone = Phone.new(project_dir, temp_dir, logger)
    @phone.set_brightness(0)

    logger.info('initialized')
  end

  def toggle_recording
    @recording = !@recording
    @phone.toggle_recording
    @microphone.toggle_recording
  end

  def restore_initial_state
    toggle_recording if @recording
    @phone.restore_brightness
    @phone.close_opencamera
  end
end

def show_help
  puts 'r - (RE)START recording'
  puts 's - STOP and SAVE current clip'
  puts 'd - STOP and DELETE current clip'
  puts 'f - FOCUS camera on face'
  puts 'h — show HELP'
  puts 'q / Ctrl+C - QUIT'
  puts
end

def run_main_loop(_devices, _logger)
  loop do
    case STDIN.getch
    when 'q'
      break
    when 'r'
      puts 'pressed r'
      sleep 3
    when 'h'
      show_help
    end
  end

  #  devices.toggle_recording
  #  sleep 3
  #  devices.toggle_recording
end

if ARGV.empty?
  puts 'syntax phone-and-mic-rec.rb project_dir/'
  exit 1
end

begin
  project_dir = ARGV[0]
  temp_dir = File.join(project_dir, 'tmp')
  FileUtils.mkdir_p(temp_dir)

  # logger = Logger.new(File.join(project_dir, 'log.txt'))
  logger = Logger.new(File.join(project_dir, 'log.txt'), File::WRONLY | File::CREAT)
  logger.level = Logger::WARN

  devices = DevicesFacade.new(project_dir, temp_dir, logger)
  show_help
  run_main_loop(devices, logger)
rescue SystemExit, Interrupt
rescue StandardError => error
  logger.fatal error
end

puts 'Exiting...'
logger.info('exit')

devices.restore_initial_state
logger.close
