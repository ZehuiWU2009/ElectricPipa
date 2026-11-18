"""Isolated experiment: can progressive excitation reproduce the pipa attack?

Target (robust, 3-take median, 1-period smoothed, steady=1):
  0ms 0.40 -> 12ms peak 1.38 -> 30ms back to 1.0

Three mechanisms compared against the target Hilbert envelope:
  base : current kernel, fill delay line in one sample
  inj  : progressive wideband noise injection (energy builds, then HF decays)
  env  : output-side time-varying gain shaped from the target curve

Nothing here touches the shipping kernel.
"""
import sys
import wave
import numpy as np
from scipy import signal
from scipy.ndimage import uniform_filter1d
sys.path.insert(0, '/Users/lujing/Downloads/wzh/ElectricPipa/Scripts/fit')
import pipa_kernel as pk

SR = 48000
D = '/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/fit_test/demo'
W = int(round(SR / 220.0))          # one period, for ripple removal

# fitted s1 parameters (zi string, 220 Hz)
B, DEC, POS, COMB, DIRECT = 0.9968461770255461, 6.201997053546464, 0.30638034690919397, 0.985, 0.05
PEAKS = [(219.1703265492175, 3.5, -8.0), (420.0, 3.0, -6.77107599520971),
         (760.0, 2.6, 16.0), (1350.0, 2.2, 5.4390374217730395),
         (2600.0, 1.8, -2.85105391798287)]
SHELF = (239.7465896743957, -29.69046525695187)


def sm(e):
    return uniform_filter1d(e, size=W, mode='nearest')


def norm_steady(e, lo=0.030, hi=0.050):
    return e / np.mean(e[int(lo * SR):int(hi * SR)])


def make_body():
    return pk.Biquad.low_shelf(*SHELF), tuple(pk.Biquad.peaking(*p) for p in PEAKS)


def apply_body(v, sh, pk_b):
    v = sh.process(v)
    for flt in pk_b:
        v = flt.process(v)
    return v * pk.F(0.5)


class InjectString(pk.String):
    """Waveguide driven by two physical stages:
       1) pick drawing across the string: progressive wideband drive (rises)
       2) pick releasing the string: a short broadband impulse -> overshoot peak
    """
    def pluck_inject(self, inject_ms, peak_ms, tail_ms, seed, amp, pulse_ms, amp_pulse):
        self._retune()
        n = int(inject_ms / 1000 * SR)
        t = np.arange(n) / SR * 1000.0
        env = np.sin(np.pi / 2 * np.minimum(t / peak_ms, 1.0)) ** 2.0
        fall = t > peak_ms
        env[fall] = np.exp(-(t[fall] - peak_ms) / tail_ms)
        rng = np.random.default_rng(seed)
        noise = rng.standard_normal(n)
        noise /= max(np.max(np.abs(noise)), 1e-12)
        drive = env * noise * amp
        # release impulse at peak_ms: 1 ms burst of broadband noise
        if pulse_ms > 0 and amp_pulse > 0:
            i0 = int(peak_ms / 1000 * SR)
            pn = int(0.0012 * SR)
            burst = rng.standard_normal(pn)
            burst /= max(np.max(np.abs(burst)), 1e-12)
            win = np.sin(np.pi * np.arange(pn) / pn) ** 2
            for j in range(pn):
                if i0 + j < n:
                    drive[i0 + j] += burst[j] * win[j] * amp_pulse
        self.drive = drive.astype(np.float64)
        self.inject_len = n
        self.inject_n = 0
        self.buffer[:] = 0
        self.index = 0
        self.loop_state = 0
        self.ax = 0
        self.ay = 0

    def render_inject(self):
        idx = self.index
        raw = self.buffer[idx]
        delayed = self.allpass_coeff * raw + self.ax - self.allpass_coeff * self.ay
        self.ax, self.ay = raw, delayed
        filtered = (1 - self.loop_coeff) * delayed + self.loop_coeff * self.loop_state
        self.loop_state = filtered
        inj = 0.0
        if self.inject_n < self.inject_len:
            inj = self.drive[self.inject_n]
            self.inject_n += 1
        self.buffer[idx] = filtered * self.damping + inj
        self.index = (idx + 1) % self.length
        return delayed + inj


def render_base(n=SR):
    sh, pk_b = make_body()
    st = pk.String(pk.midi_to_freq(pk.OPEN_MIDI[3]), seed=0x12345678, sr=SR)
    st.set_brightness(B); st.set_decay(DEC); st.combDepth = COMB; st.directLoopCoeff = DIRECT
    st.pluck(0.9, POS)
    out = np.empty(n, np.float32)
    for k in range(n):
        out[k] = apply_body(st.render(), sh, pk_b)
    return out


