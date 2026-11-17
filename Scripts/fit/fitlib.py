"""Measurement utilities shared by the parameter fits.

The first attempt at fitting compared band-averaged dB levels. That metric is
dominated by whatever sits in the band that the model cannot produce at all:
the sympathetic ring of the other open strings (a 220 Hz string cannot radiate
110 Hz) and the slow drift of the room floor. The optimiser answered by
inventing a 112 Hz body resonance with 22 dB of gain, i.e. it fitted the room,
not the instrument.

Everything here therefore works on the harmonic series of the plucked string
only: a narrow window around each k*f0 is peak-picked, and the resulting
amplitudes are compared after normalising to the strongest harmonic. That
measure is blind to scale, to the noise between harmonics, and to anything
standing below the fundamental.
"""
import wave
import numpy as np
from scipy import signal

SR = 48000
RAW = '/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/raw'


def load_wav(path):
    w = wave.open(path, 'rb')
    sr = w.getframerate()
    n = w.getnframes()
    raw = w.readframes(n)
    w.close()
    a = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 2, 3)[:, 0, :]
    x = (a[:, 0].astype(np.int32)
         | (a[:, 1].astype(np.int32) << 8)
         | (a[:, 2].astype(np.int32) << 16))
    x = np.where(x & 0x800000, x - 0x1000000, x).astype(np.float64) / 8388608.0
    return x, sr


def onset_of(x, sr, search_from=0.0):
    """First attack in x. Backs off from the threshold crossing so the very
    start of the transient is kept: a 5% threshold lands a few ms late and that
    is enough to bias every decay measurement."""
    hop = int(0.002 * sr)
    env = np.array([np.sqrt(np.mean(x[i:i + hop] ** 2))
                    for i in range(0, len(x) - hop, hop)])
    peak = env.max()
    # first sample above 2% of peak
    idx = int(np.argmax(env > 0.02 * peak))
    # walk back to where it was quiet
    while idx > 0 and env[idx] > 0.005 * peak:
        idx -= 1
    return max(0.0, search_from + idx * hop / sr - 0.005)


def pluck(y, sr, onset, dur):
    """Slice one pluck, aligned so sample 0 is the attack."""
    a = int(onset * sr)
    seg = y[a:a + int(dur * sr)].copy()
    return seg / max(np.max(np.abs(seg)), 1e-12)


def harmonic_table(y, sr, f0, kmax=14, win=(0.10, 1.60)):
    """Amplitude of each harmonic, in dB relative to the strongest one.

    Returns (rel_db, abs_db, k_list). Harmonics above Nyquist*0.9 or that fall
    outside the analysis window are dropped."""
    a = int(win[0] * sr)
    b = min(int(win[1] * sr), len(y))
    seg = y[a:b] * np.hanning(b - a)
    nfft = 1 << int(np.ceil(np.log2(max(len(seg), 4096)))) + 1
    X = np.abs(np.fft.rfft(seg, nfft))
    f = np.fft.rfftfreq(nfft, 1.0 / sr)
    abs_db, ks = [], []
    for k in range(1, kmax + 1):
        ft = k * f0
        if ft > 0.45 * sr:
            break
        m = (f >= ft * 0.975) & (f <= ft * 1.025)
        if not m.any():
            continue
        abs_db.append(20 * np.log10(X[m].max() + 1e-20))
        ks.append(k)
    abs_db = np.array(abs_db)
    rel_db = abs_db - abs_db.max()
    return rel_db, abs_db, np.array(ks)


def envelope_db(y, sr, hop_s=0.02):
    hop = int(hop_s * sr)
    n = len(y) // hop
    e = np.array([np.sqrt(np.mean(y[i * hop:(i + 1) * hop] ** 2))
                  for i in range(n)])
    return 20 * np.log10(e + 1e-12)


def harmonic_decay(y, sr, f0, kmax=10, hop_s=0.01, win_s=0.17, floor_db=-75.0):
    """Decay rate in dB/s for three harmonic groups, tracked with a single STFT.

    Grouping by harmonic rather than by fixed octave band matters: a band
    average mixes neighbouring harmonics whose decay rates differ a lot, and it
    also picks up whatever else lives in the band. Groups: low k1-2, mid k3-5,
    high k6-9.
    """
    nperseg = int(win_s * sr)
    hop = int(hop_s * sr)
    f, t, Z = signal.stft(y, sr, nperseg=nperseg, noverlap=nperseg - hop)
    mag = np.abs(Z)
    groups = {'low': range(1, 3), 'mid': range(3, 6), 'high': range(6, 10)}
    out = {}
    for name, ks in groups.items():
        ks = [k for k in ks if k * f0 < 0.45 * sr]
        if not ks:
            continue
        rows = []
        for k in ks:
            ft = k * f0
            m = (f >= ft * 0.97) & (f <= ft * 1.03)
            rows.append(mag[m].max(axis=0))
        c = 20 * np.log10(np.mean(rows, axis=0) + 1e-12)
        # skip the attack: the analysis window has to be filled with steady
        # ringing before a slope means anything
        t0 = win_s + 0.05
        m = (t > t0) & (c > c.max() - 35) & (c > floor_db)
        if m.sum() < 8:
            out[name] = float('nan')
            continue
        A = np.polyfit(t[m], c[m], 1)
        out[name] = float(A[0])
    return out
