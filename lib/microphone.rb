require 'io/console'

class Microphone
  attr_reader :sound_filename

  def initialize(temp_dir, arecord_args, logger)
    @logger = logger
    @temp_dir = temp_dir

    @arecord_command = "arecord --quiet --nonblock #{arecord_args}"
    @arecord_pipe = nil
  end

  def toggle_recording(sound_num)
    if @arecord_pipe.nil?
      @sound_filename = File.join @temp_dir, format('%016d.wav', sound_num)
      @arecord_pipe = IO.popen "#{@arecord_command} #{sound_filename}"
      @logger.debug "recording #{sound_filename}"
    else
      @logger.debug "kill #{@arecord_pipe.pid}"
      Process.kill 'SIGTERM', @arecord_pipe.pid
      @arecord_pipe.close
      @arecord_pipe = nil
    end
  end
end
