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

require 'numeric'
require 'set'

class Phone
  APP_ID = 'net.sourceforge.opencamera'.freeze
  MAIN_ACTIVITY = "#{APP_ID}/#{APP_ID}.MainActivity".freeze
  POLL_WAIT_TIME = 0.3

  def initialize(temp_dir, options, logger)
    @temp_dir = temp_dir

    @change_brightness = options[:change_brightness]

    @logger = logger
    @opencamera_dir = options[:opencamera_dir]

    android_id = options[:android_id]
    @adb_env = android_id.empty? ? '' : "ANDROID_SERIAL='#{android_id}'"
    @adb = "#{@adb_env} adb"
    @adb_shell = "#{@adb} shell --"

    @clip_num_to_filename = {}
    @filenames = Set.new
    @filenames = get_new_filenames.to_set

    wakeup

    raise 'You need to unlock the screen' if locked?

    opencamera_was_active = opencamera_active?
    run_opencamera unless opencamera_was_active
    unlock_auto_rotate
    @width, @height = get_size
    @logger.debug "device width=#{@width}, height=#{@height}"
    @initial_brightness = get_brightness
    set_front_camera unless opencamera_was_active
  end

  def move_to_host(phone_filename, clip_num)
    local_filename = File.join @temp_dir, clip_num.with_leading_zeros + '.mp4'
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
    screen_x = (x * @height).to_i
    screen_y = (y * @width).to_i
    adb_shell("input tap #{screen_x} #{screen_y}")
  end

  def locked?
    dumpsys = adb_shell('dumpsys window')
    unless dumpsys =~ /mDreamingLockscreen=(.*?)\s/ || dumpsys =~ /mShowingLockscreen=(.*?)\s/
      raise 'Failed to check if device is locked'
    end

    Regexp.last_match(1) == 'true'
  end

  def wakeup
    adb_shell('input keyevent KEYCODE_WAKEUP')
  end

  def unlock_auto_rotate
    adb_shell('adb shell settings put system accelerometer_rotation 1')
  end

  def opencamera_active?
    adb_shell('dumpsys window windows').match?(/mCurrentFocus=Window\{[0-9a-f]* u0 #{MAIN_ACTIVITY}/)
  end

  def run_opencamera
    system "#{@adb_shell} am start -n #{MAIN_ACTIVITY} && sleep 3", out: File::NULL
  end

  def close_opencamera
    adb_shell('input keyevent KEYCODE_BACK')
  end

  def set_front_camera
    @logger.debug 'set_front_camera'
    tap 0.955, 0.292
  end

  def get_size
    dumpsys = adb_shell('dumpsys display')
    width, height =
      if dumpsys =~ /mDisplayWidth=([0-9]{2,}?)\n\s*mDisplayHeight=([0-9]{2,}?)\n/
        width = Regexp.last_match(1).to_i
        height = Regexp.last_match(2).to_i
        [width, height]
      elsif dumpsys =~ /deviceWidth=([0-9]{2,}?),\sdeviceHeight=([0-9]{2,}?)\}/
        width = Regexp.last_match(1).to_i
        height = Regexp.last_match(2).to_i
        [width, height].reverse
      else
        raise 'Failed to fetch display size'
      end

    if adb_shell('dumpsys window') =~ /mAppBounds=Rect\([0-9\s-]*,\s0\s-\s([0-9]*),\s[0-9\s-]*\)/
      new_height = Regexp.last_match(1).to_i
      @logger.debug "height #{height} => #{new_height}"
      height = new_height
    end

    [width, height]
  end

  def get_brightness
    adb_shell('settings get system screen_brightness').to_i
  end

  def set_brightness(brightness)
    return unless @change_brightness

    adb_shell("settings put system screen_brightness #{brightness}").to_i
  end

  def restore_brightness
    set_brightness @initial_brightness
  end

  def get_system_info
    dumpsys = adb_shell('dumpsys battery').split("\n")

    level_value = dumpsys.select { |line| line.include? 'level: ' }
                         .map { |line| line.gsub(/.*: /, '') }
                         .first
                         .to_i
    level_sign = level_value <= 20 ? '🪫' : '🔋'
    level = "#{level_sign}#{level_value}"

    temperature = dumpsys.select { |line| line.include? 'temperature: ' }
                         .map { |line| line.gsub(/.*: /, '').to_i / 10 }
                         .first

    free_storage = adb_shell("df -h #{@opencamera_dir} | tail -n1 | awk '{print $3}'").strip
    [level, temperature, free_storage]
  end

  def adb_shell(args)
    command = "#{@adb_shell} #{args}"
    @logger.debug command
    `#{command}`.gsub("\r\n", "\n")
    # @logger.debug "#{command} => #{output}"
  end
end
