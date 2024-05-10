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

require 'json'

FFMPEG = ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error']
FFMPEG_NO_OVERWRITE = ['ffmpeg', '-n', '-hide_banner', '-loglevel', 'panic']

EXTRACT_LEFT_CHANNEL_FILTER = 'pan=mono|c0=c0' # TODO: https://trac.ffmpeg.org/wiki/AudioChannelManipulation#Chooseaspecificchannel
VAD_SAMPLING_RATE = 16_000

FLAC_SAMPLING_FORMAT = 's16'

MIN_SHOT_SIZE = 1.0

MPV_COMMAND = ['mpv', '--really-quiet', '--no-resume-playback', '--af=scaletempo2', '--fs', '--speed=1',
               '--volume-max=300']

def get_duration(filename)
  command = ['ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_streams', filename]
  streams = JSON.parse(`#{command.shelljoin_wrapped}`)['streams']
  streams.map { |i| i['duration'].to_f }.min
end

def get_framerate(filename)
  fps = 'FrameRate'
  mode = 'FrameRate_Mode'
  properties = video_properties([fps, mode], filename)
  { fps: properties[fps], mode: properties[mode] }
end

def get_color_info(filename)
  standard = 'colour_primaries'
  format = 'ChromaSubsampling'
  colorspace = 'ColorSpace'
  properties = video_properties([standard, format, colorspace], filename)
  { standard: properties[standard], format: properties[format], colorspace: properties[colorspace] }
end

def video_properties(properties, filename)
  command = ['mediainfo', '--Output=JSON', filename]
  tracks = JSON.parse(`#{command.shelljoin_wrapped}`)['media']['track'].filter do |i|
    i['@type'] == 'Video' && properties.all? { |property| !i[property].nil? }
  end
  raise 'Unexpected number of video tracks' unless tracks.length == 1

  track = tracks[0]
  properties.map { |i| [i, track[i]] }.to_h
end

def get_mean_color(filename)
  command = [
    'ffmpeg',
    '-i',
    filename,
    '-vf',
    'scale=1:1,pad=1:1:0:0:color=white',
    '-pix_fmt',
    'rgb24',
    '-vframes',
    '1',
    '-f',
    'rawvideo',
    '-'
  ]

  `#{command.shelljoin_wrapped} 2>>/dev/null`
    .unpack('C*')[0..2]
    .map { |i| i.to_f / 255.0 }
end

def get_luminance(color)
  r, g, b = color
  0.2126 * r + 0.7152 * g + 0.0722 * b
end

def get_saturation(color)
  (color.max - color.min) / color.max
end

# def compute_gamma(luminance)
#  Math.log(luminance + 0.01) / Math.log(0.5)
# end

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
  # TODO: do second audio sync for individually cut fragments to avoid audio drift?
  audio_filters = [EXTRACT_LEFT_CHANNEL_FILTER]

  segments.each_with_index.map do |seg, subclip_num|
    start_position, end_position = seg
    output_filename = "#{sync_sound_filename}_#{subclip_num}.flac"

    ffmpeg_cut_args = ['-ss', start_position, '-i', sync_sound_filename, '-to', end_position - start_position,
                       '-codec', 'copy']
    ffmpeg_output_args = ['-sample_fmt', FLAC_SAMPLING_FORMAT, '-af', "#{audio_filters.join(',')}", '-acodec', 'flac']

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

def nvidia_cuda_ready?
  if (find_executable 'nvcc').nil?
    print("nvidia-cuda-toolkit is not installed\n")
    false
  elsif !File.exist?('/dev/nvidia0')
    print("nvidia module is not loaded\n")
    false
  else
    true
  end
end

def nvenc_supported?(encoder)
  command = FFMPEG + ['--help', "encoder=#{encoder}"]
  if `#{command.shelljoin_wrapped}`.include?('is not recognized')
    print("ffmpeg was built without #{encoder} support\n")
    false
  else
    nvidia_cuda_ready?
  end
end

def h264_video_codec
  if nvenc_supported?('h264_nvenc')
    'h264_nvenc -preset slow -cq 18'
  else
    'libx264 -preset ultrafast -crf 18'
  end
end

def h265_video_codec
  if nvenc_supported?('hevc_nvenc')
    # 'hevc_nvenc -preset p1 -rc vbr -cq 18 -qmin 18 -qmax 18 -b:v 0'
    'hevc_nvenc -preset p1 -cq 18 -qp 18 -b:v 0'
  else
    'libx265 -preset ultrafast -crf 18'
  end
end
