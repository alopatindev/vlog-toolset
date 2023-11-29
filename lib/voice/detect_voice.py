#!/usr/bin/env python3

import os
import sys
import torch

USE_ONNX = True
USAGE = 'Usage: %s <path to wav file> <sampling rate> \
<aggressiveness> <min shot size> \
<min pause between shots> <speech padding>\n'


def main(args):
    if len(args) != 7:
        sys.stderr.write(USAGE % args[0])
        sys.exit(1)

    sound_filename = args[1]
    sampling_rate = int(args[2])
    aggressiveness = float(args[3])
    min_shot_size = float(args[4])
    min_pause_between_shots = float(args[5])
    speech_padding = float(args[6])

    available_threads = max(torch.get_num_threads(), os.cpu_count())
    torch.set_num_threads(available_threads)

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
        speech_pad_ms=(speech_padding * 1000),
        return_seconds=True,
        visualize_probs=False,
    )

    for i in speech_timestamps:
        print(i['start'], i['end'])


if __name__ == '__main__':
    main(sys.argv)
