#!/usr/bin/env python3
"""16:9 SVG of Worker path from app frame to display. UTF-8 only."""

from pathlib import Path
from xml.sax.saxutils import escape

W, H = 1600, 900
OUT_SVG = Path("/workspace/docs/MarlWorkerFrame.slide.zh.svg")
OUT_HTML = Path("/workspace/docs/MarlWorkerFrame.slide.zh.html")

INK = "#1c1b16"
MUTED = "#5c584e"
LINE = "#c8c1b0"
BG = "#fbf9f4"
WHITE = "#ffffff"
OTHER_FILL = "#f7f4ee"
APP_FILL, APP_LINE = "#d6e8f8", "#1565c0"
SF_FILL, SF_LINE = "#f0e4f6", "#6a1b9a"
SCREEN_FILL, SCREEN_LINE = "#e4f0e2", "#2e7d32"
ARROW = "#9a9486"

FONT = "sans-serif"


def T(s):
    return escape(s, {"'": "&apos;"})


def box_style(kind):
    if kind == "app":
        return APP_FILL, APP_LINE, APP_LINE
    if kind == "sf":
        return SF_FILL, SF_LINE, SF_LINE
    if kind == "screen":
        return SCREEN_FILL, SCREEN_LINE, SCREEN_LINE
    return OTHER_FILL, LINE, MUTED


def rounded(x, y, w, h, rx, fill, stroke, sw=1.5):
    return (
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
        f'rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>'
    )


def text(x, y, s, size, fill=INK, weight="400", anchor="start"):
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" '
        f'font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
        f'fill="{fill}">{T(s)}</text>'
    )


def arrow_right(x, cy, w=22, h=14):
    x2 = x + w
    return (
        f'<polygon points="{x:.1f},{cy - h / 2:.1f} {x2:.1f},{cy:.1f} '
        f'{x:.1f},{cy + h / 2:.1f}" fill="{ARROW}"/>'
    )


def arrow_down(cx, y, w=14, h=18):
    return (
        f'<polygon points="{cx - w / 2:.1f},{y:.1f} {cx + w / 2:.1f},{y:.1f} '
        f'{cx:.1f},{y + h:.1f}" fill="{ARROW}"/>'
    )


def add_box(x, y, w, h, who, title, kind):
    fill, stroke, who_c = box_style(kind)
    parts = [rounded(x, y, w, h, 10, fill, stroke, 1.6)]
    if kind in ("app", "sf"):
        parts.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="7" height="{h:.1f}" '
            f'rx="2" fill="{stroke}"/>'
        )
    parts.append(text(x + 16, y + 28, who, 13, who_c, "700"))
    # title may be two lines
    if isinstance(title, tuple):
        parts.append(text(x + 16, y + 54, title[0], 17, INK, "700"))
        parts.append(text(x + 16, y + 76, title[1], 17, INK, "700"))
    else:
        parts.append(text(x + 16, y + 58, title, 17, INK, "700"))
    return "\n".join(parts)


def place_row(boxes, y, left, right, box_h):
    n = len(boxes)
    gap = 28
    usable = right - left
    bw = (usable - gap * (n - 1)) / n
    parts = []
    xs = []
    for i, spec in enumerate(boxes):
        x = left + i * (bw + gap)
        parts.append(add_box(x, y, bw, box_h, spec["who"], spec["title"], spec["kind"]))
        xs.append((x, bw))
        if i < n - 1:
            parts.append(arrow_right(x + bw + 3, y + box_h / 2))
    return "\n".join(parts), xs


def chip(x, y, w, label, fill, stroke, color):
    h = 28
    return "\n".join(
        [
            rounded(x, y, w, h, 14, fill, stroke, 1.2),
            text(x + w / 2, y + 19, label, 13, color, "700", "middle"),
        ]
    )


