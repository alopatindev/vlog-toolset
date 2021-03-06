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

require 'ffmpeg_utils.rb'
require 'fileutils'

def detect_voice(sound_filename, min_shot_size, min_pause_between_shots, agressiveness)
  first_segment_correction = 0.5
  start_correction = 0.1
  end_correction = 0.1

  script_filename = File.join(__dir__, 'detect_voice.py')

  sound_with_single_channel_filename = prepare_for_vad(sound_filename)
  output = `#{script_filename} #{sound_with_single_channel_filename} #{agressiveness} #{min_shot_size} #{min_pause_between_shots}`

  FileUtils.rm_f sound_with_single_channel_filename

  segments = output
             .split("\n")
             .map { |line| line.split(' ') }
             .map { |r| r.map(&:to_f) }
             .select { |r| r.length == 2 }
             .map { |start_position, end_position| [start_position - start_correction, end_position + end_correction] }

  segments
end
