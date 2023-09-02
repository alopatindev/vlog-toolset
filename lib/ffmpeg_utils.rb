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

FFMPEG = 'ffmpeg -y -hide_banner -loglevel error '.freeze
# FFMPEG_NO_OVERWRITE = 'ffmpeg -n -hide_banner -loglevel panic'.freeze
FFMPEG_NO_OVERWRITE = 'ffmpeg -n -hide_banner -loglevel error'.freeze # TODO

def get_duration(filename)
  `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{filename}`.to_f
end

def prepare_for_vad(filename)
  output_filename = "#{filename}.vad.wav"
  system "#{FFMPEG} -i #{filename} -af 'pan=mono|c0=c0' -ar 48000 -vn #{output_filename}"
  output_filename
end

def clamp_speed(speed)
  speed.clamp(0.5, 2.0)
end
