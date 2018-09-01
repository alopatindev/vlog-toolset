#!/usr/bin/env python3

# this code is based on https://github.com/hcmlab/vadnet/blob/master/vad_extract.py
# which was made by Johannes Wagner <wagner@hcm-lab.de>
# Copyright (C) University of Augsburg, Lab for Human Centered Multimedia

import os
import subprocess
import sys
import json
import glob

import tensorflow as tf
import numpy as np
import librosa as lr


def audio_from_file(path, sr=None, ext=''):
    return lr.load('{}{}'.format(path, ext), sr=sr, mono=True, offset=0.0, duration=None, dtype=np.float32, res_type='kaiser_best')


def audio_to_frames(x, n_frame, n_step=None):
    if n_step is None:
        n_step = n_frame

    if len(x.shape) == 1:
        x.shape = (-1,1)

    n_overlap = n_frame - n_step
    n_frames = (x.shape[0] - n_overlap) // n_step
    n_keep = n_frames * n_step + n_overlap

    strides = list(x.strides)
    strides[0] = strides[1] * n_step

    return np.lib.stride_tricks.as_strided(x[0:n_keep,:], (n_frames,n_frame), strides)


def to_shots(positions, min_pause_between_shots):
    n = len(positions)
    result = []
    if n > 0:
        start = positions[0]
        prev = positions[0]
        for i, pos in enumerate(positions[1:]):
            is_successor = pos - prev == 1
            is_first = i == 0
            is_last = i + 1 == n - 1
            is_new_shot = pos - prev >= min_pause_between_shots
            if not is_successor and (is_first or is_new_shot):
                result.append((start, prev))
                start = pos
            elif is_last:
                result.append((start, pos))
            prev = pos
    return result


def extract_voice(path, wav_file, n_batch, min_shot_size, min_pause_between_shots):
    if os.path.isdir(path):
        candidates = glob.glob(os.path.join(path, 'model.ckpt-*.meta'))
        if candidates:
            candidates.sort()
            checkpoint_path, _ = os.path.splitext(candidates[-1])
    else:
        checkpoint_path = path

    if not all([os.path.exists(checkpoint_path + x) for x in ['.data-00000-of-00001', '.index', '.meta']]):
        print('ERROR: could not load model')
        raise FileNotFoundError

    vocabulary_path = checkpoint_path + '.json'
    if not os.path.exists(vocabulary_path):
        vocabulary_path = os.path.join(os.path.dirname(checkpoint_path), 'vocab.json')
    if not os.path.exists(vocabulary_path):
        print('ERROR: could not load vocabulary')
        raise FileNotFoundError

    with open(vocabulary_path, 'r') as fp:
        vocab = json.load(fp)

    graph = tf.Graph()

    with graph.as_default():
        saver = tf.train.import_meta_graph(checkpoint_path + '.meta')

        x = graph.get_tensor_by_name(vocab['x'])
        y = graph.get_tensor_by_name(vocab['y'])
        init = graph.get_operation_by_name(vocab['init'])
        logits = graph.get_tensor_by_name(vocab['logits'])
        ph_n_shuffle = graph.get_tensor_by_name(vocab['n_shuffle'])
        ph_n_repeat = graph.get_tensor_by_name(vocab['n_repeat'])
        ph_n_batch = graph.get_tensor_by_name(vocab['n_batch'])
        sr = vocab['sample_rate']

        with tf.Session() as sess:
            saver.restore(sess, checkpoint_path)
            sound, _ = audio_from_file(wav_file, sr=sr)
            input = audio_to_frames(sound, x.shape[1])
            labels = np.zeros((input.shape[0],), dtype=np.int32)
            sess.run(init, feed_dict = { x : input, y : labels, ph_n_shuffle : 1, ph_n_repeat : 1, ph_n_batch : n_batch })
            count = 0
            n_total = input.shape[0]
            while True:
                try:
                    output = sess.run(logits)
                    labels[count:count+output.shape[0]] = np.argmax(output, axis=1)
                    count += output.shape[0]
                except tf.errors.OutOfRangeError:
                    break

            to_tuple = lambda i: (float(i[0]), float(i[1]))
            is_large_enough = lambda i: i[1] - i[0] >= min_shot_size
            voice = 1
            shots = (to_tuple(i) for i in to_shots(np.argwhere(labels == voice).reshape(-1), min_pause_between_shots) if is_large_enough(to_tuple(i)))
            return shots


if __name__ == '__main__':
    wav_file = sys.argv[1]
    min_shot_size = float(sys.argv[2])
    min_pause_between_shots = float(sys.argv[3])

    model = 'lib/voice/vadnet/models/vad'
    n_batch = 8

    os.environ['TF_CPP_MIN_LOG_LEVEL'] = '3'
    for start, end in extract_voice(model, wav_file, n_batch, min_shot_size, min_pause_between_shots):
        print(start, end)
