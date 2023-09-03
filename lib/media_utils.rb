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

require 'shellwords_utils'

FFMPEG = ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error']
FFMPEG_NO_OVERWRITE = ['ffmpeg', '-n', '-hide_banner', '-loglevel', 'panic']

MPV = ['mpv', '--really-quiet', '--no-resume-playback']

def get_duration(filename)
  command = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1',
             filename]
  `#{command.shelljoin_wrapped}`.to_f
end

def prepare_for_vad(filename)
  output_filename = "#{filename}.vad.wav"
  command = FFMPEG + ['-i', filename, '-af', 'pan=mono|c0=c0', '-ar', 48_000, '-vn', output_filename]
  system "#{command.shelljoin_wrapped}"
  output_filename
end

def clamp_speed(speed)
  speed.clamp(0.5, 2.0)
end
