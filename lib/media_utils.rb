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

MIN_SHOT_SIZE = 1.0

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

def get_volume_adjustment(filename)
  command = ['sox', filename, '--null', 'stat']
  `#{command.shelljoin_wrapped} 2>&1`
    .split("\n")
    .map { |i| i.split('Volume adjustment:')[1] }
    .filter { |i| !i.nil? }
    .map { |i| i.to_f }
    .first
end

def synchronize_sound(camera_filename, sound_filename)
  output_filename = "#{sound_filename}.sync.wav"

  command = ['sync-audio-tracks.sh', sound_filename, camera_filename, output_filename]
  sync_offset = `#{command.shelljoin_wrapped}`
                .split("\n")
                .filter { |line| line.start_with? 'offset is' }
                .map { |line| line.sub(/^offset is /, '').sub(/ seconds$/, '').to_f }
                .first || 0.0

  [sync_offset, output_filename]
end

def process_sound(sync_sound_filename, segments)
  audio_filters = [EXTRACT_LEFT_CHANNEL_FILTER]

  segments.each_with_index.map do |seg, subclip_num|
    start_position, end_position = seg
    output_filename = "#{sync_sound_filename}_#{subclip_num}.flac"

    ffmpeg_cut_args = ['-ss', start_position, '-i', sync_sound_filename, '-to', end_position - start_position,
                       '-codec', 'copy']
    ffmpeg_output_args = ['-af', "#{audio_filters.join(',')}", '-acodec', 'flac']

    temp_filename = "#{sync_sound_filename}_#{subclip_num}.cut.wav"

    command = FFMPEG + ffmpeg_cut_args + [temp_filename]
    # @logger.debug command
    system command.shelljoin_wrapped, out: File::NULL

    command = FFMPEG + ['-i', temp_filename] + ffmpeg_output_args + [output_filename]
    # @logger.debug command
    system command.shelljoin_wrapped, out: File::NULL

    FileUtils.rm_f temp_filename

    raise "Failed to process #{output_filename}" unless File.file?(output_filename)

    output_filename
  end
end

def process_video(camera_filename, segments)
  segments.each_with_index.map do |seg, subclip_num|
    start_position, end_position = seg
    output_filename = "#{camera_filename}_#{subclip_num}.processed.mp4"
    temp_filename = "#{camera_filename}_#{subclip_num}.cut.mp4"

    command = FFMPEG + [
      '-ss', start_position,
      '-i', camera_filename,
      '-to', end_position - start_position,
      '-an',
      '-codec', 'copy',
      temp_filename
    ]
    system command.shelljoin_wrapped
    FileUtils.mv temp_filename, output_filename, force: true

    output_filename
  end
end

def merge_files(processed_sound_filenames, processed_video_filenames, clip_num, rotation, project_dir)
  processed_sound_filenames
    .zip(processed_video_filenames)
    .each_with_index
    .map do |f, subclip_num|
    # @logger.debug "save_clip: merging files #{f} #{subclip_num}"

    processed_sound_filename, processed_video_filename = f
    output_filename = get_output_filename clip_num, subclip_num, rotation, project_dir
    # @logger.debug "save_clip: output_filename=#{output_filename}"
    command = FFMPEG + ['-i', processed_sound_filename, '-an', '-i', processed_video_filename, '-shortest',
                        '-strict', '-2', '-codec', 'copy', '-movflags', 'faststart', output_filename]
    # @logger.debug command
    system command.shelljoin_wrapped

    output_filename
  end
end

def get_output_filename(clip_num, subclip_num, rotation, project_dir)
  prefix = File.join project_dir, "#{clip_num.with_leading_zeros}_#{subclip_num.with_leading_zeros}"
  if rotation.nil?
    Dir[prefix + '*'].first
  else
    "#{prefix}_#{rotation}.mp4"
  end
end
