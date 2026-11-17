"""Python mirror of the ElectricPipa Swift DSP kernel, for offline fitting.

The arithmetic deliberately follows Swift's Float (float32) / Double (float64)
split: filter state and audio buffers are float32; coefficient solving is
float64. This is required for sample-accurate agreement with the Swift renderer.

String index convention matches Swift: 0 = Chan (thickest), 3 = Zi (thinnest).
The App tunes one octave above the recording; pass tune_octave=-1 for fitting.
"""
import math
import numpy as np

F = np.float32

SR = 48000.0
OPEN_MIDI = [45, 50, 52, 57]   # A2 d3 e3 a3, the register the instrument sounds in
CAPACITY = 4096


def midi_to_freq(m):
    return 440.0 * 2.0 ** ((m - 69.0) / 12.0)


def loop_magnitude(s, w):
    real = 1.0 - s * math.cos(w)
    imag = s * math.sin(w)
    return (1.0 - s) / max(math.sqrt(real * real + imag * imag), 1e-12)


def loop_phase_delay(s, w):
    return math.atan2(s * math.sin(w), 1.0 - s * math.cos(w)) / w


def allpass_phase_delay(a, w):
    num = math.atan2(-math.sin(w), a + math.cos(w))
    den = math.atan2(-a * math.sin(w), 1.0 + a * math.cos(w))
    return -(num - den) / w


def solve_loop_coeff(target_gain, w):
    lo, hi = 0.0, 0.9995
    for _ in range(36):
        mid = (lo + hi) * 0.5
        if loop_magnitude(mid, w) > target_gain:
            lo = mid
        else:
            hi = mid
    return (lo + hi) * 0.5


def solve_allpass_coeff(target_delay, w):
    lo, hi = -0.6, 0.95
    for _ in range(36):
        mid = (lo + hi) * 0.5
        if allpass_phase_delay(mid, w) > target_delay:
            lo = mid
        else:
            hi = mid
    return (lo + hi) * 0.5


def loop_gain_for_brightness(b):
    b = min(max(b, 0.0), 1.0)
    return 0.990 + (0.99995 - 0.990) * b


class Biquad:
    __slots__ = ("b0", "b1", "b2", "a1", "a2", "z1", "z2")

    def __init__(self, b0, b1, b2, a1, a2):
        self.b0, self.b1, self.b2 = F(b0), F(b1), F(b2)
        self.a1, self.a2 = F(a1), F(a2)
        self.z1 = F(0)
        self.z2 = F(0)

    @staticmethod
    def peaking(freq, q, gain_db, sr=SR):
        a = 10.0 ** (gain_db / 40.0)
        w = 2.0 * math.pi * freq / sr
        alpha = math.sin(w) / (2.0 * q)
        cw = math.cos(w)
        b0 = 1 + alpha * a
        b1 = -2 * cw
        b2 = 1 - alpha * a
        a0 = 1 + alpha / a
        a1 = -2 * cw
        a2 = 1 - alpha / a
        return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)

    @staticmethod
    def low_shelf(freq, gain_db, sr=SR):
        a = 10.0 ** (gain_db / 40.0)
        w = 2.0 * math.pi * freq / sr
        cw = math.cos(w)
        alpha = math.sin(w) / 2.0 * math.sqrt(2.0)
        two = 2.0 * math.sqrt(a) * alpha
        b0 = a * ((a + 1) - (a - 1) * cw + two)
        b1 = 2 * a * ((a - 1) - (a + 1) * cw)
        b2 = a * ((a + 1) - (a - 1) * cw - two)
        a0 = (a + 1) + (a - 1) * cw + two
        a1 = -2 * ((a - 1) + (a + 1) * cw)
        a2 = (a + 1) + (a - 1) * cw - two
        return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)

    def process(self, x):
        y = self.b0 * x + self.z1
        self.z1 = self.b1 * x - self.a1 * y + self.z2
        self.z2 = self.b2 * x - self.a2 * y
        return y

    def reset(self):
        self.z1 = F(0)
        self.z2 = F(0)


