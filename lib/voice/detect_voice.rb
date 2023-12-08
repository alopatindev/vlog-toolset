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

require 'media_utils'
require 'shellwords_utils'

require 'fileutils'

def detect_voice(sound_filename, min_shot_size, min_pause_between_shots, agressiveness)
  first_segment_correction = 0.5
  speech_pad = 0.1

  script_filename = File.join(__dir__, 'detect_voice.py')

  sound_with_single_channel_filename = prepare_for_vad(sound_filename)
  command = [script_filename, sound_with_single_channel_filename, VAD_SAMPLING_RATE, agressiveness, min_shot_size,
             min_pause_between_shots, speech_pad]
  output = `#{command.shelljoin_wrapped} 2>>/dev/null`

  raise "#{command} failed" if $?.exitstatus != 0

  FileUtils.rm_f sound_with_single_channel_filename

  output
    .split("\n")
    .map { |line| line.split(' ') }
    .map { |r| r.map(&:to_f) }
    .select { |r| r.length == 2 }
end
