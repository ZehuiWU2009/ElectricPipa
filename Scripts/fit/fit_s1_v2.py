"""Fit one open string against its recording, on a loss that can only see the
string's own harmonic series.

What the loss deliberately ignores
----------------------------------
* Absolute level. Both signals are normalised, so the fit is about timbre and
  decay only.
* Anything below 0.97*f0. A 220 Hz string cannot radiate 110 Hz; the 110 Hz
  that shows up in the recording is the fourth string ringing sympathetically,
  one octave down. Asking the model for it is what produced the earlier
  nonsense result (a 112 Hz body resonance with 22 dB of gain).
* Band averages. The recording floor is not flat and drifts with time, so an
  average over a fixed band turns background structure into a fitting target.

What it does use
----------------
* Harmonic amplitudes at k*f0, relative to the strongest harmonic.
* Decay rate in dB/s for the low / mid / high harmonic groups.
"""
import json
import sys
import numpy as np
from scipy.optimize import differential_evolution, minimize

from fitlib import load_wav, onset_of, pluck, harmonic_table, harmonic_decay, envelope_db, RAW
from fast_kernel import render_at, DEFAULT_PEAKS, DEFAULT_SHELF

F0 = 220.0            # first string, A3, one octave below the app's 440
STRING_TAG = 's1'
DUR = 3.0

REAL_ENV_SLOPE = -12.4

PEAK_FREQS = [p[0] for p in DEFAULT_PEAKS]
PEAK_QS = [p[1] for p in DEFAULT_PEAKS]
PEAK_GAINS = [p[2] for p in DEFAULT_PEAKS]


def load_target(take='take1'):
    x, sr = load_wav(f'{RAW}/{take}/pipa01_{STRING_TAG}_open_tan_medium.wav')
    on = onset_of(x, sr)
    return pluck(x, sr, on, DUR), sr


def model(x, n):
    brightness, decay, position = x[0], x[1], x[2]
    gains = x[3:8]
    f1 = x[8]
    shelf = (x[9], x[10])
    freqs = [f1] + PEAK_FREQS[1:]
    peaks = [(freqs[i], PEAK_QS[i], gains[i]) for i in range(5)]
    y = render_at(F0, brightness, decay, position, peaks=peaks, n=n, shelf=shelf)
    y = np.asarray(y, dtype=np.float64)
    return y / max(np.max(np.abs(y)), 1e-12)


def measure(y, sr):
    rel, absdb, ks = harmonic_table(y, sr, F0, kmax=14)
    dec = harmonic_decay(y, sr, F0)
    return rel, ks, dec


def loss(x, real, real_rel, real_ks, real_dec, sr):
    n = len(real)
    y = model(x, n)
    rel, ks, dec = measure(y, sr)
    if len(ks) != len(real_ks):
        rel = np.interp(real_ks, ks, rel)
        ks = real_ks
    # k1 and k2 are de-weighted on purpose. At 220 and 440 Hz the recording
    # carries the fourth string ringing sympathetically one and two octaves
    # down; those two partials sit some 45 dB below the peak and decay at
    # 1 dB/s, which is the thick string's tail, not this string's.
    w = np.where(real_ks <= 2, 0.2, 1.0)
    w = w * np.where(real_ks <= 8, 1.0, 0.5)
    # cap each harmonic: a single 100 dB outlier must not swamp the rest
    diff2 = np.minimum((rel - real_rel) ** 2, 3600.0)
    harm = float(np.sum(w * diff2) / np.sum(w))
    # decay: only the mid and high groups are usable. The low group contains
    # the sympathetic partials described above.
    dterms = []
    for g in ('mid', 'high'):
        r = real_dec.get(g, float('nan'))
        v = dec.get(g, float('nan'))
        if np.isnan(r) or np.isnan(v):
            continue
        dterms.append(((v - r) / 10.0) ** 2)
    decay_term = float(np.mean(dterms)) if dterms else 100.0
    # broadband loudness decay: what a listener actually hears fall away
    e = envelope_db(y, sr, 0.02)
    t = np.arange(len(e)) * 0.02
    m = (t > 0.35) & (t < 3.0)
    slope = float(np.polyfit(t[m], e[m], 1)[0])
    env_term = ((slope - REAL_ENV_SLOPE) / 3.0) ** 2
    return harm + 1.2 * decay_term + 2.0 * env_term