class String:
    def __init__(self, frequency, seed=0x12345678, sr=SR):
        self.sr = sr
        self.frequency = frequency
        self.buffer = np.zeros(CAPACITY, dtype=np.float32)
        self.length = 2
        self.index = 0
        self.allpass_coeff = F(0)
        self.ax = F(0)
        self.ay = F(0)
        self.extra_delay = 0.0
        self.loop_state = F(0)
        self.loop_coeff = F(0.5)
        self.damping = F(0.996)
        self.brightness = 0.6
        self.decay = 2.0
        self.energy = F(0)
        self.noise_state = np.uint32(seed)
        self._update_delay()

    @property
    def omega(self):
        return 2.0 * math.pi * max(self.frequency, 20.0) / self.sr

    def _apply_decay(self):
        lg = loop_magnitude(float(self.loop_coeff), self.omega)
        loss = max(-math.log(lg), 1e-9)
        maximum = 6.9078 / (max(self.frequency, 20.0) * loss)
        effective = min(max(self.decay, 0.02), 0.85 * maximum)
        total = 0.001 ** (1.0 / (effective * max(self.frequency, 20.0)))
        self.damping = F(min(total / max(lg, 1e-9), 0.99999))

    def _update_delay(self):
        w = self.omega
        s = float(self.loop_coeff)
        lpd = loop_phase_delay(s, w)
        total = self.sr / max(self.frequency, 20.0)
        remaining = total - lpd
        integer_part = max(2, int(math.floor(remaining - 0.5)))
        self.length = min(max(integer_part, 2), CAPACITY - 1)
        frac = remaining - self.length
        self.allpass_coeff = F(solve_allpass_coeff(frac, w))
        self.extra_delay = lpd + allpass_phase_delay(float(self.allpass_coeff), w)
        if self.index >= self.length:
            self.index %= self.length
        self._apply_decay()

    def _retune(self):
        self.loop_coeff = F(solve_loop_coeff(loop_gain_for_brightness(self.brightness), self.omega))
        self._update_delay()

    def set_brightness(self, v):
        self.brightness = min(max(v, 0.0), 1.0)
        self._retune()

    def set_decay(self, v):
        self.decay = v
        self._apply_decay()

    def _noise(self):
        x = self.noise_state
        x ^= np.uint32(x << np.uint32(13))
        x ^= np.uint32(x >> np.uint32(17))
        x ^= np.uint32(x << np.uint32(5))
        if x == 0:
            x = np.uint32(0x9E3779B9)
        self.noise_state = x
        i32 = np.int32(x)
        return F(float(i32) / float(np.iinfo(np.int32).max))

    def pluck(self, amplitude, position, retune=True):
        if retune:
            self._retune()
        gain = F(min(max(amplitude, 0.0), 1.0))
        pos = min(max(position, 0.06), 0.94)
        for i in range(self.length):
            self.buffer[i] = self._noise()
        comb = max(1, int(float(self.length) * pos))
        if comb < self.length:
            for i in range(self.length - 1, comb - 1, -1):
                self.buffer[i] = F(self.buffer[i] - F(self.buffer[i - comb] * F(0.7)))
        mean = F(sum(float(v) for v in self.buffer[:self.length]) / self.length)
        peak = F(0)
        for i in range(self.length):
            self.buffer[i] = F(self.buffer[i] - mean)
            if abs(self.buffer[i]) > peak:
                peak = F(abs(self.buffer[i]))
        scale = F(gain / peak) if peak > 1e-9 else F(0)
        for i in range(self.length):
            self.buffer[i] = F(self.buffer[i] * scale)
        self.index = 0
        self.loop_state = F(0)
        self.ax = F(0)
        self.ay = F(0)
        self.energy = F(1)

    def render(self):
        raw = self.buffer[self.index]
        delayed = F(self.allpass_coeff * raw + self.ax - F(self.allpass_coeff * self.ay))
        self.ax = raw
        self.ay = delayed
        filtered = F(F(F(1) - self.loop_coeff) * delayed + self.loop_coeff * self.loop_state)
        self.loop_state = filtered
        self.buffer[self.index] = F(filtered * self.damping)
        self.index = (self.index + 1) % self.length
        mag = abs(float(filtered))
        self.energy = F(float(self.energy) * 0.9995 + mag * mag)
        return delayed


DEFAULT_PEAKS = [
    (205.0, 3.5, -6.0),
    (420.0, 3.0, -2.0),
    (760.0, 2.6, 10.0),
    (1350.0, 2.2, 5.0),
    (2600.0, 1.8, 0.0),
]

DEFAULT_SHELF = (300.0, -16.0)


class Synth:
    def __init__(self, brightness=None, decay=None, peaks=None, tune_octave=0, sr=SR,
                 shelf=None):
        self.sr = sr
        self.strings = []
        pk = peaks if peaks is not None else DEFAULT_PEAKS
        sf = shelf if shelf is not None else DEFAULT_SHELF
        self.shelf = Biquad.low_shelf(sf[0], sf[1], sr)
        self.filters = [Biquad.peaking(f, q, g, sr) for f, q, g in pk]
        # Swift seeds each string with the same 0x12345678.
        for i in range(4):
            f = midi_to_freq(OPEN_MIDI[i]) * (2.0 ** tune_octave)
            s = String(f, seed=0x12345678, sr=sr)
            db = 0.34 + 0.42 * (i / 3.0)
            dd = 4.6 - 2.6 * (i / 3.0)
            b = brightness[i] if (brightness is not None and brightness[i] is not None) else db
            d = decay[i] if (decay is not None and decay[i] is not None) else dd
            s.set_brightness(b)
            s.set_decay(d)
            self.strings.append(s)

    def pluck(self, string, velocity=0.9, position=0.5):
        self.strings[string].pluck(velocity, position)

    def render(self, n):
        out = np.empty(n, dtype=np.float32)
        for k in range(n):
            v = F(0)
            for s in self.strings:
                v = F(v + s.render())
            v = self.shelf.process(v)
            for flt in self.filters:
                v = flt.process(v)
            out[k] = F(v * F(0.5))
        return out
