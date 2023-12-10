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

require 'process_utils'

FFMPEG = ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error']
FFMPEG_NO_OVERWRITE = ['ffmpeg', '-n', '-hide_banner', '-loglevel', 'panic']

EXTRACT_LEFT_CHANNEL_FILTER = 'pan=mono|c0=c0' # TODO: https://trac.ffmpeg.org/wiki/AudioChannelManipulation#Chooseaspecificchannel
VAD_SAMPLING_RATE = 16_000

MPV = ['mpv', '--no-config', '--really-quiet', '--no-resume-playback', '--af=scaletempo2', '--fs']

def get_duration(filename)
  command = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1',
             filename]
  `#{command.shelljoin_wrapped}`.to_f
end

def prepare_for_vad(filename)
  output_filename = "#{filename}.vad.wav"
  command = FFMPEG + [
    '-i', filename,
    '-af', EXTRACT_LEFT_CHANNEL_FILTER,
    '-ar', VAD_SAMPLING_RATE,
    '-c:a', 'pcm_s16le',
    '-vn',
    output_filename
  ]
  system "#{command.shelljoin_wrapped}"
  output_filename
end

def clamp_speed(speed)
  speed.clamp(0.5, 2.0)
end
