"""Fit the per-string parameters against one shared body.

The body is a property of the instrument, not of a string: all four strings
radiate through the same box. So the body (low shelf plus five peaks) is taken
from the Zi-string fit and frozen, and only brightness, decay and pluck
position are solved per string here. Fitting four bodies would give four
different instruments.

String indices match PipaTuning: 0 Chan (110 Hz), 1 Lao (146.83), 2 Zhong
(164.81), 3 Zi (220).
"""
import json
import os
import numpy as np
from scipy.optimize import differential_evolution, minimize

from fitlib import load_wav, onset_of, pluck, harmonic_table, harmonic_decay, envelope_db, RAW
from fast_kernel import render_at

DUR = 3.0
STRINGS = [
    (0, 's4', 110.00),
    (1, 's3', 146.83),
    (2, 's2', 164.81),
    (3, 's1', 220.00),
]
OUT_DIR = '/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/fit_test'


def target(tag):
    x, sr = load_wav(f'{RAW}/take1/pipa01_{tag}_open_tan_medium.wav')
    on = onset_of(x, sr)
    y = pluck(x, sr, on, DUR)
    rel, _, ks = harmonic_table(y, sr, {'s1': 220.0, 's2': 164.81, 's3': 146.83, 's4': 110.0}[tag], kmax=14)
    dec = harmonic_decay(y, sr, {'s1': 220.0, 's2': 164.81, 's3': 146.83, 's4': 110.0}[tag])
    e = envelope_db(y, sr, 0.02)
    t = np.arange(len(e)) * 0.02
    m = (t > 0.35) & (t < 3.0)
    slope = float(np.polyfit(t[m], e[m], 1)[0])
    return y, sr, rel, ks, dec, slope


def measure_syn(y, sr, f0):
    rel, _, ks = harmonic_table(y, sr, f0, kmax=14)
    dec = harmonic_decay(y, sr, f0)
    e = envelope_db(y, sr, 0.02)
    t = np.arange(len(e)) * 0.02
    m = (t > 0.35) & (t < 3.0)
    slope = float(np.polyfit(t[m], e[m], 1)[0])
    return rel, ks, dec, slope


def make_loss(f0, n, sr, body, real_rel, real_ks, real_dec, real_slope):
    peaks, shelf = body

    def f(p):
        y = np.asarray(render_at(f0, p[0], p[1], p[2], peaks=peaks, n=n, shelf=shelf), dtype=np.float64)
        y = y / max(np.max(np.abs(y)), 1e-12)
        rel, ks, dec, slope = measure_syn(y, sr, f0)
        if len(ks) != len(real_ks):
            rel = np.interp(real_ks, ks, rel)
        w = np.where(real_ks <= 2, 0.2, 1.0) * np.where(real_ks <= 8, 1.0, 0.5)
        harm = float(np.sum(w * np.minimum((rel - real_rel) ** 2, 3600.0)) / np.sum(w))
        dt = [((dec[g] - real_dec[g]) / 10.0) ** 2 for g in ('mid', 'high')
              if not (np.isnan(dec.get(g, np.nan)) or np.isnan(real_dec.get(g, np.nan)))]
        return harm + 1.2 * (float(np.mean(dt)) if dt else 100.0) + 2.0 * ((slope - real_slope) / 3.0) ** 2

    return f


def main():
    z = json.load(open(f'{OUT_DIR}/fit_s1_v2.json'))
    peaks = [tuple(p) for p in z['params']['peaks']]
    shelf = tuple(z['params']['shelf'])
    body = (peaks, shelf)
    print('shared body:', [f'{p[0]:.0f}Hz/{p[2]:+.1f}dB' for p in peaks], 'shelf', shelf)

    out = {'body': {'peaks': [list(p) for p in peaks], 'shelf': list(shelf)}, 'strings': {}}
    for index, tag, f0 in STRINGS:
        real, sr, rel, ks, dec, slope = target(tag)
        loss = make_loss(f0, len(real), sr, body, rel, ks, dec, slope)
        bounds = [(0.05, 1.0), (0.5, 40.0), (0.06, 0.50)]
        res = differential_evolution(loss, bounds, seed=11, maxiter=70, popsize=10,
                                     tol=1e-6, mutation=(0.5, 1.2), recombination=0.75,
                                     polish=False, workers=1)
        r2 = minimize(loss, res.x, method='L-BFGS-B', bounds=bounds,
                      options={'maxiter': 2000, 'ftol': 1e-10})
        p = r2.x if r2.fun < res.fun else res.x
        y = np.asarray(render_at(f0, p[0], p[1], p[2], peaks=peaks, n=len(real), shelf=shelf), dtype=np.float64)
        y = y / max(np.max(np.abs(y)), 1e-12)
        srel, _, sdec, sslope = measure_syn(y, sr, f0)
        res_rel = srel - rel
        print(f'\n{tag} (string {index}, {f0:.2f} Hz)  loss {loss(p):.2f}')
        print(f'  brightness {p[0]:.4f}  decay {p[1]:.2f}s  position {p[2]:.3f}')
        print(f'  slope real {slope:.1f}  fitted {sslope:.1f} dB/s')
        print(f'  decay real ' + ' '.join(f'{g}={dec[g]:.1f}' for g in ('mid', 'high')))
        print(f'  decay fit  ' + ' '.join(f'{g}={sdec.get(g, float("nan")):.1f}' for g in ('mid', 'high')))
        print(f'  harm resid ' + ' '.join(f'k{int(k)}={v:+.0f}' for k, v in zip(ks, res_rel) if k >= 3))
        out['strings'][tag] = {
            'index': index, 'f0': f0,
            'brightness': float(p[0]), 'decay': float(p[1]), 'position': float(p[2]),
            'loss': float(loss(p)),
            'slope_real': slope, 'slope_fitted': sslope,
            'decay_real': dec, 'decay_fitted': sdec,
            'harm_residual': [float(v) for v in res_rel],
        }
        with open(f'{OUT_DIR}/fit_strings.json', 'w') as fh:
            json.dump(out, fh, indent=2)
    print('\nwrote', f'{OUT_DIR}/fit_strings.json')


if __name__ == '__main__':
    main()
