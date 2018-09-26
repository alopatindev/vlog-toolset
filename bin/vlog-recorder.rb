#!/bin/env ruby

require 'phone.rb'
require 'microphone.rb'
require 'numeric.rb'
require 'ffmpeg_utils.rb'
require 'voice/detect_voice.rb'

require 'concurrent'
require 'fileutils'
require 'io/console'
require 'logger'
require 'optparse'

class DevicesFacade
  MPV = 'mpv --no-terminal --fs --volume=130'.freeze
  MIN_SHOT_SIZE = 1.0

  def initialize(options, temp_dir, logger)
    @project_dir = options[:project_dir]
    @temp_dir = temp_dir
    @trim_duration = options[:trim_duration]
    @min_pause_between_shots = options[:min_pause_between_shots]
    @aggressiveness = options[:aggressiveness]
    @fps = options[:fps]
    @speed = clamp_speed(options[:speed])
    @video_filters = options[:video_filters]
    @video_compression = options[:video_compression]
    @reencode_video = options[:reencode_video]
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
    Dir.glob("{#{dirs_joined}}#{File::SEPARATOR}0*.{wav,mp4,mkv,m4a}")
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
      delete_last_subclip
    else
      ok = delete_unsaved_clip
      delete_last_subclip unless ok
    end
  end

  def delete_last_subclip
    @logger.debug 'delete_last_subclip'
    filename = get_clips([@project_dir]).last
    if !filename.nil? && (File.file? filename)
      show_status "Delete #{filename}? y/n"
      remove_files filename if STDIN.getch == 'y'
    end
  end

  def save_clip(trim_noise)
    @logger.debug "save_clip: trim_noise = #{trim_noise}"
    clip_num = @clip_num
    phone_filename = @phone.filename(clip_num)
    sound_filename = @microphone.filename(clip_num)

    if @saving_clips.include?(clip_num) || phone_filename.nil? || sound_filename.nil?
      @logger.debug "save_clip: skipping #{clip_num}"
    else
      @logger.info "save_clip #{clip_num}"
      @saving_clips.add(clip_num)

      @thread_pool.post do
        begin
          camera_filename = @phone.move_to_host(phone_filename, clip_num)
          @logger.debug "save_clip: camera_filename=#{camera_filename} sound_filename=#{sound_filename}"

          sync_offset, sync_sound_filename = synchronize_sound(camera_filename, sound_filename)
          @logger.debug "save_clip: sync_offset=#{sync_offset}"

          segments = detect_segments(sync_sound_filename, camera_filename, sync_offset, trim_noise)
          processed_sound_filenames = process_sound(sync_sound_filename, segments)
          @logger.debug "save_clip: processed_sound_filenames=#{processed_sound_filenames}"

          processed_video_filenames = process_video(camera_filename, segments)
          output_filenames = merge_files(processed_sound_filenames, processed_video_filenames, clip_num)
          remove_files [camera_filename, sound_filename, sync_sound_filename] + processed_sound_filenames + processed_video_filenames
          @logger.info "save_clip: #{clip_num} as #{output_filenames} ok"
        rescue StandardError => error
          @logger.info "ignoring saving of #{clip_num} as #{output_filename}"
          @logger.debug error
        end
      end
    end
  end

  def merge_files(processed_sound_filenames, processed_video_filenames, clip_num)
    processed_sound_filenames
      .zip(processed_video_filenames)
      .each_with_index
      .map do |f, subclip_num|
      @logger.debug "save_clip: merging files #{f} #{subclip_num}"

      processed_sound_filename, processed_video_filename = f
      output_filename = get_output_filename clip_num, subclip_num
      @logger.debug "save_clip: output_filename=#{output_filename}"
      command = "#{FFMPEG} -i #{processed_sound_filename} -an -i #{processed_video_filename} -shortest -codec copy -f ipod #{output_filename}"
      @logger.debug command
      system command

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
      @logger.debug "voice segments: #{voice_segments.join(',')}"

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
    video_filters = ["fps=#{@fps}", "setpts=(1/#{@speed})*PTS"] + @video_filters.split(',')

    segments.each_with_index.map do |seg, subclip_num|
      start_position, end_position = seg
      output_filename = "#{camera_filename}_#{subclip_num}.processed.mp4"
      temp_filename = "#{camera_filename}_#{subclip_num}.cut.mp4"

      system "#{FFMPEG} -ss #{start_position} -i #{camera_filename} -to #{end_position - start_position} -an -c copy #{temp_filename}"
      if @reencode_video
        system "#{FFMPEG} -i #{temp_filename} -vcodec libx264 #{@video_compression} -vf '#{video_filters.join(',')}' #{output_filename}"
        remove_files temp_filename
      else
        FileUtils.mv temp_filename, output_filename, force: true
      end

      output_filename
    end
  end

  def get_output_filename(clip_num, subclip_num)
    File.join @project_dir, "#{clip_num.with_leading_zeros}_#{subclip_num.with_leading_zeros}.mp4"
  end

  def get_duration(filename)
    `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{filename}`.to_f
  end

  def synchronize_sound(camera_filename, sound_filename)
    output_filename = "#{sound_filename}.sync.wav"

    sync_offset = `sync-audio-tracks.sh #{sound_filename} #{camera_filename} #{output_filename}`
                  .split("\n")
                  .select { |line| line.start_with? 'offset is' }
                  .map { |line| line.sub(/^offset is /, '').sub(/ seconds$/, '').to_f }
                  .first || 0.0

    [sync_offset, output_filename]
  end

  def process_sound(sync_sound_filename, segments)
    audio_filters = ['pan=mono|c0=c0']
    audio_filters.append "atempo=#{@speed}" if @reencode_video

    segments.each_with_index.map do |seg, subclip_num|
      start_position, end_position = seg
      output_filename = "#{sync_sound_filename}_#{subclip_num}.m4a"

      ffmpeg_cut_args = "-ss #{start_position} -i #{sync_sound_filename} -to #{end_position - start_position} -c copy"
      ffmpeg_output_args = "-af '#{audio_filters.join(',')}' -acodec alac"

      temp_filename = "#{sync_sound_filename}_#{subclip_num}.cut.wav"
      command = "#{FFMPEG} #{ffmpeg_cut_args} #{temp_filename} && \
        #{FFMPEG} -i #{temp_filename} #{ffmpeg_output_args} #{output_filename}"
      @logger.debug command
      system command, out: File::NULL
      remove_files temp_filename

      unless File.file?(output_filename)
        raise "Failed to process #{output_filename}"
      end

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
      last_clip_num = parse_clip_num clips.last
      @logger.debug "play clip: #{last_clip_num}"

      last_clip_filename = File.basename(get_output_filename(last_clip_num, subclip_num = 0))
      position_in_playlist = clips
                             .map { |f| File.basename(f) }
                             .index(last_clip_filename) || clips.length - 1

      mpv_args = @reencode_video ? '' : "-vf=mirror --speed=#{@speed}"
      command = "#{MPV} #{mpv_args} --playlist-start=#{position_in_playlist} #{clips.join(' ')}"
      @logger.debug command
      system command
    end
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

