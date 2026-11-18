"""Numba-JIT fast kernel for fitting. Numerically equivalent to pipa_kernel.py
but uses plain float64 state internally during optimisation (the float32 cast in
the Swift kernel changes results by <1e-5, far below the fitting tolerance).
Final fitted parameters are always re-verified against the exact kernel.
"""
import math
import numpy as np
from numba import njit
from pipa_kernel import OPEN_MIDI, midi_to_freq

DEFAULT_PEAKS = [(205.,3.5,-6.),(420.,3.0,-2.),(760.,2.6,10.),(1350.,2.2,5.),(2600.,1.8,0.)]
DEFAULT_SHELF = (300.0, -16.0)

@njit(cache=True)
def loop_magnitude(s, w):
    real = 1.0-s*math.cos(w)
    imag = s*math.sin(w)
    return (1.0-s)/max(math.sqrt(real*real+imag*imag), 1e-12)

@njit(cache=True)
def loop_phase_delay(s, w):
    return math.atan2(s*math.sin(w), 1.0-s*math.cos(w))/w

@njit(cache=True)
def allpass_phase_delay(a, w):
    num = math.atan2(-math.sin(w), a+math.cos(w))
    den = math.atan2(-a*math.sin(w), 1.0+a*math.cos(w))
    return -(num-den)/w

@njit(cache=True)
def solve_loop_coeff(target_gain, w):
    lo, hi = 0.0, 0.9995
    for _ in range(36):
        mid = (lo+hi)*0.5
        if loop_magnitude(mid,w) > target_gain: lo = mid
        else: hi = mid
    return (lo+hi)*0.5

@njit(cache=True)
def solve_allpass_coeff(target_delay, w):
    lo, hi = -0.6, 0.95
    for _ in range(36):
        mid = (lo+hi)*0.5
        if allpass_phase_delay(mid,w) > target_delay: lo = mid
        else: hi = mid
    return (lo+hi)*0.5

@njit(cache=True)
def loop_gain_for_brightness(b):
    b = min(max(b,0.0),1.0)
    return 0.990 + (0.99995-0.990)*b


def low_shelf_coeff(freq, gain_db, sr=48000.0):
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
    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def low_shelf_coeff(freq, gain_db, sr=48000.0):
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
    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def biquad_coeff(freq, q, gain_db, sr=48000.0):
    a = 10.0**(gain_db/40.0)
    w = 2.0*math.pi*freq/sr
    alpha = math.sin(w)/(2.0*q)
    cw = math.cos(w)
    b0=(1+alpha*a); b1=-2*cw; b2=1-alpha*a
    a0=(1+alpha/a); a1=-2*cw; a2=1-alpha/a
    return (b0/a0,b1/a0,b2/a0,a1/a0,a2/a0)