def main():
    real, sr = load_target()
    real_rel, real_ks, real_dec = measure(real, sr)
    e = envelope_db(real, sr, 0.02)
    t = np.arange(len(e)) * 0.02
    m = (t > 0.35) & (t < 3.0)
    global REAL_ENV_SLOPE
    REAL_ENV_SLOPE = float(np.polyfit(t[m], e[m], 1)[0])
    print('target broadband slope: %.1f dB/s' % REAL_ENV_SLOPE)
    print('target decay dB/s:', {k: round(v, 1) for k, v in real_dec.items()})
    print('target harmonics :', ' '.join(f'k{int(k)}={v:.1f}' for k, v in zip(real_ks, real_rel)))

    bounds = [
        (0.05, 1.00),    # brightness
        (0.50, 40.0),    # requested 60 dB decay time, seconds
        (0.06, 0.50),    # pluck position along the string
    ] + [(-8.0, 8.0), (-14.0, 14.0), (-4.0, 16.0), (-8.0, 12.0), (-8.0, 8.0)] \
        + [(150.0, 320.0), (180.0, 650.0), (-30.0, 0.0)]

    def f(x):
        return loss(x, real, real_rel, real_ks, real_dec, sr)

    base = np.array([0.76, 2.0, 0.5, *PEAK_GAINS, 205.0, *DEFAULT_SHELF])
    print('\ndefault loss:', round(f(base), 2))

    res = differential_evolution(
        f, bounds, seed=7, maxiter=140, popsize=12, tol=1e-6,
        mutation=(0.5, 1.2), recombination=0.75, polish=False, workers=1,
        disp=True)
    print('DE done', round(res.fun, 2))

    # Bounds matter here. A narrow -18 dB notch at 219 Hz fits one note well and
    # wrecks the instrument: 219.4 Hz is the first fret of the Lao string and
    # 220 Hz the fifth of the Zhong string, so those two notes would go hollow
    # while their neighbours stayed full. The body response has to stay smooth,
    # which means the overall tilt belongs to the shelf and the peaks only shape
    # detail.
    res2 = minimize(f, res.x, method='L-BFGS-B', bounds=bounds,
                    options={'maxiter': 3000, 'ftol': 1e-10})
    x = res2.x if res2.fun < res.fun else res.x
    print('final loss', round(f(x), 3))

    y = model(x, len(real))
    rel, ks, dec = measure(y, sr)
    default = model(base, len(real))
    drel, dks, ddec = measure(default, sr)

    print('\n  k   freq     real   default   fitted')
    for i, k in enumerate(real_ks):
        print(f'  {int(k):2d} {k*F0:7.1f}  {real_rel[i]:7.1f} {drel[i]:9.1f} {rel[i]:8.1f}')
    print('\n  decay dB/s       real  default  fitted')
    for g in ('low', 'mid', 'high'):
        print(f'   {g:5s}  {real_dec[g]:9.1f} {ddec.get(g, float("nan")):8.1f} {dec.get(g, float("nan")):8.1f}')

    out = {
        'string': STRING_TAG, 'f0': F0,
        'params': {
            'brightness': float(x[0]), 'decay': float(x[1]), 'position': float(x[2]),
            'peaks': [[float([x[8], *PEAK_FREQS[1:]][i]), PEAK_QS[i], float(x[3 + i])] for i in range(5)],
            'shelf': [float(x[9]), float(x[10])],
        },
        'loss': float(f(x)),
        'default_loss': float(f(base)),
        'measured': {'decay_real': real_dec, 'decay_fitted': dec, 'decay_default': ddec},
    }
    import os
    os.makedirs('/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/fit_test', exist_ok=True)
    with open('/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/fit_test/fit_s1_v2.json', 'w') as fh:
        json.dump(out, fh, indent=2)

    # write the three renders so they can be compared by ear
    from scipy.io import wavfile
    d = '/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/fit_test'
    wavfile.write(f'{d}/compare_real.wav', sr, (real * 0.5 * 32767).astype(np.int16))
    wavfile.write(f'{d}/compare_default.wav', sr, (default * 0.5 * 32767).astype(np.int16))
    wavfile.write(f'{d}/compare_fitted.wav', sr, (y * 0.5 * 32767).astype(np.int16))
    print('\nwrote', d)


if __name__ == '__main__':
    main()
