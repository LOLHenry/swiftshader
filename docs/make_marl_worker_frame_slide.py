#!/usr/bin/env python3
"""16:9 HTML slide from the first MarlWorkerFrame.zh.html, not the PPT."""

from html import escape
from pathlib import Path
import re

OUT_HTML = Path("/workspace/docs/MarlWorkerFrame.slide.zh.html")
OUT_SVG = Path("/workspace/docs/MarlWorkerFrame.slide.zh.svg")

# First-version HTML copy. kind matches the original classes: worker / sf / other.
STEPS = [
    {
        "kind": "other",
        "who": "显示 / Choreographer",
        "title": "1. Vsync 到了",
        "detail": "系统按目标帧率（如 30）发垂直同步。应用主线程被叫醒，开始这一帧。",
    },
    {
        "kind": "other",
        "who": "应用 UI 线程",
        "title": "2. 改界面、记显示列表（DisplayList）",
        "detail": "应用改 View（文字、布局、可见性），再 invalidate。UI 线程只把「这一帧画什么」记成一份操作清单，还不是像素。真正画图不在这条线程，交给 RenderThread。",
    },
    {
        "kind": "other",
        "who": "应用 RenderThread + HWUI / Skia",
        "title": "3. 把显示列表变成 Vulkan 命令",
        "detail": "GLES 会先经 ANGLE 再进 pastel；Vulkan 直接进 pastel。这里是 `vkCmdDraw` 等，只往命令缓冲里记，几乎不算像素。",
    },
    {
        "kind": "other",
        "who": "应用 Vulkan Queue 线程（Queue<…>）",
        "title": "4. `vkQueueSubmit`：命令真正开始执行",
        "detail": "`Queue::submit` 把任务丢进内部队列；`taskLoop` 里 `bind()` 调度器后逐条执行命令缓冲。这条线程不是 Thread<NN>。",
    },
    {
        "kind": "other",
        "who": "SwiftShader Renderer",
        "title": "5. `Renderer::draw`：为这次绘制准备 Routine",
        "detail": "按管线状态找或现场 JIT：VertexRoutine、SetupRoutine、PixelRoutine、sampler。第一次会编，之后复用。",
    },
    {
        "kind": "worker",
        "who": "应用 Worker · marl::schedule",
        "title": "6. 切成 batch，丢进线程池 —— Worker 从这里开始干活",
        "detail": "`DrawCall::run` 按最多约 128 个图元一块 `marl::schedule`。哪条 Worker 空谁拿。",
    },
    {
        "kind": "worker",
        "who": "同一条应用 Worker 上顺序做完一块",
        "title": "7. 顶点 → 图元 → 像素",
        "detail": "`processVertices` 跑顶点 JIT；`processPrimitives` 裁剪、装配、边方程；`processPixels` 四像素一组光栅化 + 片元 + 采样 + 写颜色/深度。perf 里的 PixelRoutine / sampler 主要在这。",
    },
    {
        "kind": "other",
        "who": "应用进程 · CPU 上的 vk::Image",
        "title": "8. 这一帧的颜色已经在内存里",
        "detail": "没有 GPU framebuffer。Queue 在 fence 前会 `renderer->synchronize()`，等所有 batch 做完。",
    },
    {
        "kind": "other",
        "who": "应用 · Android 图像导出",
        "title": "9. 拷到 AHardwareBuffer，交给 BufferQueue",
        "detail": "`vkQueueSignalReleaseImageANDROID` → 按行 memcpy 到 AHB（memfd）。然后 `queueBuffer` 给 SurfaceFlinger。这一步常是 memcpy 热点，不是 Worker 空转。",
    },
    {
        "kind": "sf",
        "who": "SurfaceFlinger 主线程",
        "title": "10. 合成这一屏：各层排在哪",
        "detail": "读应用刚交来的 buffer，加上状态栏、壁纸等。能走 HWC 直通就少算像素；走 Client 合成就要再画一遍。",
    },
    {
        "kind": "sf",
        "who": "SF 的 pastel（另一份 ICD）",
        "title": "11. SF 自己的 vkQueueSubmit",
        "detail": "合成 shader 再走一遍 4→7，但是 **SF 进程里另一套 Worker**，ini、ThreadCount 各算各的。",
    },
    {
        "kind": "worker",
        "who": "SF Worker · Thread<NN>",
        "title": "12. 采样各层、做片元、写出合成结果",
        "detail": "Client 合成时，SF 侧 PixelRoutine + bilinear sampler 经常比应用侧更热：全屏图层、逐像素采样。",
    },
    {
        "kind": "other",
        "who": "显示 / redroid",
        "title": "13. 上屏",
        "detail": "合成结果进 framebuffer / 虚拟屏。scrcpy 另走一条编码，不是这条 pastel Worker。",
    },
]

