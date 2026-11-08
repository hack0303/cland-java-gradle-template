#!/usr/bin/env python3
# ⚠️ gate.py runner —— **唯一真源 = commit-gate 技能资产**（skill 分发链）：
#
#   分发规则（2026-10-22 · #649 / atlas 裁定）:
#     · 各仓/模板/技能里的 gate.py 必须是本文件的**字节副本**，并带同名 sidecar
#       `gate.py.sha256` 声明真源指纹（`# SOURCE_SHA: <sha256>`）。
#     · 校验：`bash scripts/gate-selftest.sh --verify-source`
#           sha 与声明不符 ⇒ rc≠0；多份并存/指纹不一致 ⇒ WARN（--strict ⇒ rc≠0）
#     · 历史旧线（284 行版）已归档为 `gate.py.deprecated-284`，只留回溯，不得再演进。
#   再分叉视为事故：任何仓**不得**各自演进 gate.py；要改就改真源，再按 sidecar 分发。
#   RUNNER_REV 语义：机器比较**只认 REV**，改本文件必须 +1；且 REV 行必须是纯十进制
#     —— 行尾挂注释会被 check-runner-sha 判「REV 格式非法」（实测踩过）。
#     理由：允许行尾注释，就等于允许「人读到的」与「机器比较的」不一致。
"""gate.py — 提交门禁 runner (通用质量门禁, L1 校验)

由 gate.yaml 声明检查器: 文档合规 / 目录结构 / 格式化 / 测试 / 覆盖率...
  pre-commit 只跑 stage=fast 且命中暂存文件的检查器 (秒级)
  CI 跑 stage=all (全量)

gate.yaml 格式:
  gates:
    <名称>:
      cmd: "<shell 命令>"          # 任意命令检查器 (退出码 0=通过)
      type: structure              # 或内置目录结构检查器
      require: [目录]              #   (structure) 必须存在的目录
      forbid:  [目录]              #   (structure) 禁止存在的路径
      on: ["glob 模式"]            # 暂存文件命中任一模式才运行 (pre-commit 场景)
      stage: fast | slow           # fast=提交也跑; slow=仅 CI (默认 fast)
      requires: [工具]             # 缺工具 ⇒ SKIP(env)（环境问题，不当代码不合规）
                                   #   ⚠️ 只保证 PATH 上**存在**，不保证可用、更不保证用例真的执行
      evidence:                    # 可选：声明"PASS 必须有执行证据"（#650 D-1）
        any_of: [pytest_summary, junitxml_nonempty]   # 缺证据 ⇒ FAIL 并点名 collected=0

用法:
  python3 tools/gate.py [--stage fast|slow|all] [--changed] [--config gate.yaml]
                        [--only-gate <id>] [--quiet]
退出码（四段 · 门禁规范 v0.2.4 §1 三分 + validate_envelope.py 先例 · #649）:
  0 = 全部通过（含「没有 gate.yaml ⇒ N/A 跳过」）
  1 = 有门禁项失败 / 配置存在不会被解析的顶层块 / 中间态（#642）
  2 = 用法错误（argparse：未知参数、--stage 非法值、--only-gate 缺值）
  3 = 无法判定（IO/配置层）：gate.yaml 存在但读不出来（权限/编码）、
      门禁项 type 未知（已由本分支 fail-closed 记为 FAIL）、--only-gate 指向不存在的门禁项
"""

import argparse
import fnmatch
import os
import re
import subprocess
import sys

try:  # PyYAML 优先；缺失时降级到旧解析器（见 parse_config）
    import yaml as _yaml
except ImportError:  # pragma: no cover - 环境差异
    _yaml = None

DEFAULT_CONFIG = "gate.yaml"
EVIDENCE_LIST_KEY = "__evidence_any_of__"

# ---- runner 身份三件套（#638）---------------------------------------------
# version : 只供人读（发布说明/单里引用），MAJOR.MINOR.PATCH 纯数字无 v
# REV     : **机器比较只认它**，单调递增整数，改本文件必须 +1（check-runner-rev.sh 强制）
# sha     : 运行时对**本文件字节**求 sha256 前 12 位（check-runner-sha.sh 会外部重算比对）
#           ⚠️ 不许写成常量：写死会让"内容变了"看不出来，比没有更坏。
RUNNER_VERSION = "1.6.0"
# #642：merge/rebase/cherry-pick 中间态 fail-closed · #649：四段退出码 + --only-gate（REV 行必须纯净十进制）
RUNNER_REV = 17

