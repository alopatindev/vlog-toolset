require 'fileutils'
require 'io/console'

class Microphone
  attr_reader :sound_filename

  def initialize(temp_dir, arecord_args, logger)
    @logger = logger
    @temp_dir = temp_dir

    @arecord_command = "arecord --quiet --nonblock #{arecord_args}"
    @arecord_pipe = nil
  end

  def toggle_recording(sound_filename)
    if @arecord_pipe.nil?
      @sound_filename = sound_filename
      command = "exec #{@arecord_command} #{@sound_filename} >/dev/null 2>&1"
      @logger.debug "running #{command}"
      @arecord_pipe = IO.popen command
    else
      @logger.debug "kill #{@arecord_pipe.pid}"
      Process.kill 'SIGTERM', @arecord_pipe.pid
      @logger.debug "arecord says: '#{@arecord_pipe.read}'"
      @arecord_pipe.close
      @arecord_pipe = nil
    end
  end

  def delete_clip
    unless @sound_filename.nil?
      @logger.debug "removing #{@sound_filename}"
      FileUtils.rm_f @sound_filename
    end
  end
end
