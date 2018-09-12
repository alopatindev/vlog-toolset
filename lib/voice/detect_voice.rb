def detect_voice_with_vadnet(sound_filename, _duration, min_shot_size, min_pause_between_shots)
  start_correction = 0.5
  end_correction = 1.5

  script_filename = File.join(File.dirname(__FILE__), 'detect_voice.py')

  `#{script_filename} #{sound_filename} #{min_shot_size} #{min_pause_between_shots}`
    .split("\n")
    .map { |line| line.split(' ') }
    .map { |r| r.map(&:to_f) }
    .select { |r| r.length == 2 }
    .map { |start_position, end_position| [start_position - start_correction, end_position + end_correction] }
end

def detect_voice_with_ffmpeg(sound_filename, duration, min_shot_size, min_pause_between_shots, silence_threshold_db = nil)
  start_correction = 0.2
  end_correction = 0.5

  if silence_threshold_db.nil?
    silence_threshold_db = compute_silence_threshold sound_filename, duration
  end

  pauses = `ffmpeg -i #{sound_filename} -af silencedetect=n=#{silence_threshold_db}dB:d=#{min_pause_between_shots} -f null - 2>> /dev/stdout`
           .split("\n")
           .select { |line| line.match(/silencedetect.*silence_(start|end)/) }
           .map { |line| line.sub(/.*silence_(start|end): /, '') }
           .map { |line| line.sub(/ \| silence_duration: [0-9.]*/, '') }
           .map(&:to_f)
           .map { |position| [0.0, position].max }

  pauses.pop if pauses.length.odd?
  noise = [0.0] + pauses + [duration]

  noise
    .each_slice(2)
    .map { |start_position, end_position| [start_position - start_correction, end_position + end_correction] }
    .select { |start_position, end_position| end_position - start_position >= min_shot_size }
end

def compute_silence_threshold(sound_filename, duration)
  trim_duration = 0.2
  end_position = duration - trim_duration * 2.0
  volume_levels = `ffmpeg -ss #{trim_duration} -i #{sound_filename} -to #{end_position} \
									 			  -filter:a volumedetect -f null - 2>> /dev/stdout`
                  .split("\n")
                  .select { |line| line.match(/(mean|max)_volume/) }
                  .map { |line| line.sub(/.*(mean|max)_volume: /, '').sub(/ dB$/, '').to_f }
  if volume_levels.nil? || (volume_levels.length != 2)
    -40.0
  else
    volume_levels.sum * 0.5
  end
end
