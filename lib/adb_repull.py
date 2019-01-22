#!/usr/bin/env python3

# adb-repull.py
#
# ADB pull emulation for machines with problematic USB ports/cables.
# It continuously retries and resumes download when disconnection happens.
#
# Copyright (c) 2018 Alexander Lopatin
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

import errno
import math
import os
import subprocess
import sys
import time


BUFFER_SIZE = 8192
SLEEP_TIMEOUT = 5


def run_with_retries(function):
    while True:
        try:
            return function()
        except ConnectionError as e:
            print(e)
            print('Retrying after {} seconds'.format(SLEEP_TIMEOUT))
            time.sleep(SLEEP_TIMEOUT)


def size_to_blocks(size):
    return math.ceil(size / BUFFER_SIZE)


def get_size(remote_file):
    print('Getting size of {}'.format(remote_file))
    with subprocess.Popen(['adb', 'shell', 'ls', '-l', remote_file], stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        out, err = process.communicate()

        if len(err) > 0:
            raise ConnectionError('Disconnected')

        numbers = [i for i in out.decode('utf-8').split(' ') if i.isdigit()]
        if len(numbers) > 0:
            return int(numbers[0])
        else:
            raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), remote_file)


def is_execout_supported():
    print('Checking if exec-out is supported')
    with subprocess.Popen(['adb', 'exec-out', 'echo'], stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        out, err = process.communicate()

        if len(err) > 0 and err.decode('utf-8').strip() != 'error: closed':
            raise ConnectionError('Disconnected')

        result = process.returncode == 0
        print('Yes' if result else 'No')
        return result


def get_size_with_retries(remote_file):
    return run_with_retries(lambda: get_size(remote_file))


def is_execout_supported_with_retries():
    return run_with_retries(is_execout_supported)


def update_progress(remote_file, current_block, last_block, speed):
    if current_block % 1000 == 0 or current_block == last_block:
        progress = (current_block / last_block) * 100.0
        speed_in_mib = speed / (1024 * 1024)
        print('Downloading {} {:.1f}% ({:.1f} MiB/s)'.format(remote_file, progress, speed_in_mib))


def pull(remote_file, local_file, remote_size, execout, output):
    print('Downloading {}'.format(remote_file))

    last_block = size_to_blocks(remote_size)
    local_size = os.path.getsize(local_file)
    current_block = size_to_blocks(local_size)

    time_elapsed = 0
    bytes_downloaded = 0

    dd_command = "dd if={} bs={} skip={} 2>>/dev/null".format(remote_file, BUFFER_SIZE, current_block)
    command = ['adb', 'exec-out', dd_command] if execout else ['adb', 'shell', 'busybox stty raw ; {}'.format(dd_command)]

    with subprocess.Popen(command, stdout=subprocess.PIPE) as process:
        while current_block < last_block:
            time_start = time.time()

            current_block += 1
            expected_buffer_size = remote_size - local_size if current_block == last_block else BUFFER_SIZE

            buffer = process.stdout.read(expected_buffer_size)
            buffer_size = len(buffer)

            if buffer_size != expected_buffer_size:
                raise ConnectionError('Wrong buffer size {}. Disconnected'.format(buffer_size))

            output.write(buffer)
            local_size += buffer_size

            time_end = time.time()
            time_elapsed += time_end - time_start

            bytes_downloaded += buffer_size
            speed = bytes_downloaded / time_elapsed
            update_progress(remote_file, current_block, last_block, speed)
        print('Done')


def pull_with_retries(remote_file, local_file):
    remote_size = get_size_with_retries(remote_file)
    execout = is_execout_supported_with_retries()

    with open(local_file, 'a+b') as output:
        output.seek(os.SEEK_END)
        run_with_retries(lambda: pull(remote_file, local_file, remote_size, execout, output))


def main(argv):
    if len(argv) < 2:
        print('Usage: %s /mnt/sdcard/remote.bin [local.bin]' % argv[0])
    else:
        try:
            if sys.platform != 'linux':
                raise OSError('Unsupported platform')
            remote_file = argv[1]
            local_file = os.path.basename(remote_file) if len(argv) < 3 else argv[2]
            pull_with_retries(remote_file, local_file)
        except OSError as e:
            print(e)


main(sys.argv)
