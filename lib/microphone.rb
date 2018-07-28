class Microphone
  ARECORD_OPTIONS = '-D usb_card -f dat'.freeze

  def initialize(_project_dir, _temp_dir, logger)
    @logger = logger
  end

  def toggle_recording; end
end
