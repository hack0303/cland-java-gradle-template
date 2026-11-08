#!/usr/bin/env python3
# ⚠️ 真源 = spec 技能 scripts/doc-guide-check.py（sha256 前12 = dc158fcb1bf1）
#   本文件是**同版副本**（模板需可独立运行，CI 无技能目录）；改判据先改技能再同步此处。
# -*- coding: utf-8 -*-
"""doc-guide-check.py —— GUIDE.md 合规体检（references/guide-md-spec.md v0.0.1）

判据（G1–G7，全部可机检；rc=0 才算合规）：
  G1 十节齐全（或该节含「不适用」+ 理由）
  G2 §3 安装章节里**每条代码块命令**后面 3 行内出现「期望/期望输出/rc=/exit」标记
  G3 §4 任务配方按**场景**命名（`### ` 标题里含「我要/场景/使用/怎么/如何/recipe」之一）且 ≥1 条
  G4 §6 常见错误 ≥3 条，且每条含**真实报错痕迹**（代码块 / 反引号 / 冒号后的原文 / "报错"字样）
  G5 §7 交付章节含可 pass/fail 判据（含 pass / 判据 / 勾选框 / 表格行）
  G6 §10 自检有一条命令（代码块内）且给期望输出
  G7 不与 SPEC.md / RULES.md 正文重复：被引用的行 ≤ 12 行（超过 ⇒ 疑似复制）

用法：python3 doc-guide-check.py [<项目根>] [--json] [--selftest]
"""
from __future__ import annotations
import argparse, json, os, re, sys

SECTIONS = [
    ("能做什么", r"能做什么|不做|能力"),
    ("前置条件", r"前置条件|前置|依赖|要求"),
    ("安装与首次运行", r"安装|首次运行|快速开始|上手"),
    ("任务配方", r"任务配方|配方|场景|recipes|Recipes"),
    ("配置项", r"配置项|配置|环境变量"),
    ("常见错误与处置", r"常见错误|错误与处置|故障|排错|troubleshoot"),
    ("交付与验收", r"交付与验收|交付|验收"),
    ("升级与回滚", r"升级与回滚|升级|回滚|rollback"),
    ("边界与安全", r"边界与安全|边界|安全"),
    ("自检", r"自检|self-?check|selftest|冒烟|smoke"),
]
EXPECT = re.compile(r"期望|expect|rc=|exit|退出码|输出：|输出:", re.I)
SCENE = re.compile(r"我要|场景|使用|怎么|如何|recipe|when", re.I)


def split_sections(md: str) -> dict:
    """按 `## ` 切节（忽略 frontmatter 与代码块内的 ##）。"""
    out, cur, buf, in_fence = {}, None, [], False
    for ln in md.splitlines():
        if ln.strip().startswith("```"):
            in_fence = not in_fence
        if not in_fence and re.match(r"^##\s+", ln):
            if cur is not None:
                out[cur] = "\n".join(buf)
            cur, buf = ln.strip("# ").strip(), []
        elif cur is not None:
            buf.append(ln)
    if cur is not None:
        out[cur] = "\n".join(buf)
    return out


def code_blocks(md: str) -> list:
    return re.findall(r"```[a-zA-Z]*\n(.*?)```", md, re.S)


