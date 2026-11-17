"""End-to-end fit of one string's brightness/decay against a real pluck.

Usage: python3 fit_one_string.py
Optimises brightness and decay for one string with scipy, using:
  - envelope loss: RMS trajectory in dB over the first 4 s
  - spectrum loss: log band energies over 7 fixed bands
Both normalised so neither dominates. Prints and saves a comparison WAV.
"""
import sys, wave, json
import numpy as np
from scipy.optimize import differential_evolution, minimize
from scipy import signal
from fast_kernel import render as fast_render

SR = 48000
REC = "/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/raw/take1/pipa01_s1_open_tan_medium.wav"
ONSET = 6.5
DUR = 6.0
EDGES = [(80,180),(180,350),(350,700),(700,1300),(1300,2300),(2300,4000),(4000,8000)]


def load_real():
    w = wave.open(REC, 'rb')
    n = w.getnframes(); raw = w.readframes(n); w.close()
    a = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 2, 3)[:, 0, :]
    v = (a[:,0].astype(np.int32) | (a[:,1].astype(np.int32)<<8) | (a[:,2].astype(np.int32)<<16))
    v = np.where(v & 0x800000, v-0x1000000, v).astype(np.float64) / 8388608.0
    y = v[int(ONSET*SR):int(ONSET*SR)+int(DUR*SR)]
    return y / np.max(np.abs(y))


REAL = load_real()


def envelope(y, hop=2400):
    m = len(y)//hop
    y = y[:m*hop].reshape(m, hop)
    return 20*np.log10(np.sqrt(np.mean(y*y,axis=1))+1e-14)


ENV_REAL = envelope(REAL)


def bands(y):
    f, t, Z = signal.stft(y, SR, nperseg=4096, noverlap=3584)
    S = np.abs(Z)
    fr = np.sqrt(np.mean(S**2, axis=0))
    mask = fr > 0.03*fr.max()
    P = 20*np.log10(np.mean(S[:, mask], axis=1)+1e-14)
    out = []
    for lo, hi in EDGES:
        m = (f>=lo)&(f<hi)
        out.append(P[m].mean())
    return np.array(out)


BAND_REAL = bands(REAL)


def synth(params, string=3, velocity=0.9, position=0.5):
    y = fast_render(params, string=string, n=len(REAL))
    return y/np.max(np.abs(y))


def loss(params):
    y = synth(params)
    env = envelope(y)
    # compare only where real is above -45 dB (audible tail)
    valid = ENV_REAL > -45
    e = np.mean((env[valid]-ENV_REAL[valid])**2)
    bd = bands(y)
    s = np.mean((bd-BAND_REAL)**2)
    return e + s


if __name__ == "__main__":
    print("target bands:", np.round(BAND_REAL,1))
    print("evaluating default (b=0.76, d=2.0):", round(loss([0.76,2.0]),2))
    res = differential_evolution(loss, bounds=[(0.05,0.99),(1.0,12.0)],
                                 seed=1, maxiter=8, popsize=8, polish=False,
                                 callback=lambda xk,c: print("  iter best", round(c,2), np.round(xk,3)))
    print("DE result", np.round(res.x,4), round(res.fun,2))
    res2 = minimize(loss, res.x, method="Nelder-Mead", options=dict(maxiter=300, xatol=1e-3, fatol=1e-3))
    print("refined  ", np.round(res2.x,4), round(res2.fun,2))
    best = res2.x if res2.fun < res.fun else res.x
    yb = synth(best)
    print("final bands:", np.round(bands(yb),1))
    # save comparison wav
    def w24(path, x):
        v = np.clip(x, -1, 1)
        q = np.round(v*8388607).astype(np.int32)
        b = bytearray()
        for t in q:
            m = t & 0xFFFFFF
            b += bytes((m&255,(m>>8)&255,(m>>16)&255))
        hdr = b'RIFF'+ (36+len(b)).to_bytes(4,'little')+b'WAVEfmt '+ (16).to_bytes(4,'little')+(1).to_bytes(2,'little')+(1).to_bytes(2,'little')+SR.to_bytes(4,'little')+(SR*3).to_bytes(4,'little')+(3).to_bytes(2,'little')+(24).to_bytes(2,'little')+b'data'+len(b).to_bytes(4,'little')
        open(path,'wb').write(hdr+bytes(b))
    out = "/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/fit_test"
    import os; os.makedirs(out, exist_ok=True)
    w24(f"{out}/real.wav", REAL)
    w24(f"{out}/baseline.wav", synth([0.76,2.0]))
    w24(f"{out}/fitted.wav", yb)
    json.dump(dict(brightness=float(best[0]), decay=float(best[1]),
                   loss=float(min(res.fun,res2.fun)),
                   bands_real=BAND_REAL.tolist(), bands_fit=bands(yb).tolist()),
              open(f"{out}/result.json","w"), indent=2)
    print("saved to", out)