def build_svg():
    left, right = 32, 1568
    box_h = 108
    parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
        f'width="{W}" height="{H}" role="img" aria-labelledby="title desc">',
        '<title id="title">从应用渲染循环到上屏：Worker 在哪</title>',
        '<desc id="desc">一帧里 Worker 只出现两次：应用 pastel 线程池画像素，'
        "SurfaceFlinger pastel 线程池做合成。中间提交、拷 AHB、上屏都不是 Worker。</desc>",
        f'<rect width="{W}" height="{H}" fill="{BG}"/>',
        text(32, 44, "从应用渲染循环到上屏：Worker 在哪", 32, INK, "700"),
        text(
            32,
            72,
            "redroid guest · vulkan.pastel.so · 一帧里 Worker 只出现两次（应用池 + SurfaceFlinger 池）",
            15,
            MUTED,
        ),
        chip(1078, 28, 148, "蓝：应用 Worker", APP_FILL, APP_LINE, APP_LINE),
        chip(1236, 28, 148, "紫：SF Worker", SF_FILL, SF_LINE, SF_LINE),
        chip(1394, 28, 142, "灰：其他线程", OTHER_FILL, LINE, MUTED),
    ]

    row1 = [
        {"kind": "other", "who": "显示", "title": "1. Vsync 到了"},
        {"kind": "other", "who": "应用 UI 线程", "title": "2. 改界面、记 DisplayList"},
        {"kind": "other", "who": "RenderThread / HWUI", "title": "3. 变成 Vulkan 命令"},
        {"kind": "other", "who": "Queue 线程", "title": "4. vkQueueSubmit"},
        {"kind": "other", "who": "Renderer", "title": "5. 准备 / JIT Routine"},
    ]
    y1 = 96
    s, xs1 = place_row(row1, y1, left, right, box_h)
    parts.append(s)
    cx_drop = xs1[-1][0] + xs1[-1][1] / 2
    parts.append(arrow_down(cx_drop, y1 + box_h + 6))

    parts.append(text(left, 242, "应用进程 · vulkan.pastel.so", 15, APP_LINE, "700"))

    row2 = [
        {"kind": "app", "who": "应用 Worker", "title": "6. batch 入队  marl::schedule"},
        {"kind": "app", "who": "应用 Worker", "title": "7. 顶点 → 图元 → 像素"},
        {"kind": "other", "who": "CPU 内存", "title": "8. 颜色在 vk::Image"},
        {"kind": "other", "who": "Android 导出", "title": "9. memcpy 到 AHB，queueBuffer"},
    ]
    y2 = 254
    s, xs2 = place_row(row2, y2, left, right, box_h)
    parts.append(s)
    cx_drop = xs2[-1][0] + xs2[-1][1] / 2
    parts.append(arrow_down(cx_drop, y2 + box_h + 6))

    parts.append(
        text(left, 400, "SurfaceFlinger · 另一份 ICD，另一套 ThreadCount", 15, SF_LINE, "700")
    )

    row3 = [
        {"kind": "sf", "who": "SF 主线程", "title": "10. 排图层、Client 合成"},
        {"kind": "sf", "who": "SF Queue", "title": "11. 自己的 vkQueueSubmit"},
        {"kind": "sf", "who": "SF Worker", "title": "12. 采样各层 + 片元写出"},
        {"kind": "screen", "who": "显示 / redroid", "title": "13. 上屏"},
    ]
    y3 = 412
    s, _ = place_row(row3, y3, left, right, box_h)
    parts.append(s)

    note_y, note_h = 548, 320
    parts.append(rounded(32, note_y, 1536, note_h, 10, WHITE, LINE, 1.2))
    parts.append(text(52, note_y + 36, "一块 batch 在 Worker 里（步骤 7 / 12）", 18, INK, "700"))
    parts.append(
        text(
            52,
            note_y + 72,
            "DrawCall::run  →  marl::schedule(batch)  →  processVertices（VertexRoutine）  →  processPrimitives（SetupRoutine）  →  processPixels（PixelRoutine + sampler，四像素一组）",
            15,
            INK,
        )
    )
    parts.append(
        text(
            52,
            note_y + 102,
            "没活：spinForWork 空转一会儿，再 wait() 睡觉。挡住了：suspend，切纤程（Fiber），同一条 OS 线程接着干别的。",
            15,
            INK,
        )
    )
    parts.append(
        text(
            52,
            note_y + 138,
            "不是 Worker：UI 线程、RenderThread、Queue、SF 主线程。绑核只限制坐哪几把椅子；条数认 cwd 的 ThreadCount，否则 min(看见的逻辑核, 16)。应用和 SF 各走一遍这条链。",
            14,
            MUTED,
        )
    )

    # Mini legend of two Worker pools, so the 16:9 figure stands alone
    parts.append(
        rounded(52, note_y + 168, 736, 128, 8, APP_FILL, APP_LINE, 1.2)
    )
    parts.append(text(72, note_y + 198, "应用 Worker 池", 16, APP_LINE, "700"))
    parts.append(
        text(72, note_y + 226, "画这一帧应用自己的像素。Thread<NN> 在应用进程里。", 14, INK)
    )
    parts.append(
        text(72, note_y + 252, "ini / ThreadCount 看应用进程 cwd。", 14, MUTED)
    )
    parts.append(
        text(72, note_y + 278, "perf：应用侧 PixelRoutine / sampler。", 14, MUTED)
    )

    parts.append(
        rounded(808, note_y + 168, 736, 128, 8, SF_FILL, SF_LINE, 1.2)
    )
    parts.append(text(828, note_y + 198, "SF Worker 池", 16, SF_LINE, "700"))
    parts.append(
        text(828, note_y + 226, "Client 合成时再画一遍。另一份 vulkan.pastel.so。", 14, INK)
    )
    parts.append(
        text(828, note_y + 252, "ini / ThreadCount 看 SurfaceFlinger 的 cwd。", 14, MUTED)
    )
    parts.append(
        text(828, note_y + 278, "秒表场景常常比应用侧更热（全屏采样）。", 14, MUTED)
    )

    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def build_html(svg: str):
    # Inline the SVG so the 16:9 page is self-contained.
    # Strip XML declaration; keep the <svg> element.
    inner = svg.split("\n", 1)[1] if svg.startswith("<?xml") else svg
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>从应用到上屏：Worker 在哪（16:9）</title>
  <style>
    * {{ box-sizing: border-box; }}
    html, body {{
      margin: 0;
      height: 100%;
      background: #2a2824;
    }}
    .fit {{
      min-height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 12px;
    }}
    .stage {{
      width: min(100vw - 24px, calc((100vh - 24px) * 16 / 9));
      aspect-ratio: 16 / 9;
      background: {BG};
      border-radius: 8px;
      overflow: hidden;
    }}
    .stage svg {{
      display: block;
      width: 100%;
      height: 100%;
    }}
  </style>
</head>
<body>
  <div class="fit">
    <section class="stage" aria-label="16比9流程图：从应用到上屏">
{inner.rstrip()}
    </section>
  </div>
</body>
</html>
"""


def main():
    svg = build_svg()
    OUT_SVG.write_text(svg, encoding="utf-8")
    OUT_HTML.write_text(build_html(svg), encoding="utf-8")
    print("wrote", OUT_SVG, "bytes", OUT_SVG.stat().st_size)
    print("wrote", OUT_HTML, "bytes", OUT_HTML.stat().st_size)
    # sanity: no NUL, starts with xml
    raw = OUT_SVG.read_bytes()
    assert b"\x00" not in raw
    assert raw.startswith(b"<?xml")
    assert "Worker" in OUT_SVG.read_text(encoding="utf-8")


if __name__ == "__main__":
    main()
