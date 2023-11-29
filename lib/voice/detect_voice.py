#!/usr/bin/env python3

# TODO: pip install --user --break-system-packages onnxruntime torchaudio
# TODO: update readme, new VAD is used

import contextlib
import os
import sys
import torch
import wave


def get_sample_rate(path):
    # TODO: anything cheaper, without reading entire file?
    with contextlib.closing(wave.open(path, 'rb')) as wf:
        sample_rate = wf.getframerate()
        assert sample_rate in (8000, 16000, 32000, 48000)
        return sample_rate


def main(args):
    if len(args) != 6:
        sys.stderr.write('Usage: %s <path to wav file> <aggressiveness> <min_shot_size> <min_pause_between_shots> <speech_pad>\n' % args[0])
        sys.exit(1)

    sound_filename = args[1]
    aggressiveness = float(args[2])
    min_shot_size = float(args[3])
    min_pause_between_shots = float(args[4])
    speech_pad = float(args[5])

    available_threads = max(torch.get_num_threads(), os.cpu_count())
    torch.set_num_threads(available_threads)

    sampling_rate = get_sample_rate(sound_filename)

    USE_ONNX = True
    model, utils = torch.hub.load(repo_or_dir='snakers4/silero-vad',
                                  model='silero_vad',
                                  force_reload=False,
                                  onnx=USE_ONNX)

    (get_speech_timestamps,
     save_audio,
     read_audio,
     VADIterator,
     collect_chunks) = utils

    audio = read_audio(sound_filename, sampling_rate=sampling_rate)
    speech_timestamps = get_speech_timestamps(
        audio,
        model,
        threshold=aggressiveness,
        sampling_rate=sampling_rate,
        min_speech_duration_ms=(min_shot_size * 1000),
        max_speech_duration_s=float('inf'),
        min_silence_duration_ms=(min_pause_between_shots * 1000),
        window_size_samples=512,
        speech_pad_ms=(speech_pad * 1000),
        return_seconds=True,
        visualize_probs=False,
    )

    for i in speech_timestamps:
        print(i['start'], i['end'])


if __name__ == '__main__':
    main(sys.argv)