@njit(cache=True)
def render_one(freq, brightness, decay, velocity, position, peaks_b,
               n, sr=48000.0, shelf_b=(1.0, 0.0, 0.0, 0.0, 0.0),
               comb_depth=0.7, direct_loop=-1.0):
    """Render one plucked string through the body filter bank."""
    w = 2.0*math.pi*max(freq,20.0)/sr
    if direct_loop >= 0.0:
        loop_coeff = min(max(direct_loop, 0.0), 0.9)
    else:
        loop_coeff = solve_loop_coeff(loop_gain_for_brightness(brightness), w)
    lg = loop_magnitude(loop_coeff, w)
    loss = max(-math.log(lg), 1e-9)
    maximum = 6.9078/(max(freq,20.0)*loss)
    effective = min(max(decay,0.02), 0.85*maximum)
    total = 0.001**(1.0/(effective*max(freq,20.0)))
    damping = min(total/max(lg,1e-9), 0.99999)

    lpd = loop_phase_delay(loop_coeff, w)
    remaining = sr/max(freq,20.0) - lpd
    length = min(max(max(2,int(math.floor(remaining-0.5))),2),4095)
    frac = remaining - length
    ap = solve_allpass_coeff(frac, w)

    buf = np.zeros(4096, dtype=np.float64)
    seed = 0x12345678
    for i in range(length):
        seed ^= (seed << 13) & 0xFFFFFFFF
        seed ^= (seed >> 17) & 0xFFFFFFFF
        seed ^= (seed << 5) & 0xFFFFFFFF
        seed &= 0xFFFFFFFF
        if seed == 0:
            seed = 0x9E3779B9
        if seed >= 0x80000000:
            signed = seed - 0x100000000
        else:
            signed = seed
        buf[i] = signed / 2147483647.0

    pos = min(max(position,0.06),0.94)
    gain = min(max(velocity,0.0),1.0)
    # Fractional pluck point and tunable comb depth. Rounding the point to an
    # integer sample quantises the notch frequencies; a sharp or soft plectrum
    # changes how deep those notches cut. Neither belongs in a fixed constant.
    comb_f = min(max(length*pos, 1.0), float(length-1))
    comb_i = int(math.floor(comb_f))
    comb_frac = comb_f - comb_i
    depth = min(max(comb_depth, 0.0), 0.999)
    if comb_i < length:
        for i in range(length-1, comb_i-1, -1):
            near = buf[i-comb_i]
            far = buf[i-comb_i-1] if (i-comb_i-1) >= 0 else near
            sample = near + comb_frac*(far-near)
            buf[i] -= depth*sample
    mean = 0.0
    for i in range(length): mean += buf[i]
    mean /= length
    peak = 0.0
    for i in range(length):
        buf[i] -= mean
        if abs(buf[i])>peak: peak=abs(buf[i])
    scale = gain/peak if peak>1e-9 else 0.0
    for i in range(length): buf[i] *= scale

    index=0; ax=0.0; ay=0.0; ls=0.0
    z1=np.zeros(5,dtype=np.float64); z2=np.zeros(5,dtype=np.float64)
    sz1=0.0; sz2=0.0
    sz1=0.0; sz2=0.0
    out=np.empty(n,dtype=np.float64)
    for k in range(n):
        raw = buf[index]
        delayed = ap*raw + ax - ap*ay
        ax = raw; ay = delayed
        filtered = (1.0-loop_coeff)*delayed + loop_coeff*ls
        ls = filtered
        buf[index] = filtered*damping
        index = (index+1) % length
        v = delayed
        sb0, sb1, sb2, sa1, sa2 = shelf_b
        ys = sb0 * v + sz1
        sz1 = sb1 * v - sa1 * ys + sz2
        sz2 = sb2 * v - sa2 * ys
        v = ys
        for j in range(5):
            b0,b1,b2,a1,a2 = peaks_b[j]
            y = b0*v + z1[j]
            z1[j] = b1*v - a1*y + z2[j]
            z2[j] = b2*v - a2*y
            v = y
        out[k] = v*0.5
    return out


_default_b = tuple(biquad_coeff(*p) for p in DEFAULT_PEAKS)


def render(params, string=3, n=48000*6, peaks=None, sr=48000.0, position=0.5,
           shelf=None, comb_depth=0.7):
    b, d = params
    freq = midi_to_freq(OPEN_MIDI[string])
    pk = tuple(biquad_coeff(*p, sr=sr) for p in (peaks or DEFAULT_PEAKS))
    sb = low_shelf_coeff(*(shelf or DEFAULT_SHELF), sr=sr)
    return render_one(freq, b, d, 0.9, position, pk, n, sr, sb, comb_depth)


def render_at(freq, brightness, decay, position, peaks=None, velocity=0.9,
              n=48000*3, sr=48000.0, shelf=None, comb_depth=0.7,
              direct_loop=-1.0):
    pk = tuple(biquad_coeff(*p, sr=sr) for p in (peaks or DEFAULT_PEAKS))
    sb = low_shelf_coeff(*(shelf or DEFAULT_SHELF), sr=sr)
    return render_one(freq, brightness, decay, velocity, position, pk, n, sr, sb,
                      comb_depth, direct_loop)