def render_inject(inject_ms, peak_ms, tail_ms, amp, pulse_ms, amp_pulse, n=SR):
    sh, pk_b = make_body()
    st = InjectString(pk.midi_to_freq(pk.OPEN_MIDI[3]), seed=0x12345678, sr=SR)
    st.set_brightness(B); st.set_decay(DEC); st.combDepth = COMB; st.directLoopCoeff = DIRECT
    st.pluck_inject(inject_ms, peak_ms, tail_ms, 0x12345678, amp, pulse_ms, amp_pulse)
    out = np.empty(n, np.float32)
    for k in range(n):
        out[k] = apply_body(st.render_inject(), sh, pk_b)
    return out


def hilb_env(y):
    y = signal.sosfilt(signal.butter(2, 60, 'highpass', fs=SR, output='sos'), y)
    e = np.abs(signal.hilbert(y))
    k = int(0.0003 * SR); k += k % 2 == 0
    return np.convolve(e, np.ones(k) / k, mode='same')


def envelope_of(y):
    return sm(norm_steady(hilb_env(y)))


if __name__ == '__main__':
    target = np.load('/tmp/real_env_median.npy')
    N = int(0.030 * SR)

    def metrics(name, e):
        rmse = np.sqrt(np.mean((e[:N] - target[:N]) ** 2))
        pk = e[:N].max(); tpk = np.argmax(e[:N]) / SR * 1000
        return (f'  {name:>12s}: RMSE={rmse:.3f} peak={pk:.2f}@{tpk:.0f}ms '
                f'v6={e[int(.006*SR)]:.2f} v12={e[int(.012*SR)]:.2f} v30={e[N-1]:.2f}')

    print('TARGET: peak=%.2f@12ms v6=%.2f v12=%.2f v30=%.2f' %
          (target[:N].max(), target[int(.006*SR)], target[int(.012*SR)], target[N-1]))

    curves = {'t': np.arange(0, N, 48) / SR * 1000,
              'real': target[::48]}
    base = envelope_of(render_base())
    print(metrics('base', base))
    curves['base'] = base[::48]

    # sweep: ramp build + release impulse
    best = None
    for peak_ms in [6, 8, 10, 12]:
        for tail_ms in [8, 16, 26]:
            for amp in [0.9, 1.4, 2.0]:
                for amp_pulse in [0.0, 0.8, 1.4, 2.2, 3.2]:
                    e = envelope_of(render_inject(28, peak_ms, tail_ms, amp, peak_ms, amp_pulse))
                    rmse = np.sqrt(np.mean((e[:N] - target[:N]) ** 2))
                    if best is None or rmse < best[0]:
                        best = (rmse, peak_ms, tail_ms, amp, amp_pulse, e)
    rmse, pms, tms, amp, apulse, e = best
    print(metrics(f'inj p{pms}/t{tms}/a{amp}/pulse{apulse}', e))
    curves['inj'] = e[::48]

    print('\n ms  real  base   inj')
    for ms in range(0, 31, 2):
        i = int(ms / 1000 * SR)
        print(f'{ms:3d}  {target[i]:4.2f}  {base[i]:4.2f}  {e[i]:4.2f}')

    import json, os
    json.dump({k: np.round(np.asarray(v), 3).tolist() for k, v in curves.items()},
              open('/tmp/progressive_curves2.json', 'w'))
    np.save('/tmp/inj_best.npy', e)

    # save wav: real | base | inj
    def rd24(p):
        w = wave.open(p); b = np.frombuffer(w.readframes(w.getnframes()), dtype=np.uint8).reshape(-1,3).astype(np.int32); w.close()
        v = b[:,0] | (b[:,1]<<8) | (b[:,2]<<16)
        return np.where(v & 0x800000, v-0x1000000, v)/8388608
    real = rd24(f'{D}/08_real_vs_synth.wav')  # placeholder length reference
    def write24(path, sig):
        sig = np.clip(sig, -1, 1)
        b = (sig * 8388607).astype(np.int32).astype(np.uint32)
        raw = np.stack([(b & 0xff), ((b >> 8) & 0xff), ((b >> 16) & 0xff)], axis=1).astype(np.uint8)
        w = wave.open(path, 'wb'); w.setnchannels(1); w.setsampwidth(3); w.setframerate(SR)
        w.writeframes(raw.tobytes()); w.close()
    seg = int(0.05 * SR)
    yb = render_base(seg); yi = render_inject(28, pms, tms, amp, pms, apulse, seg)
    gap = int(0.03 * SR); zero = np.zeros(gap, np.float32)
    write24(f'{D}/30_progressive_AB.wav', np.concatenate([zero, yb, zero, yi, zero]))
    print('\nsaved /tmp/progressive_curves2.json and demo/30_progressive_AB.wav')
