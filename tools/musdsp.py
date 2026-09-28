"""Small DSP helpers for the music tools, in pure Python: FFT, a Hann window,
power spectra, band edges, a windowed-sinc resampler."""
import cmath
import math


def fft(x):
    """Radix-2 FFT of a list (complex or real); len(x) a power of 2."""
    n = len(x)
    a = [complex(v) for v in x]
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    size = 2
    while size <= n:
        w = cmath.exp(-2j * math.pi / size)
        half = size >> 1
        tw = [w ** k for k in range(half)]
        for s in range(0, n, size):
            for k in range(half):
                u = a[s + k]
                t = a[s + k + half] * tw[k]
                a[s + k] = u + t
                a[s + k + half] = u - t
        size <<= 1
    return a


def hann(n):
    return [0.5 - 0.5 * math.cos(2 * math.pi * i / n) for i in range(n)]


def power_spectrum(x, rate):
    """(freqs, power) of x with a Hann window; len(x) rounded down to a
    power of 2."""
    n = 1
    while n * 2 <= len(x):
        n *= 2
    w = hann(n)
    X = fft([x[i] * w[i] for i in range(n)])
    p = [abs(X[k]) ** 2 for k in range(n // 2 + 1)]
    f = [k * rate / n for k in range(n // 2 + 1)]
    return f, p


def centroid(x, rate):
    f, p = power_spectrum(x, rate)
    t = sum(p) or 1.0
    return sum(fi * pi for fi, pi in zip(f, p)) / t


def band_fraction(x, rate, lo):
    f, p = power_spectrum(x, rate)
    t = sum(p) or 1.0
    return sum(pi for fi, pi in zip(f, p) if fi >= lo) / t


def rms(x):
    return math.sqrt(sum(v * v for v in x) / max(1, len(x)))


def sinc_kernel(ratio, taps=24):
    """Cutoff at 0.45 of the output rate (ratio = out rate / in rate)."""
    cut = min(1.0, ratio) * 0.9
    return cut, taps


def resample(x, rate_in, rate_out, taps=24, periodic=False):
    """Windowed-sinc resampling (Blackman window). periodic: x is one loop
    (the ends wrap)."""
    ratio = rate_out / rate_in
    cut = min(1.0, ratio) * 0.9          # of the input Nyquist
    n_out = int(round(len(x) * ratio))
    half = int(math.ceil(taps / min(1.0, ratio)))
    out = []
    n = len(x)
    for j in range(n_out):
        t = j / ratio
        i0 = int(math.floor(t))
        acc = 0.0
        wsum = 0.0
        for i in range(i0 - half + 1, i0 + half + 1):
            d = t - i
            if periodic:
                v = x[i % n]
            else:
                if i < 0 or i >= n:
                    continue
                v = x[i]
            arg = d * cut
            s = 1.0 if arg == 0 else math.sin(math.pi * arg) / (math.pi * arg)
            u = (d + half) / (2 * half)
            if u < 0 or u > 1:
                continue
            win = 0.42 - 0.5 * math.cos(2 * math.pi * u) + 0.08 * math.cos(4 * math.pi * u)
            k = cut * s * win
            acc += v * k
            wsum += k
        out.append(acc)
    return out
