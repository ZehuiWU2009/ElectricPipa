"""Sympathetic ringing of the three strings that were not plucked.

A plucked string drives the bridge; the bridge drives every other open string
at its own pitch. Those voices are 12 to 29 dB below the plucked one, but they
are the difference between a box that makes a note and an instrument that is
still ringing after the note. The Swift engine models each of them as a
damped sine, excited by a pluck on any other string and fed through the same
body filter as the direct voice.

The kernel here is the fitting-side twin of the Swift implementation. The
direct string is rendered by the ordinary kernel; the ringers are rendered
separately because the body filter is linear, so filtering the sum is exactly
the same as summing the filtered parts. That keeps the fit fast without
changing what it measures.
"""
import math
import numpy as np
from numba import njit

from fast_kernel import biquad_coeff, low_shelf_coeff, render_at, DEFAULT_PEAKS, DEFAULT_SHELF
from pipa_kernel import midi_to_freq, OPEN_MIDI

# Index convention: 0 = Chan (110 Hz), 1 = Lao, 2 = Zhong, 3 = Zi (220 Hz).
PAIRS = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]


def pair_index(i, j):
    a, b = min(i, j), max(i, j)
    return PAIRS.index((a, b))


@njit(cache=True)
def _ringers(plucked, freqs, decays, coupling, velocity, n, sr, shelf_b, peaks_b, attack_s):
    """Render the three undamped strings driven by one pluck."""
    out = np.zeros(n, dtype=np.float64)
    two_pi = 2.0 * math.pi
    for j in range(4):
        if j == plucked:
            continue
        c = coupling[plucked][j] * velocity
        if c <= 1e-10:
            continue
        w = two_pi * max(freqs[j], 20.0) / sr
        dec = math.exp(-1.0 / (max(decays[j], 0.05) * sr))
        atk = 1.0 - math.exp(-1.0 / (max(attack_s, 0.001) * sr))
        target = c
        level = 0.0
        phase = 0.0
        sz1 = 0.0
        sz2 = 0.0
        z1 = np.zeros(5, dtype=np.float64)
        z2 = np.zeros(5, dtype=np.float64)
        sb0, sb1, sb2, sa1, sa2 = shelf_b
        for k in range(n):
            target *= dec
            level += (target - level) * atk
            v = level * math.sin(phase)
            phase += w
            if phase > two_pi:
                phase -= two_pi
            ys = sb0 * v + sz1
            sz1 = sb1 * v - sa1 * ys + sz2
            sz2 = sb2 * v - sa2 * ys
            v = ys
            for m in range(5):
                b0, b1, b2, a1, a2 = peaks_b[m]
                y = b0 * v + z1[m]
                z1[m] = b1 * v - a1 * y + z2[m]
                z2[m] = b2 * v - a2 * y
                v = y
            out[k] += v * 0.5
    return out


def render_with_sympathy(plucked, strings, body, coupling, n, sr=48000.0,
                         velocity=0.9, attack_s=0.03, direct=None):
    """Full voice: one plucked string plus the ring of the other three."""
    peaks = body[0]
    shelf = body[1]
    if direct is None:
        s = strings[plucked]
        direct = render_at(midi_to_freq(OPEN_MIDI[plucked]), s[0], s[1], s[2],
                           peaks=peaks, n=n, sr=sr, shelf=shelf,
                           comb_depth=s[3], velocity=velocity)
    pk = tuple(biquad_coeff(*p, sr=sr) for p in peaks)
    sb = low_shelf_coeff(*shelf, sr=sr)
    freqs = [midi_to_freq(m) for m in OPEN_MIDI]
    decays = [s[1] for s in strings]
    return np.asarray(direct, dtype=np.float64) + _ringers(
        plucked, freqs, decays, coupling, velocity, n, sr, sb, pk, attack_s)
