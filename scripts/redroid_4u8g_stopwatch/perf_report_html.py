#!/usr/bin/env python3
"""Turn perf report --stdio + collapsed stacks into a single HTML file."""
import html
import os
import re
import sys
from collections import defaultdict

OVERHEAD = re.compile(
    r"^\s*([0-9]+\.[0-9]+)%\s+(\S+)\s+(\S+)\s+(?:\[.\]\s+)?(.*)$"
)


def parse_report(path):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = OVERHEAD.match(line.rstrip("\n"))
            if not m:
                continue
            pct, comm, dso, sym = m.group(1), m.group(2), m.group(3), m.group(4)
            rows.append((float(pct), comm, dso, sym.strip()))
    return rows


def bars(rows, key_fn, limit=40):
    buckets = defaultdict(float)
    for pct, comm, dso, sym in rows:
        buckets[key_fn(pct, comm, dso, sym)] += pct
    items = sorted(buckets.items(), key=lambda kv: -kv[1])[:limit]
    if not items:
        return "<p>没有解析到样本。检查 perf.data 或 --symfs。</p>"
    mx = items[0][1] or 1.0
    out = ['<div class="bars">']
    for name, pct in items:
        width = max(0.5, 100.0 * pct / mx)
        out.append(
            '<div class="row"><span class="pct">{:.2f}%</span>'
            '<div class="bar" style="width:{:.1f}%"></div>'
            '<code>{}</code></div>'.format(
                pct, width, html.escape(name)
            )
        )
    out.append("</div>")
    return "\n".join(out)


def stack_table(path, limit=40):
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return "<p>没有调用栈（采样时可能没带上 --call-graph）。上面的条形图仍可用。</p>"
    rows = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            # collapsed: "frame;frame;frame count"
            parts = line.rsplit(" ", 1)
            if len(parts) != 2 or not parts[1].isdigit():
                continue
            rows.append((int(parts[1]), parts[0]))
    rows.sort(reverse=True)
    total = sum(c for c, _ in rows) or 1
    rows = rows[:limit]
    out = ["<ol class='stacks'>"]
    for count, stack in rows:
        pct = 100.0 * count / total
        pretty = html.escape(stack.replace(";", " ← "))
        out.append(
            "<li><span class='pct'>{:.2f}%</span> <code>{}</code></li>".format(
                pct, pretty
            )
        )
    out.append("</ol>")
    return "\n".join(out)


def main():
    if len(sys.argv) < 5:
        sys.stderr.write(
            "usage: perf_report_html.py report-dso.txt report-sym.txt "
            "collapsed.txt out.html\n"
        )
        return 2
    dso_rows = parse_report(sys.argv[1])
    sym_rows = parse_report(sys.argv[2])
    body = """<!DOCTYPE html>
<meta charset="utf-8">
<title>stopwatch perf</title>
<style>
body {{ font: 14px/1.45 sans-serif; margin: 24px; color: #111; }}
h1,h2 {{ font-weight: 600; }}
.bars .row {{ display: flex; align-items: center; gap: 8px; margin: 4px 0; }}
.pct {{ width: 4.5em; text-align: right; font-variant-numeric: tabular-nums; }}
.bar {{ height: 14px; background: #3b82f6; flex: 0 0 auto; }}
code {{ font: 12px/1.4 ui-monospace, monospace; word-break: break-all; }}
.note {{ background: #f3f4f6; padding: 12px 16px; }}
.stacks li {{ margin: 8px 0; }}
</style>
<h1>秒表负载 perf</h1>
<p class="note">先看「按库」：匿名页 <code>[unknown]</code> 若 maps 里有
<code>swiftshader_jit</code>，就是 CPU 在算像素。SwiftShader 默认不写
<code>/tmp/perf-PID.map</code>，所以 JIT 不会显示 <code>PixelRoutine_XXXX</code>。
本目录里的 map 只把整段 JIT 标成 <code>swiftshader_jit</code>。
<code>--symfs</code> 用来解析容器里的 <code>libhwui.so</code> /
<code>vulkan.pastel.so</code>。</p>
<h2>按进程 + 库（self）</h2>
{dso}
<h2>按进程 + 符号（self）</h2>
{sym}
<h2>最热调用栈（若采样带了 fp）</h2>
{stacks}
""".format(
        dso=bars(dso_rows, lambda p, c, d, s: "{}  {}".format(c, d)),
        sym=bars(sym_rows, lambda p, c, d, s: "{}  {}  {}".format(c, d, s)),
        stacks=stack_table(sys.argv[3]),
    )
    with open(sys.argv[4], "w", encoding="utf-8") as fh:
        fh.write(body)
    print("wrote", sys.argv[4])
    return 0


if __name__ == "__main__":
    sys.exit(main())