def parse_options!(options)
  OptionParser.new do |opts|
    opts.banner = 'Usage: vlog-recorder.rb -p project_dir/ [other options]'
    opts.on('-p', '--project [dir]', 'Project directory') { |p| options[:project_dir] = p }
    opts.on('-t', '--trim [duration]', 'Trim duration of beginning and ending of each clip (default: 0.15)') { |t| options[:trim_duration] = t.to_f }
    opts.on('-s', '--sound-settings [arecord-args]', 'Additional arecord arguments (default: " --device=default --format=dat"') { |s| options[:arecord_args] = s }
    opts.on('-A', '--android-device [device-id]', 'Android device id') { |a| options[:android_id] = a }
    opts.on('-o', '--opencamera-dir [dir]', 'Open Camera directory path on Android device (default: "/mnt/sdcard/DCIM/OpenCamera")') { |o| options[:opencamera_dir] = o }
    opts.on('-b', '--change-brightness [true|false]', 'Set lowest brightness to save device power (default: false)') { |b| options[:change_brightness] = b == 'true' }
    opts.on('-f', '--fps [num]', 'Constant frame rate (default: 30)') { |f| options[:fps] = f.to_i }
    opts.on('-S', '--speed [num]', 'Speed factor (default: 1.2)') { |s| options[:speed] = s.to_f }
    opts.on('-V', '--video-filters [filters]', 'ffmpeg video filters (default: "atadenoise,hflip,vignette")') { |v| options[:video_filters] = v }
    opts.on('-C', '--video-compression [options]', 'libx264 options (default: " -preset ultrafast -crf 18")') { |c| options[:video_compression] = c }
    opts.on('-r', '--reencode-video [true|false]', 'Whether we should apply any effects') { |r| options[:reencode_video] = r == 'true' }
    opts.on('-P', '--pause-between-shots [seconds]', 'Minimum pause between shots for auto trimming (default: 2)') { |p| options[:min_pause_between_shots] = p }
    opts.on('-a', '--aggressiveness [0..3]', 'How aggressively to filter out non-speech (default: 2)') { |a| options[:aggressiveness] = a.to_i }
    opts.on('-d', '--debug [true|false]', 'Show debug messages (default: false)') { |d| options[:debug] = d == 'true' }
  end.parse!

  raise OptionParser::MissingArgument if options[:project_dir].nil?
end

options = {
  trim_duration: 0.15,
  arecord_args: '--device=default --format=dat',
  android_id: '',
  opencamera_dir: '/mnt/sdcard/DCIM/OpenCamera',
  change_brightness: false,
  fps: 30,
  speed: 1.2,
  video_filters: 'atadenoise,hflip,vignette',
  video_compression: '-preset ultrafast -crf 18',
  reencode_video: true,
  min_pause_between_shots: 2.0,
  aggressiveness: 2,
  debug: false
}
parse_options!(options)

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
rescue StandardError => error
  logger.fatal(error) unless logger.nil?
  puts error
ensure
  puts 'Exiting...'
  logger.info('exit') unless logger.nil?

  devices.close unless devices.nil?
  logger.close unless logger.nil?
end
