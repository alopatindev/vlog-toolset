def detect_voice(sound_filename, min_shot_size, min_pause_between_shots)
  script_filename = File.join(File.dirname(__FILE__), 'detect_voice.py')

  `#{script_filename} #{sound_filename} #{min_shot_size} #{min_pause_between_shots}`
    .split("\n")
    .map { |line| line.split(' ') }
    .map { |r| r.map(&:to_f) }
    .select { |r| r.length == 2 }
end
