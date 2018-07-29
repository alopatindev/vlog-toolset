require 'numeric.rb'

require 'set'

class Phone
  APP_ID = 'net.sourceforge.opencamera'.freeze
  ADB_SHELL = 'adb shell'.freeze
  MAIN_ACTIVITY = "#{APP_ID}/#{APP_ID}.MainActivity".freeze
  NEWLINE_SPLITTER = "\r\n".freeze
  POLL_WAIT_TIME = 0.3

  def initialize(temp_dir, opencamera_dir, logger)
    @temp_dir = temp_dir
    @opencamera_dir = opencamera_dir
    @logger = logger

    @clip_num_to_filename = {}
    @filenames = Set.new
    @filenames = get_new_filenames.to_set

    wakeup

    if locked?
      raise 'You need to unlock the screen'
    else
      run_opencamera unless opencamera_active?
      @width, @height = get_size
      @initial_brightness = get_brightness
    end
  end

  def move_to_host(phone_filename, clip_num)
    local_filename = File.join @temp_dir, clip_num.with_leading_zeros + '.mp4'
    @logger.debug "move_to_host #{phone_filename} => #{local_filename}"

    system "adb pull -a '#{phone_filename}' '#{local_filename}' 2>> /dev/null && \
            #{ADB_SHELL} rm -f '#{phone_filename}'", out: File::NULL

    raise "Failed to move #{phone_filename} => #{local_filename}" unless File.file?(local_filename)
    @logger.debug "move_to_host #{phone_filename} => #{local_filename} ok"

    local_filename
  end

  def delete_clip(clip_num)
    filename = filename(clip_num)
    unless filename.nil?
      @logger.debug "phone.delete_clip #{clip_num} #{filename}"
      system("#{ADB_SHELL} rm -f '#{filename}'")
      @clip_num_to_filename.delete(clip_num)
    end
  end

  def filename(clip_num)
    @clip_num_to_filename[clip_num]
  end

  def assign_new_filename(clip_num, filename)
    raise "#{filename} is a known file" if @filenames.include?(filename)
    @logger.debug "phone.assign_new_filename #{clip_num} => #{filename}"
    @clip_num_to_filename[clip_num] = filename
    @filenames.add filename
  end

  def get_new_filenames
    `#{ADB_SHELL} 'ls #{@opencamera_dir}/*.mp4 2>> /dev/null'`
      .split(NEWLINE_SPLITTER)
      .map(&:strip)
      .reject { |f| @filenames.include?(f) }
  end

  def wait_for_new_filename(new_clip_num)
    @logger.debug "waiting for #{new_clip_num}"
    # TODO: limit number of iterations?
    unless @clip_num_to_filename.include?(new_clip_num)
      begin
        sleep POLL_WAIT_TIME
        new_filenames = get_new_filenames
        if new_filenames.length > 1
          @logger.warn "#{new_filenames.length} new files were detected, using the first one"
        end
        new_filenames.take(1).map { |f| assign_new_filename(new_clip_num, f) }
      end while new_filenames.empty?
    end
  end

  def toggle_recording(clip_num, recording)
    tap 0.92, 0.5

    wait_for_new_filename clip_num if recording
  end

  def focus
    tap 0.5, 0.5
  end

  def tap(x, y)
    screen_x = (x * @height).to_i
    screen_y = (y * @width).to_i
    system "#{ADB_SHELL} input tap #{screen_x} #{screen_y}"
  end

  def locked?
    if `#{ADB_SHELL} dumpsys window` =~ /mShowingLockscreen=(.*?)\s/
      Regexp.last_match(1) == 'true'
    else
      raise 'Failed to check if device is locked'
    end
  end

  def wakeup
    system "#{ADB_SHELL} input keyevent KEYCODE_WAKEUP"
  end

  def opencamera_active?
    `#{ADB_SHELL} dumpsys window windows`.match?(/mCurrentFocus=Window\{[0-9a-f]* u0 #{MAIN_ACTIVITY}/)
  end

  def run_opencamera
    system "#{ADB_SHELL} am start -n #{MAIN_ACTIVITY}", out: File::NULL
  end

  def close_opencamera
    system "#{ADB_SHELL} input keyevent KEYCODE_BACK"
  end

  def get_size
    dumpsys = `#{ADB_SHELL} dumpsys display`
    if dumpsys =~ /mDisplayWidth=([0-9]*?)#{NEWLINE_SPLITTER}\s*mDisplayHeight=([0-9]*?)#{NEWLINE_SPLITTER}/
      width = Regexp.last_match(1).to_i
      height = Regexp.last_match(2).to_i
      [width, height]
    else
      raise 'Failed to fetch display size'
    end
  end

  def get_brightness
    `#{ADB_SHELL} settings get system screen_brightness`.to_i
  end

  def set_brightness(brightness)
    `#{ADB_SHELL} settings put system screen_brightness #{brightness}`.to_i
  end

  def restore_brightness
    set_brightness @initial_brightness
  end

  def get_battery_info
    dumpsys = `#{ADB_SHELL} dumpsys battery`.split(NEWLINE_SPLITTER)
    level = dumpsys.select { |line| line.include? 'level: ' }
                   .map { |line| line.gsub(/.*: /, '') }
                   .first
    temperature = dumpsys.select { |line| line.include? 'temperature: ' }
                         .map { |line| line.gsub(/.*: /, '').to_i / 10 }
                         .first
    [level, temperature]
  end
end
