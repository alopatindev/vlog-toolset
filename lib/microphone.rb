require 'numeric.rb'

require 'fileutils'
require 'io/console'

class Microphone
  def initialize(temp_dir, arecord_args, logger)
    @logger = logger
    @temp_dir = temp_dir

    @arecord_command = "exec arecord --quiet --nonblock #{arecord_args}"
    @arecord_pipe = nil
  end

  def toggle_recording(clip_num)
    sound_filename = unchecked_filename(clip_num)
    if @arecord_pipe.nil?
      command = "#{@arecord_command} #{sound_filename} >/dev/null 2>&1"
      @logger.debug command
      @arecord_pipe = IO.popen command
    else
      @logger.debug "kill #{@arecord_pipe.pid} clip_num=#{clip_num}"
      Process.kill 'SIGTERM', @arecord_pipe.pid
      @logger.debug "arecord says: '#{@arecord_pipe.read}'"
      @arecord_pipe.close
      @arecord_pipe = nil
    end
  end

  def delete_clip(clip_num)
    sound_filename = filename(clip_num)
    if sound_filename.nil? || !(File.file? sound_filename)
      false
    else
      @logger.debug "mic.delete_clip #{clip_num}: #{sound_filename}"
      FileUtils.rm_f sound_filename
      true
    end
  end

  def filename(clip_num)
    result = unchecked_filename(clip_num)
    File.file?(result) ? result : nil
  end

  def unchecked_filename(clip_num)
    File.join @temp_dir, clip_num.with_leading_zeros + '.wav'
  end
end
