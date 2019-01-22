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
