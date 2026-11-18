#!/usr/bin/env python3
"""Icono de Glint (1024x1024): anillo de progreso menta con el punto de búsqueda
y un play blanco dentro, sobre casi negro. Se dibuja a 4x y se reduce para suavizar."""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "Glint/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
SS = 4
S = 1024 * SS


def k(v):
    return round(v * SS)


def grad(c1, c2, angle):
    """Degradado lineal de c1 a c2; angle 90 = de arriba a abajo."""
    m = Image.linear_gradient("L").rotate(90 - angle, resample=Image.BICUBIC)
    m = m.crop((40, 40, 216, 216)).resize((S, S), Image.BICUBIC)
    return Image.composite(Image.new("RGB", (S, S), c2), Image.new("RGB", (S, S), c1), m)


def play(cx, cy, h, r):
    """Triángulo de play con esquinas de radio r, con el centroide en (cx, cy)."""
    w = h * math.sqrt(3) / 2
    x0 = cx - w / 3
    pts = [(k(x0), k(cy - h / 2)), (k(x0 + w), k(cy)), (k(x0), k(cy + h / 2))]
    gx, gy = k(cx), k(cy)
    inradius = w / 3 * SS
    f = (inradius - k(r)) / inradius
    inner = [(gx + (x - gx) * f, gy + (y - gy) * f) for x, y in pts]
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.polygon(inner, fill=255)
    for i, a in enumerate(inner):
        b = inner[(i + 1) % 3]
        d.line([a, b], fill=255, width=2 * k(r))
        d.ellipse([a[0] - k(r), a[1] - k(r), a[0] + k(r), a[1] + k(r)], fill=255)
    return m


img = grad((20, 28, 26), (6, 8, 8), 90)
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse([k(200), k(200), k(824), k(824)], fill=70)
img.paste((50, 180, 140), (0, 0), glow.filter(ImageFilter.GaussianBlur(k(160))))

cx, cy, R, W = 512, 512, 318, 64
box = [k(cx - R), k(cy - R), k(cx + R), k(cy + R)]
track = Image.new("L", (S, S), 0)
ImageDraw.Draw(track).ellipse(box, outline=255, width=k(W))
img.paste((40, 58, 52), (0, 0), track)

# Tramo ya visto: desde arriba en sentido horario hasta el punto, con el inicio redondeado
start, end = -90, 200
rr = R - W / 2
arc = Image.new("L", (S, S), 0)
d = ImageDraw.Draw(arc)
d.arc(box, start, end, fill=255, width=k(W))
px, py = cx + rr * math.cos(math.radians(start)), cy + rr * math.sin(math.radians(start))
d.ellipse([k(px - W / 2), k(py - W / 2), k(px + W / 2), k(py + W / 2)], fill=255)
img.paste(grad((150, 247, 210), (32, 170, 128), 30), (0, 0), arc)

# Punto de búsqueda, separado del anillo por un hueco oscuro
px, py = cx + rr * math.cos(math.radians(end)), cy + rr * math.sin(math.radians(end))
ImageDraw.Draw(img).ellipse([k(px - 80), k(py - 80), k(px + 80), k(py + 80)], fill=(10, 14, 13))
ImageDraw.Draw(img).ellipse([k(px - 62), k(py - 62), k(px + 62), k(py + 62)], fill=(255, 255, 255))

img.paste((255, 255, 255), (0, 0), play(cx + 6, cy, 300, 42))

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("icono:", OUT)