def check(root: str) -> dict:
    path = None
    for cand in (os.path.join(root, "GUIDE.md"), os.path.join(root, "docs", "GUIDE.md")):
        if os.path.exists(cand):
            path = cand
            break
    if not path:
        return {"file": None, "red": [("G1", "-", "没找到 GUIDE.md（根目录或 docs/）")], "warn": []}
    md = open(path, encoding="utf-8").read()
    secs = split_sections(md)
    red, warn = [], []
    joined = "\n".join(secs.keys())

    # G1 十节齐全
    for name, pat in SECTIONS:
        if not re.search(pat, joined, re.I):
            red.append(("G1", name, "缺章节（或写「不适用 + 理由」）"))
        else:
            body = next((v for k, v in secs.items() if re.search(pat, k, re.I)), "")
            if "不适用" in body and len(re.sub(r"\s", "", body)) < 10:
                warn.append(("G1", name, "标了不适用但理由过短"))

    # G2 安装章节的命令都有期望输出
    inst = next((v for k, v in secs.items() if re.search(SECTIONS[2][1], k, re.I)), "")
    if not inst:
        red.append(("G2", "安装", "无安装章节可查"))
    else:
        # 块级判据：每个代码块 **紧随其后 4 行**（或块内以 `>` 开头）必须有期望标记
        for m in re.finditer(r"```[a-zA-Z]*\n(.*?)```", inst, re.S):
            blk, after = m.group(1), inst[m.end():m.end() + 400]
            tail = "\n".join(after.splitlines()[:4])
            inside = "\n".join(l for l in blk.splitlines() if l.strip().startswith(">"))
            if not (EXPECT.search(tail) or EXPECT.search(inside)):
                first = next((l for l in blk.strip().splitlines() if l.strip()), "")
                red.append(("G2", "安装", "代码块后无期望输出（块首：" + first[:36] + "）"))

    # G3 任务配方按场景
    recipe = next((v for k, v in secs.items() if re.search(SECTIONS[3][1], k, re.I)), "")
    subs = re.findall(r"^###\s+(.+)$", recipe, re.M)
    if not subs:
        red.append(("G3", "任务配方", "无 `###` 场景小节"))
    elif not any(SCENE.search(s) for s in subs):
        red.append(("G3", "任务配方", "小节标题不像场景：" + "；".join(s[:20] for s in subs[:3])))

    # G4 错误条目
    errs = next((v for k, v in secs.items() if re.search(SECTIONS[5][1], k, re.I)), "")
    items = re.findall(r"^###\s+(.+)$", errs, re.M) or re.findall(r"^\s*[-*]\s+\*\*(.+?)\*\*", errs, re.M)
    if len(items) < 3:
        red.append(("G4", "常见错误", f"条目 {len(items)} < 3"))
    else:
        for it in items:
            if not re.search(r"`|\[\d+\]|Error|error|错误|报错|:|：", it):
                red.append(("G4", "常见错误", "条目缺真实报错痕迹：" + it[:36]))

    # G5 交付判据
    dlv = next((v for k, v in secs.items() if re.search(SECTIONS[6][1], k, re.I)), "")
    if not re.search(r"pass|判据|\[ \]|\|\s*怎么验|验收", dlv, re.I):
        red.append(("G5", "交付与验收", "缺可 pass/fail 判据"))

    # G6 自检
    sc = next((v for k, v in secs.items() if re.search(SECTIONS[9][1], k, re.I)), "")
    if not code_blocks(sc):
        red.append(("G6", "自检", "无自检命令代码块"))
    elif not EXPECT.search(sc):
        red.append(("G6", "自检", "自检缺期望输出"))

    # G7 与 SPEC/RULES 正文重复
    for other in ("SPEC.md", "RULES.md"):
        p = os.path.join(root, other)
        if not os.path.exists(p):
            continue
        oth = {ln.strip() for ln in open(p, encoding="utf-8") if len(ln.strip()) > 25}
        dup = [ln for ln in md.splitlines() if ln.strip() in oth]
        if len(dup) > 12:
            red.append(("G7", "GUIDE", f"与 {other} 正文重复 {len(dup)} 行（应引指针，别复制）"))
    return {"file": path, "sections": len(secs), "red": red, "warn": warn}


def selftest() -> int:
    import tempfile
    bad = 0
    def chk(d, c):
        nonlocal bad
        print(("PASS " if c else "FAIL ") + d); bad += 0 if c else 1
    good = """# T
## 1. 能做什么 / 不做什么
a
## 2. 前置条件
| 项 | 要求 |
## 3. 安装与首次运行
```bash
$ ./install.sh
ok 1.0 installed
```
> 期望：`ok 1.0 installed`，rc=0
## 4. 任务配方
### 4.1 我要跑一次
```bash
$ t run
done
```
## 5. 配置项
无
## 6. 常见错误与处置
### 6.1 `MEM_HOME not found`
- 原因：路径不存在
### 6.2 `rc=5 IO error`
- 原因：目录只读
### 6.3 `permission denied`
- 原因：无权限
## 7. 交付与验收
| 判据 | 怎么验 | pass 条件 |
|---|---|---|
## 8. 升级与回滚
不适用：本工具无状态。
## 9. 边界与安全
不写远端。
## 10. 自检
```bash
$ ./selfcheck.sh
PASS 5/5
```
期望：PASS 5/5
"""
    tmp = tempfile.mkdtemp()
    open(os.path.join(tmp, "GUIDE.md"), "w").write(good)
    r = check(tmp)
    chk("规范样例 ⇒ 无红", not r["red"])
    open(os.path.join(tmp, "GUIDE.md"), "w").write(good.replace("> 期望：`ok 1.0 installed`，rc=0", ""))
    chk("删期望输出 ⇒ G2 红", any(c == "G2" for c, _, _ in check(tmp)["red"]))
    open(os.path.join(tmp, "GUIDE.md"), "w").write(good.replace("### 6.3 `permission denied`\n- 原因：无权限", ""))
    chk("错误条目不足 ⇒ G4 红", any(c == "G4" for c, _, _ in check(tmp)["red"]))
    open(os.path.join(tmp, "GUIDE.md"), "w").write(good.replace("## 10. 自检", "## 其他"))
    chk("删自检章 ⇒ G1 红", any(c == "G1" for c, _, _ in check(tmp)["red"]))
    os.remove(os.path.join(tmp, "GUIDE.md"))
    chk("缺文件 ⇒ G1 红", any(c == "G1" for c, _, _ in check(tmp)["red"]))
    print("\n%s（%d 条失败）" % ("✅ selftest 全过" if not bad else "❌ selftest 有失败", bad))
    return 0 if not bad else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=".")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if not os.path.isdir(a.root):
        print("❌ 目录不存在 ⇒ 不可判", file=sys.stderr); return 2
    r = check(a.root)
    if a.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
    else:
        print(f"GUIDE 体检：{r['file'] or '(缺)'} · 章节 {r.get('sections', 0)} · 红 {len(r['red'])} · WARN {len(r['warn'])}")
        for c, p, w in r["red"]:
            print(f"❌ {c} {p:12s} {w}")
        for c, p, w in r["warn"]:
            print(f"⚠️ {c} {p:12s} {w}")
        if not r["red"]:
            print("✅ GUIDE.md 合规")
    return 1 if r["red"] else 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv else main())
