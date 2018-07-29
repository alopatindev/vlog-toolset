class Phone
  APP_ID = 'net.sourceforge.opencamera'.freeze
  ADB_SHELL = 'adb shell'.freeze
  MAIN_ACTIVITY = "#{APP_ID}/#{APP_ID}.MainActivity".freeze
  NEWLINE_SPLITTER = "\r\n".freeze

  def initialize(opencamera_dir, logger)
    @opencamera_dir = opencamera_dir
    @logger = logger

    wakeup
    if locked?
      raise 'You need to unlock the screen'
    else
      run_opencamera unless opencamera_active?
      @width, @height = get_size
      @initial_brightness = get_brightness
    end
  end

  def clip_filename
    `#{ADB_SHELL} 'ls #{@opencamera_dir}/*.mp4 2>> /dev/null'`
      .split(NEWLINE_SPLITTER)
      .reject(&:empty?)
      .last
  end

  def move_file_to_host(phone_file, local_file)
    @logger.debug "move_file_to_host #{phone_file}, #{local_file}"
    system "adb pull -a '#{phone_file}' '#{local_file}' 2>> /dev/null && \
            #{ADB_SHELL} rm -f '#{phone_file}'", out: File::NULL
  end

  def delete_clip
    filename = clip_filename
    @logger.debug "removing #{filename}"
    system("#{ADB_SHELL} rm -f '#{filename}'")
  end

  def toggle_recording
    tap 0.92, 0.5
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
end
