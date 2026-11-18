"""Fit the six bridge couplings from the cross-string levels in the recordings.

The target is the same narrow-window peak measurement used for the direct
string fits, applied to the other strings' fundamentals. The plucked string's
own harmonics are excluded: a 220 Hz string cannot produce 110 Hz, so a peak
there has to be the Chan string ringing along.

No broadband band averages, no fitted body resonances. A coupling that cannot
reproduce these eleven narrow peaks does not get to change the body.
"""
import json
import numpy as np
from scipy.optimize import minimize

from fitlib import harmonic_table
from sympathetic_kernel import PAIRS, pair_index, render_with_sympathy

OUT = '/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/fit_test'
F0 = [110.0, 146.83, 164.81, 220.0]
N = 48000 * 3
SR = 48000.0


def peak_db(y, sr, f, half=0.015):
    a = int(0.10 * sr)
    b = min(int(1.60 * sr), len(y))
    seg = y[a:b] * np.hanning(b - a)
    nfft = 1 << int(np.ceil(np.log2(max(len(seg), 4096)))) + 1
    X = np.abs(np.fft.rfft(seg, nfft))
    fq = np.fft.rfftfreq(nfft, 1.0 / sr)
    m = (fq >= f * (1 - half)) & (fq <= f * (1 + half))
    return 20 * np.log10(X[m].max() + 1e-20)


def matrix(theta):
    c = np.zeros((4, 4), dtype=np.float64)
    for p, (i, j) in enumerate(PAIRS):
        c[i][j] = c[j][i] = float(np.exp(theta[p]))
    return c


def main():
    z = json.load(open(f'{OUT}/fit_strings_v2.json'))
    peaks = [tuple(p) for p in z['body']['peaks']]
    shelf = tuple(z['body']['shelf'])
    body = (peaks, shelf)
    strings = [tuple(z['strings'][tag][k] for k in
                     ('brightness', 'decay', 'position', 'combDepth'))
               for tag in ('s4', 's3', 's2', 's1')]
    targets = json.load(open(f'{OUT}/sympathy_targets.json'))

    # Direct voices do not depend on the couplings. Render them once.
    direct = [render_with_sympathy(pi, strings, body, np.zeros((4, 4)), N, SR,
                                   direct=None) for pi in range(4)]
    # The direct-only render is the plucked string plus nothing else; normalise
    # exactly as the earlier per-string fits did.
    for pi in range(4):
        direct[pi] = direct[pi] / max(np.max(np.abs(direct[pi])), 1e-12)

    keys = [(int(k.split('->')[0]), int(k.split('->')[1])) for k in targets]
    goal = np.array([targets[f'{i}->{j}']['median_db'] for i, j in keys])

    def predict(theta):
        c = matrix(theta)
        vals = []
        for i, j in keys:
            y = render_with_sympathy(i, strings, body, c, N, SR, direct=direct[i])
            y = y / max(np.max(np.abs(y)), 1e-12)
            vals.append(peak_db(y, SR, F0[j]) - peak_db(y, SR, F0[i]))
        return np.array(vals)

    def loss(theta):
        d = predict(theta) - goal
        return float(np.mean(np.minimum(d * d, 900.0)))

    # Seed every coupling at -22 dB, roughly the centre of the measured set.
    theta0 = np.full(6, np.log(10 ** (-22.0 / 20.0)))
    bounds = [(np.log(1e-4), np.log(1.5))] * 6
    res = minimize(loss, theta0, method='L-BFGS-B', bounds=bounds,
                   options={'maxiter': 400, 'ftol': 1e-10})
    theta = res.x if res.fun < loss(theta0) else theta0
    pred = predict(theta)
    c = matrix(theta)

    print(f'loss {loss(theta):.2f} dB^2  (no coupling {loss(np.full(6, np.log(1e-8))):.2f})')
    for p, (i, j) in enumerate(PAIRS):
        print(f'  pair s{4-i} <-> s{4-j}: coupling {c[i][j]:.4f}  '
              f'({20*np.log10(max(c[i][j],1e-9)):+.1f} dB)')
    print('\ndirection        measured   fitted   error')
    for (i, j), g, q in zip(keys, goal, pred):
        print(f'  s{4-i}->s{4-j}       {g:+7.1f}  {q:+7.1f}  {q-g:+6.1f} dB')

    out = {'couplings': {f'{i}-{j}': float(c[i][j]) for i, j in PAIRS},
           'attack_s': 0.03,
           'loss_db2': float(loss(theta)),
           'directions': {f'{i}->{j}': {'measured_db': float(g), 'fitted_db': float(q)}
                          for (i, j), g, q in zip(keys, goal, pred)}}
    path = f'{OUT}/fit_sympathy.json'
    json.dump(out, open(path, 'w'), indent=2)
    print('\nwrote', path)


if __name__ == '__main__':
    main()
