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

require 'colorize'
require 'set'

require 'numeric_utils'
require 'os_utils'

class Phone
  APP_ID = 'net.sourceforge.opencamera'
  MAIN_ACTIVITY = "#{APP_ID}/#{APP_ID}.MainActivity"
  POLL_WAIT_TIME = 0.3
  CAMERA_INITIALIZATION_TIME = 3.0

  PORTRAIT = 0
  REVERSED_PORTRAIT = 180
  LANDSCAPE_FRONT_CAMERA_ON_LEFT = 90
  LANDSCAPE_FRONT_CAMERA_ON_RIGHT = 270

  attr_reader :rotation

  def initialize(project_dir, options, logger)
    @project_dir = project_dir

    @change_brightness = options[:change_brightness] # TODO: remove option?

    @logger = logger
    @opencamera_dir = options[:opencamera_dir]

    set_android_id!(options[:android_id])

    @clip_num_to_filename = {}
    @filenames = Set.new
    @filenames = get_new_filenames.to_set

    raise 'Phone is not connected via USB Debugging' unless connected?

    wakeup

    raise 'Phone Screen is Locked' if locked?

    raise 'Phone Mic is Muted' if mic_muted?

    raise 'Phone Camera is Blocked by user' if camera_blocked?

    unlock_auto_rotate
    close_opencamera
    remove_old_opencamera_videos
    open_home_screen

    run_opencamera
    @initial_brightness = get_brightness
    @initial_night_display_auto_mode = set_night_display_auto_mode(0)

    set_front_camera
    sleep 2.0
    focus
    sleep 0.5
    lock_exposure
  end

  def move_to_host(phone_filename, clip_num)
    local_filename = File.join(@project_dir, 'input_' + clip_num.with_leading_zeros + '.mp4')
    @logger.debug "move_to_host #{phone_filename} => #{local_filename}"

    script_filename = File.join(__dir__, 'adb_repull.py')

    system "#{@adb_env} #{script_filename} '#{phone_filename}' '#{local_filename}' >> /dev/null && \
            #{@adb_shell} rm -f '#{phone_filename}'", out: File::NULL

    raise "Failed to move #{phone_filename} => #{local_filename}" unless File.file?(local_filename)

    @logger.debug "move_to_host #{phone_filename} => #{local_filename} ok"

    local_filename
  end

  def delete_clip(clip_num)
    filename = filename(clip_num)
    return if filename.nil?

    @logger.debug "phone.delete_clip #{clip_num} #{filename}"
    adb_shell("rm -f '#{filename}'")
    @clip_num_to_filename.delete(clip_num)
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
    adb_shell("'ls #{@opencamera_dir}/*.mp4 2>> /dev/null'")
      .split("\n")
      .map(&:strip)
      .reject { |f| @filenames.include?(f) }
  end

  def wait_for_new_filename(new_clip_num)
    @logger.debug "waiting for #{new_clip_num}"
    # TODO: limit number of iterations?
    return if @clip_num_to_filename.include?(new_clip_num)

    begin
      sleep POLL_WAIT_TIME
      new_filenames = get_new_filenames
      @logger.debug "new_filenames=#{new_filenames.inspect}"
      @logger.warn "#{new_filenames.length} new files were detected, using the first one" if new_filenames.length > 1
      new_filenames.take(1).each { |f| assign_new_filename(new_clip_num, f) }
    end while new_filenames.empty?
  end

  def toggle_recording(clip_num, recording)
    tap 0.92, 0.5

    wait_for_new_filename clip_num unless recording
  end

  def focus
    tap 0.5, 0.5
  end

  def tap(x, y)
    update_app_bounds!

    @logger.debug "tap x=#{x} y=#{y}"

    width = @right - @left
    height = @bottom - @top
    if @rotation == PORTRAIT
      screen_x = @left + (1.0 - y) * width
      screen_y = @top + x * height
    elsif @rotation == LANDSCAPE_FRONT_CAMERA_ON_LEFT
      screen_x = @left + x * width
      screen_y = @top + y * height
    elsif @rotation == REVERSED_PORTRAIT
      screen_x = @left + (1.0 - y) * width
      screen_y = @top + x * height
    elsif @rotation == LANDSCAPE_FRONT_CAMERA_ON_RIGHT
      screen_x = @left + (1.0 - x) * width
      screen_y = @top + (1.0 - y) * height
    else
      raise 'unexpected rotation'
    end

    @logger.debug "rotation=#{@rotation} screen_x=#{screen_x}, screen_y=#{screen_y}"
    adb_shell("input tap #{screen_x.to_i} #{screen_y.to_i}")
  end

  def connected?
    devices = `#{@adb} devices`.split("\n")[1..]
    android_ids =
      devices
      .filter { |i| i.end_with? "\tdevice" }
      .map { |i| i.split("\t").first }
      .filter { |i| @android_id.empty? || i == @android_id }
    @logger.debug "android_ids=#{android_ids.inspect}"

    found = !android_ids.empty?
    set_android_id!(android_ids.first) if found && @android_id.empty?

    found
  end

  def locked?
    dumpsys = adb_shell('dumpsys deviceidle')
    unless dumpsys =~ /mScreenLocked=(.*?)\s/
      dumpsys = adb_shell('dumpsys window')
      unless dumpsys =~ /mDreamingLockscreen=(.*?)\s/ || dumpsys =~ /mShowingLockscreen=(.*?)\s/
        raise 'Failed to check if device is locked'
      end
    end
    Regexp.last_match(1) == 'true'
  end

  def camera_blocked?
    # TODO
    false
    # adb_shell('dumpsys media.camera').include?('Device 0 is closed')
  end

  def mic_muted?
    dumpsys = adb_shell('dumpsys audio')
    dumpsys.match?(/mic mute.*=true/)
  end

  def wakeup
    adb_shell('input keyevent KEYCODE_WAKEUP')
  end

  def unlock_auto_rotate
    adb_shell('settings put system accelerometer_rotation 1')
  end

  def opencamera_running?
    dumpsys = adb_shell('dumpsys window windows')
    dumpsys.match?(/((mCurrentFocus|mHoldScreenWindow)=|(imeLayeringTarget|imeInputTarget|imeControlTarget) in display# [0-9]* )Window\{[0-9a-f]* u0 #{MAIN_ACTIVITY}/)
  end

  def run_opencamera
    already_running = `#{@adb_shell} am start -n #{MAIN_ACTIVITY} 2>>/dev/stdout`.include?('Warning: Activity not started')
    return if already_running

    @logger.debug 'waiting for phone camera initialization'
    sleep CAMERA_INITIALIZATION_TIME
  end

  def close_opencamera
    adb_shell("am force-stop #{APP_ID}")
  end

  def remove_old_opencamera_videos
    adb_shell("rm -f #{@opencamera_dir}/.pending-* #{@opencamera_dir}/*")
  end

  def open_home_screen
    adb_shell('input keyevent KEYCODE_HOME')
  end

  def set_front_camera
    @logger.debug 'set_front_camera'
    tap 0.955, 0.292
  end

  def lock_exposure
    @logger.debug 'lock_exposure'
    x =
      if @rotation == 180
        0.035 # NOTE: holy crap, just this button alone moved here in a single rotation mode
      else
        0.08
      end
    tap x, 0.927
  end

  def update_app_bounds!
    unless adb_shell('dumpsys window') =~ /mAppBounds=Rect\(([0-9]*),\s([0-9]*)\s-\s([0-9]*),\s([0-9]*)\) mMaxBounds=Rect\(([0-9]*),\s([0-9]*)\s-\s([0-9]*),\s([0-9]*)\).*mRotation=ROTATION_([0-9]*)/
      raise 'Failed to fetch display size'
    end

    @left = Regexp.last_match(1).to_i
    @top = Regexp.last_match(2).to_i
    @right = Regexp.last_match(3).to_i
    @bottom = Regexp.last_match(4).to_i

    max_left = Regexp.last_match(5).to_i
    max_top = Regexp.last_match(6).to_i
    max_right = Regexp.last_match(7).to_i
    max_bottom = Regexp.last_match(8).to_i

    @rotation = Regexp.last_match(9).to_i

    @logger.debug "device rotation=#{@rotation}, left=#{@left}, right=#{@right}, top=#{@top}, bottom=#{@bottom}, max_left=#{max_left}, max_right=#{max_right}, max_top=#{max_top}, max_bottom=#{max_bottom}"

    @left = [@left, max_left].min if @rotation == 90
    @right = [@right, max_right].max if @rotation == 270
    @top = [@top, max_top].min if @rotation == 0
    # @bottom = [@bottom, max_bottom].max if @rotation == 180
  end

  def get_brightness
    adb_shell('settings get system screen_brightness').to_i
  end

  def set_brightness(brightness)
    return unless @change_brightness

    adb_shell("settings put system screen_brightness #{brightness}").to_i
  end

  def set_night_display_auto_mode(enabled)
    was_enabled = adb_shell('settings get secure night_display_auto_mode')
    adb_shell('settings put secure night_display_activated 0')
    adb_shell("settings put secure night_display_auto_mode #{enabled}")
    was_enabled
  end

  def restore_display_settings
    set_brightness @initial_brightness
    set_night_display_auto_mode @initial_night_display_auto_mode
  end

  def get_system_info
    dumpsys = adb_shell('dumpsys battery').split("\n")
    battery_level = dumpsys.filter { |line| line.include?('level: ') }
                           .map { |line| line.gsub(/.*: /, '') }
                           .map do |value|
                             text = "#{value}%"
                             value.to_i <= 20 ? "🪫#{text}".red : "🔋#{text}"
                           end
                           .first
    battery_temperature = dumpsys.filter { |line| line.include?('temperature: ') }
                                 .map { |line| line.gsub(/.*: /, '').to_i / 10 }
                                 .map do |value|
                                   text = "#{value}°C"
                                   value >= 55 ? text.red : text
                                 end
                                 .first

    adb_shell("mkdir -p #{@opencamera_dir}")
    free_storage = parse_free_storage(adb_shell("LANG=C df -Pk #{@opencamera_dir}"))
    [battery_level, battery_temperature, free_storage]
  end

  def adb_shell(args)
    command = "#{@adb_shell} #{args}"
    @logger.debug command
    `#{command}`.gsub("\r\n", "\n")
    # @logger.debug "#{command} => #{output}"
  end

  def set_android_id!(android_id)
    @logger.debug "set_android_id #{android_id.inspect}"
    @android_id = android_id
    @adb_env = @android_id.empty? ? '' : "ANDROID_SERIAL='#{@android_id}'"
    @adb = "#{@adb_env} adb"
    @adb_shell = "#{@adb} shell --"
  end
end
