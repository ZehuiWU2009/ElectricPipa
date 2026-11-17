"""Fit brightness, decay and the five body resonance peaks against one real pluck."""
import sys, numpy as np, json, os
from scipy.optimize import differential_evolution, minimize
from fast_kernel import render as fast_render, DEFAULT_PEAKS
from fit_one_string import REAL, envelope, ENV_REAL, bands, BAND_REAL, EDGES

OUT = "/Users/lujing/Downloads/wzh/ElectricPipa/Recordings/pilot/fit_test"


def unpack(p):
    bright, decay = float(p[0]), float(p[1])
    peaks = []
    base = [float(x) for x in p[2:]]
    for i,(f0,q0,g0) in enumerate(DEFAULT_PEAKS):
        peaks.append((f0*base[i], q0, g0+base[5+i]))
    return bright, decay, peaks


def synth(p):
    b,d,pk = unpack(p)
    y = fast_render([b,d], n=len(REAL), peaks=pk)
    return y/np.max(np.abs(y))


def loss(p, w_env=1.0, w_band=2.0):
    y = synth(p)
    e = envelope(y)
    valid = ENV_REAL > -45
    le = np.mean((e[valid]-ENV_REAL[valid])**2)
    bd = bands(y)
    lb = np.mean((bd-BAND_REAL)**2)
    # penalty for out-of-range brightness
    pen = 1000*max(0, p[0]-0.99)**2
    return w_env*le + w_band*lb + pen


# p = [brightness, decay, f_scale*5, gain_delta*5]
bounds = [(0.05,0.99),(1.0,8.0)] + [(0.6,1.6)]*5 + [(-8.0,8.0)]*5
x0 = [0.76,2.0] + [1.0]*5 + [0.0]*5
print("initial loss", round(loss(x0),2))
res = differential_evolution(loss, bounds, seed=7, maxiter=12, popsize=6,
                             polish=False, init='sobol',
                             callback=lambda xk,c: print("  iter",round(c,2),np.round(xk[:2],3)))
print("DE", round(res.fun,2), np.round(res.x[:2],3))
res2 = minimize(loss, res.x, method='Nelder-Mead',
                options=dict(maxiter=2000, xatol=1e-3, fatol=1e-2))
best = res2.x if res2.fun < res.fun else res.x
print("refined", round(min(res.fun,res2.fun),2))

b,d,pk = unpack(best)
y = synth(best)
print("brightness",round(b,3),"decay",round(d,3))
print("peaks:", [(round(f),q,round(g,1)) for (f,q,g) in pk])
print("bands real", np.round(BAND_REAL,1))
print("bands fit ", np.round(bands(y),1))
print("env loss at fit", round(float(np.mean((envelope(y)[ENV_REAL>-45]-ENV_REAL[ENV_REAL>-45])**2)),1))

def w24(path,x):
    q=np.clip(x,-1,1)*8388607
    q=np.round(q).astype(np.int32)
    b=bytearray()
    for t in q:
        m=t&0xFFFFFF; b+=bytes((m&255,(m>>8)&255,(m>>16)&255))
    hdr=b'RIFF'+(36+len(b)).to_bytes(4,'little')+b'WAVEfmt '+(16).to_bytes(4,'little')+(1).to_bytes(2,'little')+(1).to_bytes(2,'little')+(48000).to_bytes(4,'little')+(48000*3).to_bytes(4,'little')+(3).to_bytes(2,'little')+(24).to_bytes(2,'little')+b'data'+len(b).to_bytes(4,'little')
    open(path,'wb').write(hdr+bytes(b))

os.makedirs(OUT,exist_ok=True)
w24(f"{OUT}/fitted_body.wav", y)
json.dump(dict(brightness=b,decay=d,peaks=pk,loss=float(min(res.fun,res2.fun)),
               bands_real=BAND_REAL.tolist(),bands_fit=bands(y).tolist()),
          open(f"{OUT}/result_body.json","w"),indent=2)
print("saved",f"{OUT}/fitted_body.wav")
