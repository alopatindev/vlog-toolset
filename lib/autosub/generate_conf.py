#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import glob
import os
import sys
from autosub import *


def extract_transcripts(
    source_path,
    src_language=DEFAULT_SRC_LANGUAGE,
    api_key=None,
):
    audio_filename, audio_rate = extract_audio(source_path, rate=48000)
    regions = find_speech_regions(audio_filename)

    converter = FLACConverter(source_path=audio_filename)
    recognizer = SpeechRecognizer(language=src_language,
                                  rate=audio_rate,
                                  retries=10,
                                  api_key=GOOGLE_SPEECH_API_KEY)

    transcripts = []
    timed_subtitles = []

    try:
        if regions:
            extracted_regions = []
            for i, extracted_region in enumerate(pool.imap(converter, regions)):
                extracted_regions.append(extracted_region)

            for i, transcript in enumerate(pool.imap(recognizer, extracted_regions)):
                transcripts.append(transcript)

        timed_subtitles = [(r, t) for r, t in zip(regions, transcripts) if t]
    finally:
        os.remove(audio_filename)
    return timed_subtitles


def filename_to_clip(filename):
    basename = os.path.basename(filename)
    return int(basename.split('_')[0])


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print('Usage: %s project_dir/ language' % sys.argv[0])
        print('       where language is one of `autosub --list-language`')
        sys.exit(1)

    project_dir = sys.argv[1]
    output = project_dir + '/render.conf'
    language = sys.argv[2]

    concurrency = 32
    pool = multiprocessing.Pool(concurrency)

    video_filenames = glob.glob(project_dir + '/0*.mp4')
    video_filenames.sort()

    new_config = not os.path.isfile(output)
    if new_config:
        f = open(output, 'w')
        line = '\t'.join(['#filename', 'speed', 'start', 'end', 'text']) + '\n'
        f.write(line)
    else:
        f = open(output, 'r+')
        last_line = f.readlines()[-1]
        first_column = last_line.split('\t')[0]
        last_recorded_filename = first_column.split('#')[-1].strip()
        last_recorded_clip = filename_to_clip(last_recorded_filename)
        skip_lines = len([i for i in video_filenames if filename_to_clip(i) <= last_recorded_clip])
        video_filenames = video_filenames[skip_lines:]

    n = len(video_filenames)

    for i, filename in enumerate(video_filenames):
        num = i + 1
        progress = (num / len(video_filenames)) * 100.0
        print('processing (%d/%d) (%.1f%%) %s' % (num, n, progress, filename))
        try:
            for (start, end), t in extract_transcripts(filename, src_language=language):
                line = '\t'.join([os.path.basename(filename), '1.0', str(start), str(end), t]) + '\n'
                f.write(line)
        except Exception as e:
            print('failed to process ' + filename)
            print(e)

    f.close()

    print('terminating the pool')
    pool.terminate()
    pool.join()

    print('done')
    print(output)