# ── 配置解析：PyYAML 优先（#<待建> · Owner 2026-11-08）──────────────────────────
# 历史坑：旧实现是"极简 YAML 子集"手写解析器，**不处理转义** ——
#   `cmd: "test -z \"$(gofmt -l .)\""` 解析后值里留着反斜杠 ⇒ 实际执行残缺命令 ⇒
#   **门禁看起来配了、其实从没真正检查**（go 模板实锤）。能不报错却静默失效的解析器，比没有更坏。
# 现在：装了 PyYAML 就用它；没装则退回旧解析器，但只要 cmd/值里出现转义痕迹就 **fail-closed**（ConfigUnreadable），
#   绝不"用坏解析器继续跑"。


# ── 子进程环境（#32）────────────────────────────────────────────────────────
# 门禁命令**不得继承**"把 git 指向别处"的变量：从 `git commit` 的 hook 里跑时，git 会把
# `GIT_DIR` / `GIT_INDEX_FILE` 注入成**绝对路径**（worktree 才如此；普通 clone 是相对的 `.git`）。
# 检查器常见的夹具写法 `git -C <tmp> init/add/commit` **压不过 env** ⇒ 操作落到真仓：
# 实测可把 `core.bare` 改成 true、把 `[user] t/t@t` 写进真仓 config、并新增 init/fixture 提交
# （`cland-devops#42` / `chaineasy-sre#32`）。runner 是唯一公共执行点 ⇒ 在这里一次性剥离。
_GIT_ENV_LEAK = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_COMMON_DIR",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_PREFIX",
    "GIT_CONFIG_PARAMETERS",
)


def child_env() -> dict:
    """门禁子进程环境：剥掉会把 git 指向别处的 GIT_*（#32）。其余变量原样继承。"""
    return {k: v for k, v in os.environ.items() if k not in _GIT_ENV_LEAK}


