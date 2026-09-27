#!/usr/bin/env python3
"""生成 App 图标（AppIcon.appiconset）。用法：python3 scripts/make_icon.py"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "App", "Assets.xcassets", "AppIcon.appiconset")
S = 2048  # 以 2 倍尺寸绘制后缩小，边缘更平滑


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def draw_icon():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    margin = int(S * 100 / 1024)
    box = (margin, margin, S - margin, S - margin)
    radius = int(S * 185 / 1024)

    # 阴影
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (box[0], box[1] + S * 0.012, box[2], box[3] + S * 0.012), radius=radius, fill=(0, 0, 0, 110)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.018))
    img.alpha_composite(shadow)

    # 渐变背景
    top, bottom = (98, 60, 245, 255), (24, 160, 255, 255)
    gradient = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(gradient)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S))
    img.paste(gradient, (0, 0), rounded_mask((S, S), box, radius))

    d = ImageDraw.Draw(img)
    u = S / 1024

    # 对话气泡
    bubble = (250 * u, 215 * u, 774 * u, 560 * u)
    d.rounded_rectangle(bubble, radius=95 * u, fill=(255, 255, 255, 255))
    d.polygon([(330 * u, 540 * u), (300 * u, 640 * u), (430 * u, 548 * u)], fill=(255, 255, 255, 255))

    # 气泡内的声波
    heights = [70, 150, 230, 130, 200, 95, 55]
    bar_w = 38 * u
    gap = 26 * u
    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x = (S - total) / 2
    cy = (bubble[1] + bubble[3]) / 2
    for i, h in enumerate(heights):
        color = lerp(top, bottom, i / (len(heights) - 1))
        d.rounded_rectangle((x, cy - h * u / 2, x + bar_w, cy + h * u / 2), radius=bar_w / 2, fill=color)
        x += bar_w + gap

    # 字幕条
    d.rounded_rectangle((250 * u, 680 * u, 774 * u, 742 * u), radius=31 * u, fill=(255, 214, 10, 255))
    d.rounded_rectangle((330 * u, 780 * u, 694 * u, 830 * u), radius=25 * u, fill=(255, 255, 255, 225))
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    master = draw_icon().resize((1024, 1024), Image.LANCZOS)
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}", "filename": name})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    with open(os.path.join(os.path.dirname(OUT), "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    master.save(os.path.join(ROOT, "docs", "icon.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
