class Phone
  APP_ID = 'net.sourceforge.opencamera'.freeze
  MAIN_ACTIVITY = "#{APP_ID}/#{APP_ID}.MainActivity".freeze
  ADB_SHELL = 'adb shell'.freeze

  def initialize(_project_dir, _temp_dir, logger)
    @logger = logger

    wakeup
    if locked?
      raise 'You need to unlock the screen'
    else
      run_opencamera unless opencamera_active?
      @width, @height = get_size
      @initial_brightness = get_brightness
      # TODO: get current recording state?
    end
  end

  def toggle_recording
    tap(0.92, 0.5)
  end

  def focus
    tap(0.5, 0.5)
  end

  def tap(x, y)
    screen_x = (x * @height).to_i
    screen_y = (y * @width).to_i
    system("#{ADB_SHELL} input tap #{screen_x} #{screen_y}")
  end

  def locked?
    if `#{ADB_SHELL} dumpsys window` =~ /mShowingLockscreen=(.*?)\s/
      Regexp.last_match(1) == 'true'
    else
      raise 'Failed to check if device is locked'
    end
  end

  def wakeup
    system("#{ADB_SHELL} input keyevent KEYCODE_WAKEUP")
  end

  def opencamera_active?
    `#{ADB_SHELL} dumpsys window windows`.match?(/mCurrentFocus=Window\{[0-9a-f]* u0 #{MAIN_ACTIVITY}/)
  end

  def run_opencamera
    @logger.info 'starting opencamera'
    system("#{ADB_SHELL} am start -n #{MAIN_ACTIVITY}")
  end

  def close_opencamera
    system("#{ADB_SHELL} input keyevent KEYCODE_BACK")
  end

  def get_size
    dumpsys = `#{ADB_SHELL} dumpsys display`
    if dumpsys =~ /mDisplayWidth=([0-9]*?)\r\n\s*mDisplayHeight=([0-9]*?)\r\n/
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