def runner_sha():
    """运行时自算本文件 sha256 前 12 位；任何异常返回 ''（调用方决定如何 fail-closed）。"""
    import hashlib

    try:
        with open(os.path.abspath(__file__), "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()[:12]
    except Exception:
        return ""


def identity():
    """runner 身份串：version + rev + sha（缺失时 sha=unknown，绝不省略字段）。"""
    return f"version={RUNNER_VERSION} rev={RUNNER_REV} sha={runner_sha() or 'unknown'}"


def parse_gates(text):
    """兼容薄包装：只返回 gates（旧调用方/测试用）。"""
    return parse_config(text)[0]


def parse_config(text):
    """解析 gate.yaml → (gates, meta)。

    **PyYAML 优先**；没装 PyYAML 时退回旧子集解析器（见 `_parse_config_legacy`），
    但旧解析器无法判断转义 ⇒ 一旦值里出现 `\\` / `\"` 就 fail-closed（不静默跑残缺命令）。
    """
    if _yaml is not None:
        return _parse_config_yaml(text)
    return _parse_config_legacy(text)


_TOP_KEYS = {"gates", "expected_gates", "profile", "required_gates"}


def _parse_config_yaml(text):
    """PyYAML 路径：真实 YAML 语义（转义、引号、块列表、锚点等都按标准来）。"""
    try:
        data = _yaml.safe_load(text) or {}
    except Exception as exc:  # yaml.YAMLError 及一切解析异常
        raise ConfigUnreadable(f"gate.yaml 不是合法 YAML: {exc}") from exc
    if not isinstance(data, dict):
        raise ConfigUnreadable("gate.yaml 顶层必须是映射（mapping）")
    anomalies = [k for k in data if k not in _TOP_KEYS]
    gates = {}
    for name, cfg in (data.get("gates") or {}).items():
        cfg = cfg or {}
        if not isinstance(cfg, dict):
            raise ConfigUnreadable(f"gate '{name}' 必须是映射，实际是 {type(cfg).__name__}")
        norm = {}
        for k, v in cfg.items():
            # YAML 1.1 把裸 `on:` / `off:` 解析成布尔 True/False（PyYAML 行为）
            # ⇒ 必须映回字符串，否则 `on:` 过滤规则会**静默失效**（所有文件都不再命中）
            if k is True:
                k = "on"
            elif k is False:
                k = "off"
            if k in ("on", "require", "forbid", "requires"):
                norm[k] = list(v) if isinstance(v, (list, tuple)) else ([v] if v is not None else [])
            else:
                norm[k] = v
        gates[str(name)] = norm
    meta = {
        "expected_gates": data.get("expected_gates"),
        "profile": data.get("profile"),
        "required_gates": list(data.get("required_gates") or []),
        "anomalies": anomalies,
        "parser": "pyyaml",
    }
    return gates, meta


def _parse_config_legacy(text):
    """旧"极简 YAML 子集"解析器（无 PyYAML 时的降级路径）。

    ⚠️ **不处理转义**：值里出现 `\\` 或 `\"` 说明作者按 YAML 标准写了引号/转义，
    旧解析器会把它当字面量 ⇒ 命令残缺但"看起来配了" ⇒ 这里直接 fail-closed。
    """
    # fail-closed：旧解析器不认转义 ⇒ 见到转义痕迹就停，别用残缺命令继续跑（宁可红，不可假绿）
    for _ln, _raw in enumerate(text.splitlines(), 1):
        if re.search(r'\\"|\\\'', _raw):
            raise ConfigUnreadable(
                f"gate.yaml:{_ln} 含引号转义，而本机缺 PyYAML：旧解析器会把转义当字面量"
                f"（命令会残缺却显示已配置）⇒ 拒绝解析。装 PyYAML：pip install pyyaml"
            )
    gates, cur, list_key = {}, None, None
    anomalies = []  # 顶格未知 key（#507：缩进错误会让 gate 静默消失）
    meta = {"expected_gates": None, "profile": None, "required_gates": [], "anomalies": anomalies,
            "parser": "legacy"}
    for raw in text.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if indent == 0:
            m0 = re.match(r"^expected_gates:\s*(\d+)\s*(?:#.*)?$", s)
            if m0:
                meta["expected_gates"] = int(m0.group(1))
            elif re.match(r"^profile:\s*(.*)$", s):
                # #636：profile 声明"本仓属于哪类"，runner 据此取最小 gate 集（见 GATE_PROFILES）
                # ⚠️ 必须先去行尾注释：`profile: template   # 说明` 会把说明当成名字的一部分 ⇒
                #    UNKNOWN_PROFILE（"行尾注释坑"，与 #636 矩阵那边同族）
                raw_p = re.match(r"^profile:\s*(.*)$", s).group(1)
                meta["profile"] = raw_p.split("#")[0].strip().strip('"').strip("'")
            elif re.match(r"^required_gates:\s*(.*)$", s):
                # #636：本仓必须存在的 gate 名单（inline 列表或后续 `- name` 块列表）
                rest = re.match(r"^required_gates:\s*(.*)$", s).group(1).split("#")[0].strip()
                req = meta.setdefault("required_gates", [])
                if rest.startswith("[") and rest.endswith("]"):
                    req.extend(x.strip().strip('"').strip("'") for x in rest[1:-1].split(",") if x.strip())
                    meta["_in_required"] = False
                else:
                    meta["_in_required"] = True
            elif re.match(r"^\s*-\s+\S", s) and meta.get("_in_required"):
                # 块列表里缩进为 0 的项（少数写法）；正常走下方 indent==2 分支
                meta["required_gates"].append(s[1:].strip().strip('"').strip("'"))
            elif re.match(r"^required_gates:\s*\[", s):
                pass  # 已在上面解析
            elif s not in ("gates:",):
                anomalies.append(s)
            cur, list_key = None, None
        elif indent == 2:
            if meta.get("_in_required") and s.startswith("- "):
                meta["required_gates"].append(s[2:].strip().strip('"').strip("'"))
                continue
            meta["_in_required"] = False
            m = re.match(r"^([\w-]+):\s*(.*)$", s)
            if m:
                cur = m.group(1)
                gates.setdefault(cur, {})
                list_key = None
        elif indent == 4 and cur:
            m = re.match(r"^([\w-]+):\s*(.*)$", s)
            if m:
                key, val = m.group(1), m.group(2).strip().strip('"').strip("'")
                if val:
                    # 内联列表 `requires: ["uv","ruff"]` ⇒ 解析成列表（#649 收口发现：
                    # 直接当字符串会按字符迭代 ⇒ 报 "缺工具 ",u,v,""）
                    if val.startswith("[") and val.endswith("]"):
                        inner = val[1:-1].strip()
                        gates[cur][key] = (
                            [
                                x.strip().strip('"').strip("'")
                                for x in inner.split(",")
                                if x.strip()
                            ]
                            if inner
                            else []
                        )
                    else:
                        gates[cur][key] = val
                    list_key = None
                else:
                    gates[cur][key] = []  # 空值 -> 列表占位
                    list_key = key
            else:
                list_key = None
        elif indent == 6 and cur:
            # ① evidence: 下的子键 any_of（#650 D-1）
            m6 = re.match(r"^([\w-]+):\s*(.*)$", s)
            if m6 and m6.group(1) == "any_of":
                inner = m6.group(2).strip()
                if inner.startswith("[") and inner.endswith("]"):
                    gates[cur]["evidence_any_of"] = [
                        x.strip().strip('"').strip("'")
                        for x in inner[1:-1].split(",")
                        if x.strip()
                    ]
                    list_key = None
                else:
                    # 块状写法 `any_of:` + 缩进 8 的 `- pytest_summary`
                    # （#650 补充：此前只认内联，块状**静默不生效** ⇒ 声明了却没证据判据 = 假绿）
                    gates[cur]["evidence_any_of"] = []
                    list_key = EVIDENCE_LIST_KEY
            # ② 普通列表项（require/forbid/on/requires…）——**不能因为①而不处理**
            elif list_key:
                m = re.match(r"^-\s+(.+)$", s)
                if m:
                    tgt = (
                        gates[cur].setdefault("evidence_any_of", [])
                        if list_key == EVIDENCE_LIST_KEY
                        else gates[cur][list_key]
                    )
                    tgt.append(m.group(1).strip('"').strip("'"))
        elif indent == 8 and cur and list_key == EVIDENCE_LIST_KEY:
            # 块状 any_of 的列表项
            m = re.match(r"^-\s+(.+)$", s)
            if m:
                gates[cur].setdefault("evidence_any_of", []).append(
                    m.group(1).strip('"').strip("'")
                )
        else:
            list_key = None
    if anomalies:
        # #507 / CI-071：不静默吞掉 —— 顶格 key 不会被解析成 gate，**必须 fail-closed**（打印后继续 = 假绿）
        print(
            "ERROR gate.yaml 顶层存在未知 key（这些行不会被当成 gate，必然少跑检查）: "
            + "; ".join(anomalies),
            file=sys.stderr,
        )
    meta.pop("_in_required", None)
    return gates, meta


class ConfigUnreadable(Exception):
    """配置文件存在但读不出来（权限/编码）⇒ 无法判定，调用方返回 rc=3。"""


def load_config(path):
    """返回 (gates, meta)；文件不存在返回 (None, None)；读不出来抛 ConfigUnreadable。"""
    if not os.path.isfile(path):
        return None, None
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigUnreadable(f"{path}: {exc}") from exc
    # ⚠️ 单一解析源：meta 只由 parse_config 产出。
    #    历史坑：这里曾自带一份 expected_gates 正则 + anomalies 判定 ⇒ 新增顶层 key
    #    （profile / required_gates）会被 parse_gates 认、被这里丢 ⇒ "配置写了但没生效"（#682 家族）。
    gates, meta = parse_config(text)
    return gates, meta


# ---------------------------------------------------------------- #
# #636：仓类型 → 最小 gate 集（"纳管"的机器可读口径）
#   口径（atlas 2026-10-31）：**在 CI/生产链路上 ⇒ 纳管**；不在 ⇒ 仓内 `gate.yaml` 显式写
#   `profile: legacy` + 注释理由，**不许静默略过**（不写 profile 也不写 required_gates ⇒ 只告警，不判红，
#   但 `#636` 的舰队审计会把它点成「未声明纳管口径」）。
#   ⚠️ 名字是**契约**：改名等于让所有仓静默失去判据，改前先加别名。
# ---------------------------------------------------------------- #
GATE_PROFILES = {
    # 生成器托管（Jenkinsfile 由 base/skills-jenkins 的模板生成）——必须能证明"生成物没被手改"
    "generated-service": ["doclint", "structure", "format", "lint", "test",
                          "jenkinsfile-drift", "vendored-sync"],
    "generated-rust": ["doclint", "structure", "format", "lint", "test",
                       "jenkinsfile-drift", "vendored-sync"],
    "generated-frontend": ["doclint", "structure", "format", "lint", "test",
                           "jenkinsfile-drift", "vendored-sync"],
    # 模板仓：产出被别人继承 ⇒ 至少语法/文档/结构/格式/测试
    "template": ["doclint", "structure", "format", "lint", "test"],
    # 纯文档仓
    "docs-only": ["doclint"],
    # 角色仓 / 工具仓（#917 · atlas 2026-10-31 定「算受门禁约束，但走轻量档」）：
    #   这类仓里有**会被别人直接执行**的脚本（坏了没人知道 = 与产品仓同类风险），
    #   但没有服务、没有 build/test ⇒ 硬套 generated-* 会恒红。
    #   ⇒ 只要求：文档合规 + **语言级语法检查** + **一条 selftest**
    #     （脚本无 `--selftest` 时记 `SKIP(no-selftest)` 并计入待补清单，**不许静默绿**）。
    "tools": ["doclint", "syntax", "selftest"],
    # 显式"已评估·不纳管"（必须在 gate.yaml 注释写理由；审计把它单列，不算漏）
    "legacy": [],
}

INTERMEDIATE_MARKERS = (
    "MERGE_HEAD",
    "rebase-merge",
    "rebase-apply",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
)


def intermediate_state(root):
    """检测未完成的 merge/rebase/cherry-pick/revert 中间态（#642）。

    为什么先于任何 gate：中间态里工作区文件是**合并中间产物**，此刻的判定不代表任何提交状态；
    且中间态落在共享工作副本上，别人/下一条 cron 随时会踩到（2026-10-21：带冲突标记的 gate.yaml 被合进 master）。
    用 `git rev-parse --git-path` 而非写死 `.git/`：worktree 下真实 git 目录在 `.git/worktrees/<name>/`。
    `BISECT_*` 不在列表内 —— bisect 状态下跑门禁是合法的，拦了会造成新的假红。
    """
    for marker in INTERMEDIATE_MARKERS:
        try:
            r = subprocess.run(
                ["git", "-C", root, "rev-parse", "--git-path", marker],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except Exception:
            return None
        if r.returncode != 0:
            return None
        path = r.stdout.strip()
        if not path:
            continue
        if not os.path.isabs(path):
            path = os.path.join(root, path)
        if os.path.exists(path):
            return marker, path
    return None


def staged_files(root):
    r = subprocess.run(
        ["git", "-C", root, "diff", "--cached", "--name-only"],
        capture_output=True,
        text=True,
    )
    return [f for f in r.stdout.splitlines() if f]


def _git_modes(args: list[str]) -> dict[str, str]:
    """`git ls-files -s` / `git ls-tree -r HEAD` → {path: mode(如 100755)}。"""
    r = subprocess.run(args, capture_output=True, text=True)
    out: dict[str, str] = {}
    for ln in r.stdout.splitlines():
        if "\t" not in ln:
            continue
        meta, path = ln.split("\t", 1)
        parts = meta.split()
        if parts:
            out[path] = parts[0]
    return out


def check_exec_bit(root, changed):
    """可执行位回归守护（#456/#507；2026-11-03 `#1008` 发现重写 runner 时**丢了**，此处补回）。

    HEAD 里 mode=100755 的文件若在 index 里被改成非 100755（典型：工具重写文件把 exec 位洗成 644）
    ⇒ 报错并阻止提交。只报**回归**，不要求新增脚本必须 +x（避免对既有 644 归档脚本造成噪声）。

    ⚠️ 它必须在 gate.yaml 之外（不依赖任何配置）：这是"提交面卫生"，与项目声明无关。
    丢了它，`exec-bit-guard.test.sh` 的负控会**静默变绿**（测试绿了但能力没了 —— 这正是 `#1008` 被发现的形态）。
    """
    errs = []
    idx = _git_modes(["git", "-C", root, "ls-files", "-s"])
    head = _git_modes(["git", "-C", root, "ls-tree", "-r", "HEAD"])
    for path, m in idx.items():
        if changed is not None and path not in changed:
            continue
        if head.get(path) == "100755" and m != "100755":
            errs.append(f"{path}: HEAD=100755 -> index={m}（可执行位被洗掉）")
    return errs


def check_structure(cfg, root):
    errs = []
    for d in cfg.get("require", []) or []:
        if not os.path.isdir(os.path.join(root, d)):
            errs.append(f"missing dir: {d}")
    for d in cfg.get("forbid", []) or []:
        if os.path.exists(os.path.join(root, d)):
            errs.append(f"forbidden path exists: {d}")
    return errs


EXCLUDE_GATES: set[str] = set()


def gate_plan(name, cfg, stage, changed):
    """计算该 gate 在本次调用中的**计划状态**（不执行）。--list 与真跑共用这一段，
    保证"执行计划"和"实际执行"不会变成两个来源。"""
    if name in EXCLUDE_GATES:
        return "SKIP(excluded)"
    if cfg.get("stage") == "slow" and stage != "all":
        return "SKIP(ci-only)"
    if changed is not None:
        pats = cfg.get("on") or ["**"]
        if not any(fnmatch.fnmatch(f, p) for p in pats for f in changed):
            return "SKIP(no-match)"
    return "RUN"


def missing_required(cfg):
    """requires 里声明的工具是否都在 PATH 上（缺 ⇒ SKIP(env)，不是 FAIL）。"""
    import shutil

    missing = []
    for tool in cfg.get("requires") or []:
        if not shutil.which(tool):
            missing.append(tool)
    return missing


def has_evidence(kinds, output, root):
    """PASS 的执行证据判定（#650 D-1）：只对声明了 evidence 的 gate 生效。

    为什么：#650 实证——stub 一个同名 `uv`（或命令恒真）就能让 `test` PASS，
    而 pytest 一行没跑。rc=0 只说明"进程成功"，不说明"用例执行过"。
    """
    import re as _re
    import glob as _glob

    if "pytest_summary" in kinds:
        passed = _re.search(r"(\d+)\s+passed", output)
        collected = _re.search(r"collected\s+(\d+)", output)
        if passed and int(passed.group(1)) > 0:
            # 有 collected 行时还要求 >0（collected=0 时 pytest 也会打 "no tests ran"）
            if collected is None or int(collected.group(1)) > 0:
                return True
    if "junitxml_nonempty" in kinds:
        for pat in ("**/junit*.xml", "**/report*.xml", "**/test-results*.xml"):
            for f in _glob.glob(os.path.join(root, pat), recursive=True):
                try:
                    if (
                        os.path.getsize(f) > 0
                        and "<testcase"
                        in open(f, encoding="utf-8", errors="ignore").read()
                    ):
                        return True
                except OSError:
                    continue
    return False


def run_gate(name, cfg, root, stage, changed):
    planned = gate_plan(name, cfg, stage, changed)
    if planned != "RUN":
        return planned, True
    miss = missing_required(cfg)
    if miss:
        print(f"SKIP(env)       {name}: 缺工具 {','.join(miss)}（环境问题，不判红）")
        return "SKIP(env)", True

    gtype = cfg.get("type")
    if gtype and gtype != "structure":
        print(
            f"UNKNOWN {name}: 未知 type '{gtype}'（本 runner 只支持 structure / cmd）"
        )
        return "ERROR(type)", False
    if gtype == "structure":
        errs = check_structure(cfg, root)
        if errs:
            print(f"FAIL {name}: {'; '.join(errs)}")
            return "FAIL", False
        return "PASS", True
    cmd = cfg.get("cmd")
    if not cmd:
        print(f"FAIL {name}: missing cmd/type")
        return "FAIL", False
    r = subprocess.run(cmd, shell=True, cwd=root, capture_output=True, text=True, env=child_env())
    if r.returncode == 0 and cfg.get("evidence_any_of"):
        out_all = (r.stdout or "") + (r.stderr or "")
        if not has_evidence(cfg["evidence_any_of"], out_all, root):
            print(
                f"FAIL {name}: 无执行证据（rc=0 但 collected=0 / 无 pytest 汇总行 / 无 junitxml）"
            )
            return "FAIL", False
    out_all = (r.stdout or "") + (r.stderr or "")
    # ── warn_only 契约（#604 · 门禁规范 v0.2.6 §12 · pillar 2026-10-22）──────────
    # 声明式：gate.yaml 里写 `warn_only: true` ⇒ 无论 rc 都判 PASS，且**完整**打印输出。
    # 为什么不是"嗅探 WARN 前缀"：换个前缀/大小写就再次静默（契约优于嗅探 · N2）；
    # 为什么**不截断**：批量告警丢尾部 = 最该看的几条恰好看不见（§12 R7 的第二种形状）。
    if cfg.get("warn_only"):
        out = out_all.strip()
        mark = "WARN" if r.returncode == 0 else f"WARN(rc={r.returncode})"
        print(f"{mark} {name}: {cmd}")
        if out:
            for ln in out.splitlines():
                print(f"    {ln}")
        return "PASS", True
    if r.returncode != 0:
        lines = out_all.strip().splitlines()
        print(f"FAIL {name}: {cmd}")
        for ln in lines[:15]:
            print(f"    {ln}")
        if len(lines) > 15:
            # 门禁规范 v0.2.7 V2：允许"前 N 条 + 其余见 <路径>"，但**被截断部分必须可达**；
            # 只写"其余已省略"= 用承诺替换可见性（§11.3）。
            logpath = write_gate_log(root, name, out_all)
            if logpath:
                print(f"    … 其余 {len(lines) - 15} 行见 {logpath}")
            else:  # 写日志失败 ⇒ 宁可全打，也不做不可达的省略
                for ln in lines[15:]:
                    print(f"    {ln}")
        return "FAIL", False
    # 未声明 warn_only 但检查器自己打印 WARN 行（存量检查器）：保留可见 + 提示迁移
    warn_lines = [ln for ln in out_all.splitlines() if ln.lstrip().startswith("WARN")]
    if warn_lines:
        print(f"WARN {name}:")
        for ln in warn_lines:
            print(f"    {ln}")
        print(f"    ⚠ 建议在 gate.yaml 为该项声明 `warn_only: true`（契约优于前缀嗅探）")
    return "PASS", True



def write_gate_log(root, name, text):
    """把检查器完整输出落盘，返回**可读路径**；失败返回 None（调用方应退回"全部打印"）。"""
    try:
        d = os.path.join(root, ".gate-logs")
        os.makedirs(d, exist_ok=True)
        safe = "".join(c if (c.isalnum() or c in "-_.") else "_" for c in name)
        path = os.path.join(d, f"{safe}.log")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description="提交门禁 runner (L1)")
    ap.add_argument("--stage", default="all", choices=["fast", "slow", "all"])
    ap.add_argument(
        "--changed",
        action="store_true",
        help="只跑命中暂存文件的检查器 (pre-commit 场景)",
    )
    ap.add_argument(
        "--changed-files",
        nargs="+",
        metavar="PATH",
        help="显式指定变更文件（用于 CI/调试；与 --changed 等价但不由 git 推断）",
    )
    ap.add_argument(
        "--list",
        action="store_true",
        help="只打印执行计划（RUN/SKIP… + gate 名），不执行任何 gate",
    )
    ap.add_argument(
        "--version",
        action="store_true",
        help="打印 runner 身份（version/rev/sha）并退出",
    )
    ap.add_argument(
        "--only-gate",
        default=None,
        metavar="ID",
        help="只跑指定门禁项（供 gate-selftest 对单个判据做反例/正控）",
    )
    ap.add_argument(
        "--exclude-gate",
        action="append",
        default=[],
        metavar="ID",
        help="跳过指定门禁项（可重复）。gate-selftest 用它把**自身**排除，避免自递归挂死",
    )
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    EXCLUDE_GATES.clear()
    EXCLUDE_GATES.update(args.exclude_gate or [])

    if args.version:
        print(f"gate: {identity()}")
        return 0

    root = os.getcwd()

    # 可执行位回归守护（无 gate.yaml 也生效；2026-11-03 `#1008` 补回）
    exec_errs = check_exec_bit(root, staged_files(root) if args.changed else None)
    if exec_errs:
        print("FAIL exec-bit: 可执行位回归（HEAD 100755 -> 现非 100755）：")
        for e in exec_errs:
            print(f"    {e}")
        print("    修：git update-index --chmod=+x <file> 后再提交")
        return 1

    # #642：中间态先判，先于任何 gate
    st = intermediate_state(root)
    if st:
        marker, path = st
        print(
            f"❌ 当前仓库处于未完成的 merge/rebase/cherry-pick 中间态（{marker} 存在：{path}）",
            file=sys.stderr,
        )
        print(
            "   ⇒ 拒绝跑门禁：此刻工作区文件是合并中间产物，判定结果无意义",
            file=sys.stderr,
        )
        print(
            "   处置：git merge --abort / git rebase --abort / 解决冲突后提交",
            file=sys.stderr,
        )
        return 1

    try:
        gates, meta = load_config(os.path.join(root, args.config))
    except ConfigUnreadable as exc:
        print(f"ERROR config: {exc}（无法判定）")
        return 3
    if gates is None:
        print(f"no config: {args.config} (skip)")
        return 0
    if args.only_gate is not None:
        if args.only_gate not in gates:
            print(
                f"ERROR --only-gate {args.only_gate}: gate.yaml 里没有这个门禁项"
                f"（现有: {', '.join(gates) or '<空>'}）"
            )
            return 3
        gates = {args.only_gate: gates[args.only_gate]}
    if args.changed_files:
        changed = list(args.changed_files)
    else:
        changed = staged_files(root) if args.changed else None

    if args.list:
        # 执行计划：与真跑共用 gate_plan()，diff 出"计划里没有"的 gate 即接线缺失
        for name, cfg in gates.items():
            if args.quiet and cfg.get("stage") == "slow" and args.stage != "all":
                continue
            print(f"{gate_plan(name, cfg, args.stage, changed):<14} {name}")
        return 0

    # CI-071 ①：顶层未知 key ⇒ fail-closed（打印不是目的，拦住才是）
    if meta["anomalies"]:
        print(
            f"gate: FAIL 配置错误（顶层未知 key {len(meta['anomalies'])} 个）⇒ rc=1",
            file=sys.stderr,
        )
        return 1
    # CI-071 ③：expected_gates 数字对账（告警会被无视，数字会自己红）
    # ⚠️ --only-gate 是把执行计划缩到一项（供 gate-selftest 用），此时两项对账必须跳过，
    #    否则"只跑一项"必然触发 parsed != declared 的假 FAIL。
    declared_n = meta["expected_gates"]
    only = args.only_gate is not None
    parsed_n = len(gates)
    if declared_n is None:
        print(
            f"WARN gate.yaml 未声明 expected_gates（当前解析到 {parsed_n} 项）"
            f"—— 建议写 expected_gates: {parsed_n} 防「静默少跑」",
            file=sys.stderr,
        )
    elif declared_n != parsed_n and not only:
        print(
            f"gate: FAIL 声明 {declared_n} 项，实际解析到 {parsed_n} 项 ⇒ 有 gate 未生效 ⇒ rc=1",
            file=sys.stderr,
        )
        return 1

    # #636：必需集校验（profile ∪ required_gates）——**缺项点名**，且不受 --only-gate 影响
    required = list(GATE_PROFILES.get(meta.get("profile") or "", []))
    prof = meta.get("profile")
    if prof and prof not in GATE_PROFILES:
        print(
            f"gate: FAIL UNKNOWN_PROFILE={prof}（已知: {', '.join(sorted(GATE_PROFILES))}）⇒ rc=1",
            file=sys.stderr,
        )
        return 1
    for g in meta.get("required_gates") or []:
        if g not in required:
            required.append(g)
    if required:
        missing = [g for g in required if g not in gates]
        if missing:
            print(
                "gate: FAIL MISSING_GATE=" + ",".join(missing)
                + f"（profile={prof or '-'} 必需 {len(required)} 项，缺 {len(missing)} 项，实际声明 {len(gates)} 项）⇒ rc=1",
                file=sys.stderr,
            )
            print(
                "   ⇒ 该有的判据没在 gate.yaml 里声明 = 这些检查根本不会跑；"
                "补声明，或改 profile / 显式登记不纳管（profile: legacy + 理由注释）",
                file=sys.stderr,
            )
            return 1

    n_pass = n_skip = n_fail = n_skip_env = 0
    _statuses: list[tuple[str, str]] = []   # (gate, status) —— 供汇总区"跳过项点名"
    for name, cfg in gates.items():
        if args.quiet and cfg.get("stage") == "slow" and args.stage != "all":
            continue
        status, ok = run_gate(name, cfg, root, args.stage, changed)
        if not args.quiet:
            print(f"{status:<14} {name}")
        _statuses.append((name, status))
        if status == "PASS":
            n_pass += 1
        elif status == "SKIP(no-match)":
            n_skip += 1
        elif status == "SKIP(ci-only)":
            n_skip += 1
        elif status == "SKIP(env)":
            n_skip_env += 1
        else:
            n_fail += 1
    # CI-071 ②：数量对账 —— 解析数 == 执行数(pass+fail) + 显式 skipped 数
    if parsed_n != n_pass + n_fail + n_skip + n_skip_env and not only:
        print(
            f"gate: FAIL 数量对账不符（parsed={parsed_n} != pass+fail+skip={n_pass + n_fail + n_skip}）⇒ rc=1",
            file=sys.stderr,
        )
        return 1
    # 只追加契约（#638）：既有字段名与顺序保持不变，身份字段**追加在行尾**。
    # 破坏性变更（改名/重排/去字段）须升 major + CHANGELOG —— 否则老解析器会**静默失效**。
    summary = (
        f"gate: declared={declared_n if declared_n is not None else '-'} parsed={parsed_n} "
        f"pass={n_pass} skip={n_skip} fail={n_fail} (stage={args.stage})"
        f"{'  ⚠ skipped 不计入 pass' if n_skip else ''}"
        f" {identity()}"
    )
    # 跳过项**点名**（2026-11-03 · builder 提议）：明细行有 SKIP 但汇总区没项名时，
    # 读者只看到 `pass=N` 就以为全查了。⚠️ 不塞进既有机器汇总行 —— 那条受 #638「只追加契约」保护
    # （改字段/顺序会让老解析器静默失效）；改为**在其前面多打一行**：老解析器读不到当没有，新解析器 grep 得到。
    _skip_ids = [n for (n, st) in _statuses if str(st).startswith("SKIP")]
    if _skip_ids:
        print("gate: skipped_ids=" + ",".join(_skip_ids), file=sys.stderr if n_fail else sys.stdout)

    # #638：汇总行在**失败路径也打印**，否则"红得不可诊断"（同 #637 的 pip 输出被吞）
    print(summary, file=sys.stderr if n_fail else sys.stdout)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
