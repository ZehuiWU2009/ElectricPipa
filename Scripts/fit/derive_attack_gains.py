"""Derive a per-string transient gain curve from the real recordings.

NOT ADOPTED. Kept for the record only. Automatic onset detection is unreliable
on three of the takes (the English cue overlaps the pluck, and several noise
floors are contaminated), so the four curves this script produces were not used.
The shipped curve in PipaSynth.attackGainCurve comes from the verified single
Zi-string take (take1, onset 6.518 s) via trial_gain.py instead.

For each string i and each of 3 takes:

For each string i and each of 3 takes:
  - locate the attack onset from a 1 ms RMS window above 20x the noise floor
  - slice 120 ms, Hilbert-envelope, smooth over one fundamental period
  - normalise to the 30-50 ms steady level
Median across takes gives target_i(t).

Render the current kernel for that string alone (through the same body), take
its Hilbert envelope, and set gain_i(t) = target_i(t) / smooth(base_i(t)).
The gain is smoothed on 2 ms and forced to 1 after 40 ms so the steady spectrum
is untouched.
"""
import sys
import numpy as np
from scipy import signal
from scipy.ndimage import uniform_filter1d
sys.path.insert(0, '/Users/lujing/Downloads/wzh/ElectricPipa/Scripts/fit')
from fitlib import load_wav, RAW
import pipa_kernel as pk

SR = 48000
F0 = [110.0, 146.83, 164.81, 220.0]
NAMES = ['s4', 's3', 's2', 's1']       # index order matches Swift (0=Chan .. 3=Zi)
# fitted per-string parameters, index order matches Swift
BRIGHT = [0.9703657754393913, 0.9852437813720939, 0.9926930160434189, 0.9968461770255461]
DECAY = [39.99999739867236, 21.862170178949548, 10.863216960872291, 6.201997053546464]
POS = [0.26267282848519696, 0.12923076143879175, 0.11391952037462497, 0.30638034690919397]
COMB = [0.7903795072919821, 0.985, 0.985, 0.985]
DIRECT = [None, None, None, 0.05]
PEAKS = [(219.1703265492175, 3.5, -8.0), (420.0, 3.0, -6.77107599520971),
         (760.0, 2.6, 16.0), (1350.0, 2.2, 5.4390374217730395),
         (2600.0, 1.8, -2.85105391798287)]
SHELF = (239.7465896743957, -29.69046525695187)


def hilb_env(y):
    y = signal.sosfilt(signal.butter(2, 60, 'highpass', fs=SR, output='sos'), y)
    e = np.abs(signal.hilbert(y))
    k = int(0.0003 * SR); k += k % 2 == 0
    return np.convolve(e, np.ones(k) / k, mode='same')


def find_onset(x):
    hop = int(0.002 * SR)
    rms = np.array([np.sqrt(np.mean(x[i:i+hop]**2))
                    for i in range(0, len(x)-hop, hop)])
    floor = np.percentile(rms[:int(8/0.002)], 10)
    cand = np.where(rms[int(4/0.002):] > 15*floor)[0] + int(4/0.002)
    good = [j for j in cand if j+30 < len(rms)
            and np.mean(rms[j:j+30] > 8*floor) > 0.8]
    return (good[0]*0.002 if good else 6.5), floor


def real_target(i):
    envs = []
    print(f'  {NAMES[i]} (f0={F0[i]:.2f}):')
    for tk in ['take1', 'take2', 'take3']:
        x, sr = load_wav(f'{RAW}/{tk}/pipa01_{NAMES[i]}_open_tan_medium.wav')
        on, floor = find_onset(x)
        seg = x[int(on*sr):int((on+0.120)*sr)]
        seg = seg / max(np.max(np.abs(seg)), 1e-12)
        e = hilb_env(seg)
        e /= np.mean(e[int(0.030*SR):int(0.050*SR)])
        w = int(round(SR/F0[i]))
        es = uniform_filter1d(e, size=w, mode='nearest')
        envs.append(es)
        print(f'    {tk}: onset={on:.4f} floor={floor:.6f} '
              f'v12={es[int(.012*SR)]:.2f} v30={es[int(.030*SR)]:.2f}')
    return np.median(np.array(envs), axis=0)


def render_base(i, n=SR):
    sh = pk.Biquad.low_shelf(*SHELF)
    pk_b = tuple(pk.Biquad.peaking(*p) for p in PEAKS)
    st = pk.String(pk.midi_to_freq(pk.OPEN_MIDI[i]), seed=0x12345678, sr=SR)
    st.set_brightness(BRIGHT[i]); st.set_decay(DECAY[i])
    st.combDepth = COMB[i]
    if DIRECT[i] is not None:
        st.directLoopCoeff = DIRECT[i]
    st.pluck(0.9, POS[i])
    out = np.empty(n, np.float32)
    for k in range(n):
        v = sh.process(st.render())
        for flt in pk_b:
            v = flt.process(v)
        out[k] = v * pk.F(0.5)
    return out


if __name__ == '__main__':
    curves = {}
    for i in range(4):
        target = real_target(i)
        base = hilb_env(render_base(i))
        base = base / np.mean(base[int(0.030*SR):int(0.050*SR)])
        w = int(round(SR/F0[i]))
        base_sm = uniform_filter1d(base, size=w, mode='nearest')

        N = int(0.040*SR)
        gain = np.ones(SR, np.float64)
        gain[:N] = target[:N] / np.maximum(base_sm[:N], 1e-6)
        gain[:N] = uniform_filter1d(gain[:N], size=int(0.002*SR), mode='nearest')
        # clamp to a sane range so the curve can never cause clipping/negatives
        gain[:N] = np.clip(gain[:N], 0.05, 2.0)
        # taper 40->45 ms down to exactly 1
        for k in range(N, min(SR, N+int(0.005*SR))):
            gain[k] = 1.0 + (gain[N-1]-1.0)*(1-(k-N)/int(0.005*SR))

        curves[NAMES[i]] = gain
        pk_i = np.argmax(target[:N])/SR*1000
        print(f'    target peak={target[:N].max():.2f}@{pk_i:.0f}ms  '
              f'gain[0]={gain[0]:.2f} gain[6ms]={gain[int(.006*SR)]:.2f} '
              f'gain[12ms]={gain[int(.012*SR)]:.2f} gain[40ms]={gain[N-1]:.2f}')

    np.savez('/tmp/attack_gains_4str.npz', **curves)
    print('\nsaved /tmp/attack_gains_4str.npz')
