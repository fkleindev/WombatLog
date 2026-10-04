"""Generates WombatLog's media files (textures and crit sounds).

Requires: pip install numpy soundfile
Run from the repository root: python tools/gen_media.py
"""
import os
import struct

import numpy as np
import soundfile as sf

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MEDIA = os.path.join(ROOT, "Media")
SOUNDS = os.path.join(MEDIA, "Sounds")
RATE = 44100


# --- textures ---------------------------------------------------------------

def write_tga(path, width, height, alpha):
    """Uncompressed 32-bit TGA, white RGB with the given alpha (rows bottom-up)."""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    a = np.clip(alpha, 0, 255).astype(np.uint8)
    pixels = np.empty((height, width, 4), np.uint8)
    pixels[..., :3] = 255
    pixels[..., 3] = a
    with open(path, "wb") as f:
        f.write(header + pixels.tobytes())


def gen_textures():
    # Gradient: alpha 255 -> 0 left to right (row backgrounds)
    ramp = 255 - np.arange(256)
    write_tga(os.path.join(MEDIA, "Gradient.tga"), 256, 4, np.tile(ramp, (4, 1)))

    # Glow: soft radial burst (crit alert)
    n = 128
    y, x = np.mgrid[0:n, 0:n]
    r = np.hypot(x - (n - 1) / 2, y - (n - 1) / 2) / (n / 2)
    glow = np.clip(1 - r, 0, 1) ** 2.2 * 255
    write_tga(os.path.join(MEDIA, "Glow.tga"), n, n, glow)


# --- sounds -----------------------------------------------------------------

def t_axis(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def envelope(t, attack, decay):
    env = np.exp(-t / decay)
    a = int(attack * RATE)
    if a > 0:
        env[:a] *= np.linspace(0, 1, a)
    return env


def place(buf, sound, at):
    start = int(at * RATE)
    end = min(len(buf), start + len(sound))
    buf[start:end] += sound[: end - start]


def finish(buf, name):
    fade = int(0.03 * RATE)
    buf[-fade:] *= np.linspace(1, 0, fade)
    buf = buf / np.max(np.abs(buf)) * 10 ** (-3 / 20)  # peak -3 dBFS
    path = os.path.join(SOUNDS, name)
    sf.write(path, buf.astype(np.float32), RATE, format="OGG", subtype="VORBIS")
    return path


def bell(freq, seconds, decay):
    """Bright bell: harmonic partials, higher ones die faster, a touch of shimmer."""
    t = t_axis(seconds)
    partials = [(1.0, 1.0, 1.0), (2.0, 0.45, 0.6), (3.0, 0.2, 0.4), (4.17, 0.08, 0.3)]
    out = np.zeros_like(t)
    for ratio, amp, decay_scale in partials:
        out += amp * np.sin(2 * np.pi * freq * ratio * t) * envelope(t, 0.003, decay * decay_scale)
    out *= 1 + 0.04 * np.sin(2 * np.pi * 6 * t)  # gentle shimmer
    return out


def chime(base, name):
    buf = np.zeros(int(0.8 * RATE))
    place(buf, bell(base, 0.8, 0.22), 0.0)
    place(buf, 0.85 * bell(base * 1.5, 0.74, 0.26), 0.065)  # a fifth up
    return finish(buf, name)


def gen_chime():
    return chime(1046.5, "CritChime.ogg")  # C6


# Crit streaks of 2, 3 and 4+ raise the crit sound by 2, 4 and 7 semitones.
# The game can't change a sound's pitch, so every sound gets its raised copies.
STREAK_STEPS = ((2, 2), (3, 4), (4, 7))


def streak_pitch(semitones):
    return 2 ** (semitones / 12)


def gen_record(pitch=1.0, name="Record.ogg"):
    # rising major arpeggio C6 E6 G6 C7, the last note rings out
    buf = np.zeros(int(1.2 * RATE))
    notes = (1046.5, 1318.5, 1568.0, 2093.0)
    for i, f in enumerate(notes):
        last = i == len(notes) - 1
        place(buf, (1.0 if last else 0.8) * bell(f * pitch, 1.0 if last else 0.5, 0.35 if last else 0.15), i * 0.09)
    return finish(buf, name)


def gen_proc(pitch=1.0, name="Proc.ogg"):
    t = t_axis(0.45)
    tone = np.sin(2 * np.pi * 1760 * pitch * t) + 0.25 * np.sin(2 * np.pi * 2640 * pitch * t)
    return finish(lowpass(tone * envelope(t, 0.005, 0.13), 5000), name)


def soft_square(freq, t):
    return np.sin(2 * np.pi * freq * t) + 0.3 * np.sin(2 * np.pi * 3 * freq * t) / 3


def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def gen_coin(pitch=1.0, name="CritCoin.ogg"):
    buf = np.zeros(int(0.5 * RATE))
    t1 = t_axis(0.075)
    place(buf, 0.8 * soft_square(988 * pitch, t1) * envelope(t1, 0.002, 0.2), 0.0)
    t2 = t_axis(0.42)
    place(buf, soft_square(1319 * pitch, t2) * envelope(t2, 0.002, 0.12), 0.07)
    return finish(lowpass(buf, 6000), name)


def gen_impact(pitch=1.0, name="CritImpact.ogg"):
    seconds = 0.6
    t = t_axis(seconds)
    rng = np.random.default_rng(7)
    # low thump: sine sweeping 150 -> 50 Hz
    freq = (50 + 100 * np.exp(-t / 0.06)) * pitch
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    thump = np.sin(phase) * envelope(t, 0.002, 0.12)
    # short noise transient
    noise = lowpass(rng.standard_normal(len(t)), 3500) * envelope(t, 0.0005, 0.012) * 2.5
    # bright ring on top
    ring = 0.3 * bell(1760 * pitch, seconds, 0.16)
    return finish(thump + noise + ring, name)


def gen_streaks():
    # the chime's raised copies keep their original names (CritStreak2-4.ogg)
    paths = [chime(1046.5 * streak_pitch(st), f"CritStreak{level}.ogg") for level, st in STREAK_STEPS]
    for gen, base in ((gen_coin, "CritCoin"), (gen_impact, "CritImpact"), (gen_record, "Record"), (gen_proc, "Proc")):
        for level, st in STREAK_STEPS:
            paths.append(gen(streak_pitch(st), f"{base}Streak{level}.ogg"))
    return paths


def main():
    os.makedirs(SOUNDS, exist_ok=True)
    gen_textures()
    for path in (gen_chime(), gen_coin(), gen_impact(), gen_record(), gen_proc(), *gen_streaks()):
        data, rate = sf.read(path)
        print(f"{os.path.basename(path)}: {len(data) / rate:.2f}s, {rate} Hz, peak {np.max(np.abs(data)):.2f}")
    print("textures: Gradient.tga, Glow.tga")


if __name__ == "__main__":
    main()
