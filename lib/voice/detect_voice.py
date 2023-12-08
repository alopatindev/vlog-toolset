#!/usr/bin/env python3

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
