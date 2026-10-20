#!/usr/bin/env python3
"""Read-only level inspection of integer PCM WAV; no external dependencies.
No automatic trimming, normalization, channel mixing or sound-quality verdict.
"""
import argparse
import json
import math
from pathlib import Path
import wave


def db(value):
    return round(20 * math.log10(value), 2) if value > 0 else None


def inspect(path):
    with wave.open(str(path), 'rb') as wav:
        channels, width, rate, frames = (wav.getnchannels(), wav.getsampwidth(),
                                         wav.getframerate(), wav.getnframes())
        if width not in (1, 2, 3, 4) or channels < 1 or rate < 1:
            raise ValueError('Unsupported PCM format')
        scale = 2 ** (width * 8 - 1)
        peaks = [0.0] * channels
        squares = [0.0] * channels
        sums = [0.0] * channels
        rails = [0] * channels
        counts = [0] * channels
        while data := wav.readframes(16384):
            if len(data) % (channels * width):
                raise ValueError('Truncated PCM frame')
            for offset in range(0, len(data), width):
                channel = (offset // width) % channels
                value = (data[offset] - 128 if width == 1 else
                         int.from_bytes(data[offset:offset + width], 'little', signed=True))
                normalized = value / scale
                peaks[channel] = max(peaks[channel], abs(normalized))
                squares[channel] += normalized * normalized
                sums[channel] += normalized
                rails[channel] += int(value == -scale or value == scale - 1)
                counts[channel] += 1
        if any(count != frames for count in counts):
            raise ValueError('WAV header frame count differs from available audio')
        return dict(file=str(path), sample_rate=rate, bits=width * 8,
                    duration_seconds=round(frames / rate, 3), channels=channels,
                    levels=[dict(channel=c + 1, peak_dbfs=db(peaks[c]),
                                 rms_dbfs=db(math.sqrt(squares[c] / max(counts[c], 1))),
                                 dc_mean=round(sums[c] / max(counts[c], 1), 7),
                                 full_scale_samples=rails[c]) for c in range(channels)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not args.directory.is_dir():
        parser.error('Input directory does not exist')
    results = []
    for path in sorted(args.directory.rglob('*')):
        if path.is_file() and path.suffix.lower() == '.wav':
            try:
                results.append(inspect(path))
            except (wave.Error, EOFError, OSError, ValueError) as exc:
                results.append(dict(file=str(path), error=str(exc)))
    report = dict(note='Integer PCM only. null dB means silence. Full-scale samples flag possible clipping; no automatic quality verdict.',
                  files=results)
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + '\n')
    print(text)


if __name__ == '__main__':
    main()