# 5-column snake: 1→2→3→4→5 ↓ 6←7←8←9? No: 5 ↓ onto 6 (right),
# then left 6→7→8→9, then 9 ↓ onto 10, then 10→11→12→13.
CARD_COL = (1, 3, 5, 7, 9)  # CSS grid columns for the five card slots


def rich(text: str) -> str:
    """Escape, then restore `code` and **bold** from the first HTML."""
    s = escape(text)

    def code(m):
        return f"<code>{m.group(1)}</code>"

    s = re.sub(r"`([^`]+)`", code, s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    return s


def card(step: dict) -> str:
    return (
        f'<article class="step {step["kind"]}">'
        f'<div class="who">{rich(step["who"])}</div>'
        f'<div class="title">{rich(step["title"])}</div>'
        f'<div class="detail">{rich(step["detail"])}</div>'
        f"</article>"
    )


def placed_card(step: dict, col: int, row: int) -> str:
    html = card(step)
    return html.replace(
        "<article ",
        f'<article style="grid-column:{col};grid-row:{row}" ',
        1,
    )


def arr(ch: str, col: int, row: int) -> str:
    return (
        f'<div class="arr" style="grid-column:{col};grid-row:{row}" '
        f'aria-hidden="true">{ch}</div>'
    )


def flow_html() -> str:
    """Snake: 1→5 down to 6, row 2 right-to-left to 9, down to 10→13."""
    bits = []
    # Row 1 LTR: slots 0-4 = steps 1-5
    for i in range(5):
        bits.append(placed_card(STEPS[i], CARD_COL[i], 1))
        if i < 4:
            bits.append(arr("→", CARD_COL[i] + 1, 1))
    bits.append(arr("↓", CARD_COL[4], 2))
    # Row 2 RTL: slot 4=6, 3=7, 2=8, 1=9
    for i, slot in enumerate((4, 3, 2, 1)):
        bits.append(placed_card(STEPS[5 + i], CARD_COL[slot], 3))
    for slot in (4, 3, 2):
        bits.append(arr("←", CARD_COL[slot] - 1, 3))
    bits.append(arr("↓", CARD_COL[1], 4))
    # Row 3 LTR: slot 1=10, 2=11, 3=12, 4=13
    for i, slot in enumerate((1, 2, 3, 4)):
        bits.append(placed_card(STEPS[9 + i], CARD_COL[slot], 5))
        if i < 3:
            bits.append(arr("→", CARD_COL[slot] + 1, 5))
    return "\n".join(bits)


HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>从应用渲染循环到上屏：Worker 在哪（16:9）</title>
  <style>
    * { box-sizing: border-box; }
    html, body {
      margin: 0;
      height: 100%;
      background: #2a2824;
    }
    .fit {
      width: 100%;
      height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .stage {
      position: relative;
      width: min(100vw, calc(100vh * 16 / 9));
      height: min(100vh, calc(100vw * 9 / 16));
      overflow: hidden;
      background: #f6f4ef;
      color: #1c1b16;
      font-family: system-ui, -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
    }
    .canvas {
      position: absolute;
      top: 0;
      left: 0;
      width: 1920px;
      height: 1080px;
      transform-origin: 0 0;
      padding: 20px 24px 18px;
      display: flex;
      flex-direction: column;
      gap: 10px;
    }
    header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 16px;
      flex: 0 0 auto;
    }
    h1 {
      margin: 0;
      font-size: 32px;
      line-height: 1.2;
    }
    .sub {
      margin: 6px 0 0;
      font-size: 16px;
      color: #5c584e;
    }
    .sub code, .step code, .batch code, .note code {
      font-family: ui-monospace, "Cascadia Code", "Courier New", monospace;
      font-size: 0.92em;
      background: #f3efe4;
      padding: 1px 5px;
      border-radius: 4px;
    }
    .legend { display: flex; gap: 8px; flex-shrink: 0; padding-top: 6px; }
    .legend span {
      display: inline-block;
      padding: 4px 10px;
      border-radius: 4px;
      border: 1px solid #d9d3c5;
      font-size: 14px;
      background: #fff;
    }
    .legend .w { background: #e3eef9; border-color: #90b4e0; }
    .legend .s { background: #f3e8f8; border-color: #ce93d8; }
    .lead {
      flex: 0 0 auto;
      background: #e8f0e4;
      border: 1px solid #b7c9b0;
      border-radius: 8px;
      padding: 10px 16px;
      font-size: 17px;
      line-height: 1.45;
      margin: 0;
    }
    .flow {
      flex: 1 1 auto;
      min-height: 0;
      display: grid;
      grid-template-columns: 1fr 22px 1fr 22px 1fr 22px 1fr 22px 1fr;
      grid-template-rows: 1fr 22px 1fr 22px 1fr;
      column-gap: 0;
      row-gap: 0;
    }
    .arr {
      display: flex;
      align-items: center;
      justify-content: center;
      color: #5c584e;
      font-size: 20px;
      font-weight: 700;
      line-height: 1;
    }
    .step {
      min-width: 0;
      min-height: 0;
      background: #fff;
      border: 1px solid #d9d3c5;
      border-radius: 8px;
      padding: 8px 10px 8px;
      display: flex;
      flex-direction: column;
    }
    .step.worker { background: #e3eef9; border-color: #90b4e0; }
    .step.sf { background: #f3e8f8; border-color: #ce93d8; }
    .who {
      font-size: 12px;
      font-weight: 700;
      color: #5c584e;
      line-height: 1.3;
    }
    .step.worker .who { color: #1565c0; }
    .step.sf .who { color: #6a1b9a; }
    .title {
      font-size: 15px;
      font-weight: 650;
      line-height: 1.3;
      margin-top: 3px;
    }
    .detail {
      font-size: 13px;
      color: #5c584e;
      line-height: 1.35;
      margin-top: 4px;
    }
    .bottom {
      flex: 0 0 268px;
      display: grid;
      grid-template-columns: 1.15fr 1fr;
      gap: 12px;
      min-height: 0;
    }
    .panel {
      background: #fff;
      border: 1px solid #d9d3c5;
      border-radius: 8px;
      padding: 10px 14px 8px;
      min-height: 0;
      overflow: hidden;
    }
    .panel h2 {
      margin: 0 0 6px;
      font-size: 16px;
    }
    .batch pre {
      margin: 0;
      white-space: pre-wrap;
      font-family: ui-monospace, "Cascadia Code", "Courier New", monospace;
      font-size: 13px;
      line-height: 1.4;
      color: #1c1b16;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th, td {
      border: 1px solid #d9d3c5;
      padding: 4px 7px;
      text-align: left;
      vertical-align: top;
    }
    th { background: #f3efe4; font-weight: 650; }
    .foot {
      flex: 0 0 auto;
      font-size: 13px;
      color: #5c584e;
      line-height: 1.4;
    }
  </style>
</head>
<body>
  <div class="fit">
    <section class="stage" aria-label="16比9：从应用到上屏，内容同第一版 HTML">
      <div class="canvas">
        <header>
          <div>
            <h1>从应用渲染循环到上屏：Worker 在哪</h1>
            <p class="sub">redroid guest + <code>vulkan.pastel.so</code> · 普通应用走 HWUI / Vulkan 这一路</p>
          </div>
          <p class="legend">
            <span class="w">蓝：应用 Worker（Thread&lt;NN&gt;）</span>
            <span class="s">紫：SF Worker（另一份 ICD）</span>
            <span>白：别的线程</span>
          </p>
        </header>
        <p class="lead">一帧里 Worker 只出现两次：<strong>应用自己的 pastel 线程池</strong>画应用的像素，<strong>SurfaceFlinger 自己的 pastel 线程池</strong>做合成。中间提交命令、排队、拷到 AHardwareBuffer、上屏，都不是 Worker 做的。</p>
        <div class="flow">
__ROWS__
        </div>
        <div class="bottom">
          <div class="panel batch">
            <h2>一块 batch 在 Worker 里怎么跑</h2>
            <pre>DrawCall::run
  marl::schedule(batch)     ← 入队，哪条空闲 Worker 领走
    processVertices         ← VertexRoutine JIT
    processPrimitives       ← SetupRoutine
    processPixels           ← PixelRoutine + sampler，写 vk::Image
没有活：spinForWork（空转）→ wait() 睡觉
有活被挡住：suspend，切到另一条纤程（Fiber），同一条 OS 线程继续干别的</pre>
          </div>
          <div class="panel">
            <h2>谁在干活（别把线程认错）</h2>
            <table>
              <thead>
                <tr><th>名字</th><th>进程</th><th>干什么</th><th>是不是 Worker</th></tr>
              </thead>
              <tbody>
                <tr><td>主线程 / UI</td><td>应用</td><td>改 View、收输入</td><td>否</td></tr>
                <tr><td>RenderThread</td><td>应用</td><td>HWUI 录命令、submit</td><td>否</td></tr>
                <tr><td>Queue&lt;…&gt;</td><td>应用或 SF</td><td>执行命令缓冲、synchronize</td><td>否（Queue 线程）</td></tr>
                <tr><td>Thread&lt;NN&gt;</td><td>应用</td><td>算应用的像素</td><td><strong>是</strong></td></tr>
                <tr><td>surfaceflinger</td><td>SF</td><td>图层决策、交合成</td><td>否</td></tr>
                <tr><td>Thread&lt;NN&gt;</td><td>SF</td><td>算合成像素</td><td><strong>是</strong></td></tr>
              </tbody>
            </table>
          </div>
        </div>
        <p class="foot">应用和 SF 各加载一份 <code>vulkan.pastel.so</code>，各有一份 marl 池子。4 核上看到两套 <code>Thread&lt;00&gt;…</code> 是正常的。上屏：<code>vkQueueSignalReleaseImageANDROID</code> → AHB，不是桌面的 <code>vkQueuePresentKHR</code>。</p>
      </div>
    </section>
  </div>
  <script>
    (function () {
      var stage = document.querySelector(".stage");
      var canvas = document.querySelector(".canvas");
      function fit() {
        canvas.style.transform = "scale(" + (stage.clientWidth / 1920) + ")";
      }
      fit();
      if (window.ResizeObserver) new ResizeObserver(fit).observe(stage);
      window.addEventListener("resize", fit);
    })();
  </script>
</body>
</html>
"""


def wrap_plain(text: str, max_chars: int) -> list[str]:
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = text.replace("**", "")
    lines, cur = [], ""
    for ch in text:
        cur += ch
        wide = sum(2 if ord(c) > 127 else 1 for c in cur)
        if wide >= max_chars * 2:
            lines.append(cur)
            cur = ""
    if cur:
        lines.append(cur)
    return lines or [""]


def build_svg() -> str:
    """Flat 16:9 SVG with the same first-HTML copy, for markdown preview."""
    W, H = 1920, 1080
    parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img">',
        '<rect width="1920" height="1080" fill="#f6f4ef"/>',
        '<text x="24" y="42" font-family="sans-serif" font-size="32" font-weight="700" fill="#1c1b16">从应用渲染循环到上屏：Worker 在哪</text>',
        '<text x="24" y="68" font-family="sans-serif" font-size="16" fill="#5c584e">redroid guest + vulkan.pastel.so · 普通应用走 HWUI / Vulkan 这一路</text>',
        '<rect x="1328" y="20" width="196" height="26" rx="4" fill="#e3eef9" stroke="#90b4e0"/>',
        '<text x="1426" y="38" text-anchor="middle" font-family="sans-serif" font-size="13" fill="#1c1b16">蓝：应用 Worker（Thread&lt;NN&gt;）</text>',
        '<rect x="1532" y="20" width="178" height="26" rx="4" fill="#f3e8f8" stroke="#ce93d8"/>',
        '<text x="1621" y="38" text-anchor="middle" font-family="sans-serif" font-size="13" fill="#1c1b16">紫：SF Worker（另一份 ICD）</text>',
        '<rect x="1718" y="20" width="178" height="26" rx="4" fill="#ffffff" stroke="#d9d3c5"/>',
        '<text x="1807" y="38" text-anchor="middle" font-family="sans-serif" font-size="13" fill="#1c1b16">白：别的线程</text>',
        '<rect x="24" y="84" width="1872" height="52" rx="8" fill="#e8f0e4" stroke="#b7c9b0"/>',
        '<text x="40" y="106" font-family="sans-serif" font-size="16" fill="#1c1b16">一帧里 Worker 只出现两次：应用自己的 pastel 线程池画应用的像素，SurfaceFlinger 自己的 pastel 线程池做合成。</text>',
        '<text x="40" y="126" font-family="sans-serif" font-size="16" fill="#1c1b16">中间提交命令、排队、拷到 AHardwareBuffer、上屏，都不是 Worker 做的。</text>',
    ]

    def kind_fill(kind):
        if kind == "worker":
            return "#e3eef9", "#90b4e0", "#1565c0"
        if kind == "sf":
            return "#f3e8f8", "#ce93d8", "#6a1b9a"
        return "#ffffff", "#d9d3c5", "#5c584e"

    gap = 22
    left, right = 24, 1896
    bw = (right - left - gap * 4) / 5
    h = 196
    ys = [148, 368, 588]

    def slot_x(slot: int) -> float:
        return left + slot * (bw + gap)

    def draw_box(step, slot, y):
        x = slot_x(slot)
        fill, stroke, who_c = kind_fill(step["kind"])
        parts.append(
            f'<rect x="{x:.1f}" y="{y}" width="{bw:.1f}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}"/>'
        )
        tw = step["title"].replace("`", "")
        parts.append(
            f'<text x="{x + 12:.1f}" y="{y + 22}" font-family="sans-serif" font-size="12" font-weight="700" fill="{who_c}">{escape(step["who"])}</text>'
        )
        ty = y + 44
        for line in wrap_plain(tw, int(bw / 15))[:2]:
            parts.append(
                f'<text x="{x + 12:.1f}" y="{ty}" font-family="sans-serif" font-size="15" font-weight="700" fill="#1c1b16">{escape(line)}</text>'
            )
            ty += 20
        for line in wrap_plain(step["detail"], int(bw / 13))[:5]:
            parts.append(
                f'<text x="{x + 12:.1f}" y="{ty + 4}" font-family="sans-serif" font-size="13" fill="#5c584e">{escape(line)}</text>'
            )
            ty += 18

    def arrow_h(slot_from, slot_to, y, ch):
        x1 = slot_x(slot_from) + bw
        x2 = slot_x(slot_to)
        mx = (x1 + x2) / 2
        parts.append(
            f'<text x="{mx:.1f}" y="{y + h / 2 + 6:.1f}" text-anchor="middle" font-family="sans-serif" font-size="18" font-weight="700" fill="#5c584e">{ch}</text>'
        )

    def arrow_v(slot, y0, y1):
        cx = slot_x(slot) + bw / 2
        parts.append(
            f'<text x="{cx:.1f}" y="{(y0 + h + y1) / 2 + 6:.1f}" text-anchor="middle" font-family="sans-serif" font-size="18" font-weight="700" fill="#5c584e">↓</text>'
        )

    for i in range(5):
        draw_box(STEPS[i], i, ys[0])
        if i < 4:
            arrow_h(i, i + 1, ys[0], "→")
    arrow_v(4, ys[0], ys[1])
    for i, slot in enumerate((4, 3, 2, 1)):
        draw_box(STEPS[5 + i], slot, ys[1])
    for slot in (4, 3, 2):
        arrow_h(slot, slot - 1, ys[1], "←")
    arrow_v(1, ys[1], ys[2])
    for i, slot in enumerate((1, 2, 3, 4)):
        draw_box(STEPS[9 + i], slot, ys[2])
        if i < 3:
            arrow_h(slot, slot + 1, ys[2], "→")

    parts.append('<rect x="24" y="804" width="980" height="232" rx="8" fill="#ffffff" stroke="#d9d3c5"/>')
    parts.append(
        '<text x="40" y="828" font-family="sans-serif" font-size="16" font-weight="700" fill="#1c1b16">一块 batch 在 Worker 里怎么跑</text>'
    )
    batch = [
        "DrawCall::run",
        "  marl::schedule(batch)     ← 入队，哪条空闲 Worker 领走",
        "    processVertices         ← VertexRoutine JIT",
        "    processPrimitives       ← SetupRoutine",
        "    processPixels           ← PixelRoutine + sampler，写 vk::Image",
        "没有活：spinForWork（空转）→ wait() 睡觉",
        "有活被挡住：suspend，切到另一条纤程（Fiber），同一条 OS 线程继续干别的",
    ]
    by = 852
    for line in batch:
        parts.append(
            f'<text x="40" y="{by}" font-family="monospace" font-size="13" fill="#1c1b16">{escape(line)}</text>'
        )
        by += 18

    parts.append('<rect x="1016" y="804" width="880" height="232" rx="8" fill="#ffffff" stroke="#d9d3c5"/>')
    parts.append(
        '<text x="1032" y="828" font-family="sans-serif" font-size="16" font-weight="700" fill="#1c1b16">谁在干活（别把线程认错）</text>'
    )
    table = [
        ("名字", "进程", "干什么", "是不是 Worker"),
        ("主线程 / UI", "应用", "改 View、收输入", "否"),
        ("RenderThread", "应用", "HWUI 录命令、submit", "否"),
        ("Queue<…>", "应用或 SF", "执行命令缓冲、synchronize", "否（Queue 线程）"),
        ("Thread<NN>", "应用", "算应用的像素", "是"),
        ("surfaceflinger", "SF", "图层决策、交合成", "否"),
        ("Thread<NN>", "SF", "算合成像素", "是"),
    ]
    ty = 848
    cols = [1032, 1210, 1340, 1688]
    for ri, row in enumerate(table):
        if ri == 0:
            parts.append(f'<rect x="1028" y="{ty - 16}" width="852" height="22" fill="#f3efe4"/>')
        for ci, cell in enumerate(row):
            wt = "700" if ri == 0 or cell == "是" else "400"
            parts.append(
                f'<text x="{cols[ci]}" y="{ty}" font-family="sans-serif" font-size="13" font-weight="{wt}" fill="#1c1b16">{escape(cell)}</text>'
            )
        ty += 28

    parts.append(
        '<text x="24" y="1062" font-family="sans-serif" font-size="13" fill="#5c584e">应用和 SF 各加载一份 vulkan.pastel.so，各有一份 marl 池子。4 核上看到两套 Thread&lt;00&gt;… 是正常的。上屏：vkQueueSignalReleaseImageANDROID → AHB，不是桌面的 vkQueuePresentKHR。</text>'
    )
    parts.append("</svg>\n")
    return "\n".join(parts)


def main():
    html = HTML.replace("__ROWS__", flow_html())
    OUT_HTML.write_text(html, encoding="utf-8")
    svg = build_svg()
    OUT_SVG.write_text(svg, encoding="utf-8")
    assert b"\x00" not in OUT_HTML.read_bytes()
    assert b"\x00" not in OUT_SVG.read_bytes()
    print("wrote", OUT_HTML, OUT_HTML.stat().st_size)
    print("wrote", OUT_SVG, OUT_SVG.stat().st_size)


if __name__ == "__main__":
    main()
