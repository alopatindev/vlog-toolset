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
require 'shellwords_utils'

require 'fileutils'
require 'lru_redux'

# TODO: rename to Mic
# TODO: handle temporary USB connection failure

class Microphone
  CONNECTED_TTL_SECS = 15

  def initialize(temp_dir, arecord_args, logger)
    @logger = logger
    @temp_dir = temp_dir

    @arecord_command = ['exec', 'arecord', '--quiet', '--nonblock'] + arecord_args.shellsplit
    @arecord_pipe = nil

    @connected_cache = LruRedux::TTL::Cache.new(1, CONNECTED_TTL_SECS)

    raise 'Mic is not connected' unless connected?
  end

  def toggle_recording(clip_num)
    sound_filename = unchecked_filename(clip_num)
    if @arecord_pipe.nil?
      command = @arecord_command + [sound_filename]
      @logger.debug command
      @arecord_pipe = IO.popen "#{command.shelljoin_wrapped} >/dev/null 2>&1"
    else
      @logger.debug "kill #{@arecord_pipe.pid} clip_num=#{clip_num}"
      kill_process(@arecord_pipe.pid)
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
      FileUtils.rm_f(sound_filename)
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

  def recording?
    !@arecord_pipe.nil? && !@arecord_pipe.closed? && !process_running?(@arecord_pipe.pid)
  end

  def connected?
    if recording?
      true
    elsif @connected_cache.key?(:connected)
      true
    else
      @logger.debug 'connection state expired'
      command = @arecord_command + [
        '--duration=1',
        '--test-nowait',
        '--quiet',
        '/dev/null'
      ]
      system("#{command.shelljoin_wrapped} 2>>/dev/null")

      is_connected = $?.exitstatus == 0
      @connected_cache[:connected] = true if is_connected
      @logger.debug "is_connected=#{is_connected}"

      is_connected
    end
  end

  def force_invalidate_connection
    @connected_cache.delete(:connected)
  end
end

# TODO: move to process_utils.rb

def process_running?(pid)
  Process.waitpid(pid, Process::WNOHANG).nil?
rescue Errno::ECHILD
  false
end

def kill_process(pid)
  Process.kill 'SIGTERM', pid
rescue Errno::ESRCH
end
