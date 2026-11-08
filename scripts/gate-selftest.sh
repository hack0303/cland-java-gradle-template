#!/usr/bin/env bash
# =============================================================================
# gate-selftest.sh —— 判据自检：跑本仓每条门禁的**反例（必红）+ 正控（必绿）**
#
# 规范依据: 门禁规范 v0.2.4 §11（判据可维护性）· #649 落地
#   §11.1「判据的可判性 = 存在一个能让它变红的、可执行的用例」——
#   注释里写「负控：…」但没有任何文件/命令会跑它 ⇒ 删掉该判据也照样绿。
#
# 为什么需要它（真实事故）:
#   「负控」长期以散文形式写在 gate.yaml 注释里，删掉被保护的门禁项照样绿；
#   而每次都靠人临时构造反例 ⇒ 判据一旦放宽，没人知道。本脚本把反例变成**永久可复跑**。
#
# 用例布局（入库存证，§11.3）:
#   tests/negative/<gate-id>/<case-name>/     # 期望红（rc≠0）
#   tests/positive/<gate-id>/<case-name>/     # 期望绿（rc=0）
#     ├── case.conf        # expect=red|green（缺省：negative 目录=red，positive 目录=green）
#     │                    # why=<一句后果>（为什么必须红；写后果不写规则复述）
#     │                    # cmd=<覆盖命令>（缺省用 gate.yaml 里该 gate 的 cmd；可用 {root}）
#     │                    # remove=<路径>[,<路径>]（从 fixture 删除已跟踪路径：写"删掉必需目录必须红"这类反例）
#     │                    # base=repo|empty（缺省 repo：工作区=HEAD 全量副本；empty=空目录）
#     └── files/           # 可选：叠加到工作区的文件/目录（相对仓根）
#                          # 名字以 `.__fixture__` 结尾的，落盘时**去掉该后缀**
#                          # （反例内容必须入库，但 `xxx.md.__fixture__` 不会被本仓门禁误扫导致自红）
#
# 执行模型:
#   每个用例 → 新建临时工作区（git archive HEAD + files/ 叠加）→ 在工作区里跑该 gate 的 cmd
#   ⇒ **正控 = 原样必绿**、**负控 = 改坏必红**，两者都不依赖网络/时钟（§11.4）。
#
# 边界（#649 验收 · graham 提案）:
#   仓库**没有** tests/negative/ ⇒ 打 WARN 并 **rc=0**（未接入 ≠ 失败：机制上线不应让存量仓一夜全红）。
#   仓库有 fixtures 但反例没变红 ⇒ **rc≠0**（有机制就必须真能红）。
#   要用"缺用例即失败"的强档：--strict（或 GATE_SELFTEST_STRICT=1）；建议按仓逐步开。
#
# 退出码（四段，承规范 §1 三分 + validate_envelope.py 先例）:
#   0 = 全部用例符合期望（含"未接入 ⇒ WARN 放行"）
#   1 = 有用例不符合期望（该红没红 / 该绿却红），或 --strict 下缺用例
#   2 = 用法错误（未知参数 / 未知 gate / --only 指向不存在的 gate）
#   3 = 无法判定（不是 git 仓 / 无 HEAD 且无法取文件列表 / 读不到 gate.yaml 的用例配置）
#
# 用法:
#   bash scripts/gate-selftest.sh                 # 全量（CI/Jenkins --stage slow）
#   bash scripts/gate-selftest.sh --only doclint  # 只跑某条门禁
#   bash scripts/gate-selftest.sh --list          # 打印负控矩阵（门禁项 × 反例数 × 用例位置）
#   bash scripts/gate-selftest.sh --strict        # 缺用例 ⇒ rc=1
#   bash scripts/gate-selftest.sh --worktree      # 工作区版（含未提交改动；本地验证"我把判据改坏了会不会红"）
#   bash scripts/gate-selftest.sh --verify-source # 真源校验：各副本 sha256 vs sidecar/头注声明（不等 rc≠0）
#   bash scripts/gate-selftest.sh --verify-source --check-remote
#                                                 # 判定前先 `ls-remote` 比一次默认分支：远端≠本地 origin/* ⇒ 打
#                                                 # ref-stale 并**只对该仓** fetch 后重判（默认关；宿主机 cron 建议开）
#   bash scripts/gate-selftest.sh --quiet
# =============================================================================
set -uo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 3

ONLY=""
STRICT="${GATE_SELFTEST_STRICT:-0}"
LIST=0
QUIET=0
BASE_MODE="${GATE_SELFTEST_BASE:-head}"   # head=HEAD（CI 口径）| worktree=工作区（含未提交改动）
VERIFY_SOURCE=0
CHECK_REMOTE="${GATE_CHECK_REMOTE:-0}"   # 1=判定前 ls-remote 检查 ref 是否过期（只对过期仓 fetch）
DEBT_BUDGET=""          # --budget N：舰队欠账（未登记副本）上限，超出 ⇒ rc=1（棘轮）
DEBT_BUDGET_FILE=""     # --budget-file PATH：从文件读上限（CI 用，便于 PR 里审"降了多少"）

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; [[ -z "$ONLY" ]] && { echo "用法: $0 --only <gate-id>" >&2; exit 2; }; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --list) LIST=1; shift ;;
    --worktree) BASE_MODE=worktree; shift ;;
    --verify-source) VERIFY_SOURCE=1; shift ;;
    --check-remote) CHECK_REMOTE=1; shift ;;
    --budget) DEBT_BUDGET="${2:-}"; [[ -z "$DEBT_BUDGET" ]] && { echo "用法: $0 --verify-source --budget <N>" >&2; exit 2; }; shift 2 ;;
    --budget-file) DEBT_BUDGET_FILE="${2:-}"; [[ -z "$DEBT_BUDGET_FILE" ]] && { echo "用法: $0 --verify-source --budget-file <PATH>" >&2; exit 2; }; shift 2 ;;
    --quiet|-q) QUIET=1; shift ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1（用 --help）" >&2; exit 2 ;;
  esac
done


# --- 0. 真源校验（--verify-source）：头注/sidecar 声称的指纹必须与字节相符 --------------
# 为什么要有它：#649 现象——cland-devops 头注写「真源 sha=906f8186」，实际文件是另一份；
#   声明可以随便写，**只有重算字节才能把它变成判据**（§10.4「只写 sha 不校验 = 假钉版」同族）。
# 规则:
#   真源 = $GATE_SOURCE > 清单里 mode=source 的第一条 > 本仓 tools/gate.py
#   副本（mode=copy）: sha256(副本) == sha256(真源) 且 sidecar/头注声明 == 真源指纹；任一不符 ⇒ rc=1
#   历史线（mode=deprecated）: 只 WARN
#   多份并存/指纹不一致 ⇒ WARN；--strict ⇒ rc=1
#   扫描根: $GATE_SCAN_ROOT（默认 ~/work）；清单: $GATE_COPIES（默认 <script>/../tools/gate-copies.txt）
#   降级（真源不可达）⇒ **rc=3 无法判定**（不是 0）：只做过本仓 sidecar 自证，舰队级判据未执行。
#   --budget N / --budget-file PATH（配合 --verify-source，**会红**的收敛维度）：
#     欠账 = 未登记副本数；debt > budget ⇒ rc=1（棘轮，只许降不许升）
#     pending（必须 owner+due）/ deprecated（归档件）**不计入欠账**
verify_source() {
  local manifest="${GATE_COPIES:-$(dirname "${BASH_SOURCE[0]}")/../tools/gate-copies.txt}"
  local src="" line mode path declared actual src_sha=0
  local -a copies=() depr=() seen_shas=()
  resolve() { case "$1" in @repo:*) printf '%s/%s' "$ROOT" "${1#@repo:}" ;; *) printf '%s' "${1/#\~/$HOME}" ;; esac; }

  if [[ -n "${GATE_SOURCE:-}" ]]; then
    src="${GATE_SOURCE/#\~/$HOME}"
  elif [[ -f "$manifest" ]]; then
    while read -r mode path; do
      [[ -z "$mode" || "$mode" == \#* ]] && continue
      [[ "$mode" == "source" ]] && { src="$(resolve "$path")"; break; }
    done < "$manifest"
  fi
  # 真源不可达（典型：CI/Jenkins agent 的 $HOME 没有 skill 安装）⇒ **降级但明示**：
  #   只校验"本仓 copy vs 自己的 sidecar"，不扫舰队（CI 看不到舰队），不静默、不判 3。
  if [[ -n "$src" && ! -f "$src" ]]; then
    local own="$ROOT/tools/gate.py" decl own_sha
    if [[ -f "$own" && -f "$own.sha256" ]]; then
      decl="$(sed -n 's/^# *SOURCE_SHA: *//p' "$own.sha256" | head -1)"
      own_sha="$(sha256sum "$own" | cut -d' ' -f1)"
      echo "⚠️  降级：真源不可达（$src；CI/无 skill 安装）⇒ 只校验本仓副本 vs sidecar"
      if [[ -n "$decl" && "$decl" == "$own_sha" ]]; then
        echo "✅ 本仓副本自证通过（sha256=${own_sha:0:16}，与 sidecar 声明一致）"
        # 降级 = **无法判定**，不是通过（atlas 2026-10-22 决定 2 / P-SILENCE 第六形态「降级即通过」）。
        # 为什么必须独立退出码："放行"是动词、rc=0 是它的结论；两者同时出现，读的人只看到结论。
        #   本仓副本 vs sidecar 自证通过 ≠ 舰队级判据跑过（未登记副本/棘轮在此**都没执行**）。
        # CI 侧应把 rc=3 映射成 SKIP/UNSTABLE，**不映射 SUCCESS**。
        echo "⚠️  无法判定（降级）：真源不可达 ⇒ 只做了本仓副本 vs sidecar 自证；"
        echo "    未执行：舰队级副本一致性 / 未登记副本扫描 / 欠账棘轮。请在有舰队视图的宿主机跑："
        echo "    bash scripts/gate-selftest.sh --verify-source --budget-file tools/gate-debt-budget.txt"
        echo "verify-source: checked=1 warn=1（本仓 0 · 舰队 1·降级）⇒ rc=3（无法判定，不是通过）"
        return 3
      fi
      echo "❌ 本仓副本与 sidecar 声明不符：声明=${decl:-<空>} 实际=${own_sha:0:16} ⇒ rc=1"
      return 1
    fi
    echo "❌ --verify-source: 真源不存在且本仓无 sidecar: $src ⇒ rc=3"; return 3
  fi
  [[ -n "$src" ]] || { echo "❌ --verify-source: 找不到真源（清单 $manifest）⇒ rc=3"; return 3; }
  src_sha="$(sha256sum "$src" | cut -d' ' -f1)"
  echo "真源: $src"
  echo "      sha256=$src_sha"

  local rc=0 warn=0 checked=0
  local warn_local=0 warn_fleet=0   # fleet=清单外/待收敛（只计数）；local=本仓自身声明问题
  # warn 按**原因**分列（atlas：只报数看不出"没接负控"与"负控通过"的区别）
  local c_unreg=0 c_nodecl=0 c_pending=0 c_missing=0 c_deprecated=0 c_multi=0
  local n_fail=0   # rc=1 级的"需要动作"计数（汇总时置顶，别被随批次 WARN 淹掉）
  while read -r mode path; do
    [[ -z "$mode" || "$mode" == \#* ]] && continue
    [[ "$mode" == "source" ]] && continue
    # pending 行形如 `<path> owner=<who> due=<YYYY-MM-DD>`：**必须先拆字段，再解析路径**。
    #   2026-10-23 修 bug：此前先 resolve 整行 ⇒ 路径里带 "owner=/due=" ⇒ 永远"未找到副本"，
    #   pending 因此三重漏检：① 不受检 ② 计进 c_missing ③ 扫描时又被当未登记副本计入 debt。
    if [[ "$mode" == "pending" ]]; then
      local rest="${path}" pend_path pend_owner="" pend_due="" pf pactual
      pend_path="$(printf '%s' "$rest" | awk '{print $1}')"
      pend_owner="$(printf '%s' "$rest" | sed -n 's/.*owner=\([^ ]*\).*/\1/p')"
      pend_due="$(printf '%s' "$rest" | sed -n 's/.*due=\([0-9-]*\).*/\1/p')"
      pf="$(resolve "$pend_path")"
      # atlas 2026-10-22 硬条件：pending 必须带 owner + due，否则等同"未登记"
      if [[ -z "$pend_owner" || -z "$pend_due" ]]; then
        # “等同未登记”必须真的计进 debt（c_unreg），否则无主 pending 就是逃债后门
        echo "⚠️  pending 缺 owner/due ⇒ 等同未登记: $pend_path"; warn=$((warn+1)); warn_fleet=$((warn_fleet+1)); c_pending=$((c_pending+1)); c_unreg=$((c_unreg+1)); continue
      fi
      if [[ "$pend_due" < "$(date +%Y-%m-%d)" ]]; then
        echo "❌ pending 已过期（due=${pend_due} < 今天）且未收敛 ⇒ rc=1: $pend_path"; rc=1; n_fail=$((n_fail+1)); continue
      fi
      if [[ ! -f "$pf" ]]; then
        echo "⚠️  未找到副本（跳过）: $pend_path"; warn=$((warn+1)); warn_fleet=$((warn_fleet+1)); c_missing=$((c_missing+1)); continue
      fi
      checked=$((checked+1))
      pactual="$(sha256sum "$pf" | cut -d' ' -f1)"
      if [[ "$pactual" == "$src_sha" ]]; then
        echo "✅ 已收敛（清单登记为 pending，可改为 copy）: $pend_path"
        seen_shas+=("$pactual")
      else
        echo "⚠️  pending 待收敛（owner=${pend_owner} due=${pend_due} sha=${pactual:0:16} ≠ 真源 ${src_sha:0:16}）: $pend_path"
        warn=$((warn+1)); warn_fleet=$((warn_fleet+1)); c_pending=$((c_pending+1))
      fi
      continue
    fi
    local f; f="$(resolve "$path")"
    [[ -f "$f" ]] || { echo "⚠️  未找到副本（跳过）: $path"; warn=$((warn+1)); warn_fleet=$((warn_fleet+1)); c_missing=$((c_missing+1)); continue; }
    checked=$((checked+1))
    actual="$(sha256sum "$f" | cut -d' ' -f1)"
    # 声明：sidecar 优先，其次文件头注（两者都读，任一存在即校验）
    declared=""
    [[ -f "$f.sha256" ]] && declared="$(sed -n 's/^# *SOURCE_SHA: *//p' "$f.sha256" | head -1)"
    local head_decl; head_decl="$(sed -n 's/^# *SOURCE_SHA: *//p' "$f" | head -1)"
    [[ -z "$declared" ]] && declared="$head_decl"
    if [[ "$mode" == "deprecated" ]]; then
      echo "⚠️  deprecated（不计失败，仅提示）: $path"; warn=$((warn+1)); warn_fleet=$((warn_fleet+1)); c_deprecated=$((c_deprecated+1)); continue
    fi
    if [[ "$actual" != "$src_sha" ]]; then
      echo "❌ 副本与真源字节不同: $path"; echo "   副本 sha=$actual"; echo "   真源 sha=$src_sha"; rc=1; n_fail=$((n_fail+1))
    fi
    if [[ -z "$declared" ]]; then
      echo "⚠️  无真源声明（缺 gate.py.sha256 / 头注 SOURCE_SHA）: $path"; warn=$((warn+1)); warn_local=$((warn_local+1)); c_nodecl=$((c_nodecl+1))
    elif [[ "$declared" != "$src_sha" ]]; then
      echo "❌ 声明与真源不符: $path"; echo "   声称=$declared"; echo "   实际真源=$src_sha"; rc=1; n_fail=$((n_fail+1))
    else
      echo "✅ 副本一致且声明可验: $path"
    fi
    seen_shas+=("$actual")
  done < "$manifest"

  # 真源自己的 sidecar：必须有且自证（声明 == 自身指纹）；缺失 ⇒ 本仓 WARN（--strict 红）
  if [[ ! -f "$src.sha256" ]]; then
    echo "⚠️  真源缺 sidecar（$src.sha256 不存在）⇒ 无法自证"; warn=$((warn+1)); warn_local=$((warn_local+1))
  elif :; then
    local self; self="$(sed -n 's/^# *SOURCE_SHA: *//p' "$src.sha256" | head -1)"
    if [[ -n "$self" && "$self" != "$src_sha" ]]; then
      echo "❌ 真源 sidecar 与自身字节不符: $src.sha256"; rc=1; n_fail=$((n_fail+1))
    fi
  fi

  # ---- 未登记副本扫描：清单之外的 gate.py 不得天然逃检（atlas 2026-10-22 实读发现第六份）----
  # ---- 指纹分级表：=真源 PASS / 登记过的历史版本 WARN / 未知指纹 ERROR ----
  local fpfile="${GATE_FINGERPRINTS:-$(dirname "${BASH_SOURCE[0]}")/../tools/gate-fingerprints.txt}"
  local -a known_fp=()
  local fp_registry_ok=0
  if [[ -f "$fpfile" ]]; then
    fp_registry_ok=1
    while read -r h _rest; do [[ -z "$h" || "$h" == \#* ]] && continue; known_fp+=("$h"); done < "$fpfile"
  else
    # 没有分级表 ⇒ 无法判断"这是历史版本还是新分叉" ⇒ 一律按未登记处理（WARN），
    # 不能因为"表格缺失"就把整个舰队判红（否则机制在无表环境里变成永远响的闸）。
    echo "⚠️  无指纹分级表（$fpfile）⇒ 未登记副本一律按 WARN 处理（不做 ERROR 分级）"
  fi
  grade_fp() {  # $1=sha256 → known|unknown
    [[ "$fp_registry_ok" -eq 1 ]] || { echo known; return; }
    local x="${1:0:16}" k
    for k in ${known_fp[@]+"${known_fp[@]}"}; do [[ "$k" == "$x" ]] && { echo known; return; }; done
    echo unknown
  }
  local scanroot; scanroot="${GATE_SCAN_ROOT:-$HOME/work}"   # 可覆盖（测试/非默认目录布局）
  local manifest_paths="" f rel
  while read -r mode path; do
    [[ -z "$mode" || "$mode" == \#* ]] && continue
    # pending 行尾带 owner=/due= ⇒ 只取第一个字段做路径，否则扫描白名单永远匹配不上（会被重复计债）
    [[ "$mode" == "pending" ]] && path="$(printf '%s' "$path" | awk '{print $1}')"
    manifest_paths+="$(resolve "$path")"$'\n'
  done < "$manifest"
  shopt -s nullglob
  local unreg=0
  for f in "$scanroot"/*/tools/gate.py "$scanroot"/*/*/tools/gate.py "$scanroot"/*/*/*/tools/gate.py; do
    [[ -f "$f" ]] || continue
    grep -qxF "$f" <<< "$manifest_paths" && continue
    local usha; usha="$(sha256sum "$f" | cut -d' ' -f1)"
    if [[ "$usha" == "$src_sha" ]]; then
      echo "⚠️  未登记副本（内容与真源一致，建议补登记）: $f"; warn=$((warn+1)); warn_fleet=$((warn_fleet+1)); c_unreg=$((c_unreg+1))
    elif [[ "$(grade_fp "$usha")" == "known" ]]; then
      echo "⚠️  未登记副本 · 已知历史版本（见 gate-fingerprints.txt）: $f  sha=${usha:0:16}"
      warn=$((warn+1)); warn_fleet=$((warn_fleet+1)); c_unreg=$((c_unreg+1))
    else
      # 未知指纹 = 可能是"分叉后悄悄演进"的新变种 ⇒ 必须红（不是"又一份旧的"）
      echo "❌ 未登记副本且**指纹未知**（不在 gate-fingerprints.txt）: $f  sha=${usha:0:16}"; rc=1; n_fail=$((n_fail+1))
    fi
    unreg=$((unreg+1))
  done
  shopt -u nullglob
  [[ "$unreg" -gt 0 ]] && echo "未登记副本: $unreg 份（按 tools/gate-copies.txt 台账登记为 copy 或收敛；--strict 会判红）"

  # ---- gate.yaml 舰队巡检（#668 · 判据合并自 chaineasy-sre:scripts/gate-yaml-flatten-scan.sh）----
  #   为什么不另挂一条 cron：判据要"一处实现、宿主机 05:50 与 Jenkins 同时覆盖"，
  #   第三条 cron = 三份实现各自漂移（#604/#628 同族：证据没对准产物）。
  #   三条判据（互相补位，缺一条就会复发）：
  #     ① 尾行是绝对路径 ⇒ **尾部压平**：门禁块被折叠成一行，旧 runner 静默忽略（假绿），新 runner rc=1
  #     ② 缺 expected_gates ⇒ "少跑"不会红 ⇒ 将来再被压平/删块照样绿
  #     ③ expected_gates ≠ 实际解析数 ⇒ 声明与实现不符（②才有牙）
  #   第 7 个「测的不是那件事」（steward 2026-10-23）：只读**工作树** ⇒ 一次 `checkout` 就能让指标 2↔0 跳变，
  #   而交付状态没变（实例：有人 checkout 到修复分支 ⇒ c_yanom 2→0 假绿）。所以：
  #     · **判据以默认分支提交态为准**（`git show <default>:gate.yaml`），不是工作树；
  #     · 工作树与默认分支结论不同 ⇒ 另报一行「工作树 ≠ 默认分支」，并带 `branch@HEAD`；
  #     · 判不了默认分支（无 origin/HEAD、无 main/master）⇒ 退回工作树并显式标注 `nodefault`。
  local gy_total=0 gy_noexp=0 gy_anom=0 gy_wtdiff=0 gy_nodefault=0 gy_wt_anom=0 gy_wt_flat=0 gy_wt_info=0 gy_wt_branchonly=0 gy_real=0 gy_confirm=0 gy_wt_anom_printed=0 gy_rhythm=0 gy_refstale=0 gy_refunknown=0 gy_swallowed=0
  # ---- 已知阻塞表（只标注，不豁免；见 tools/gate-known-blockers.txt 的铁律 1/2/3）----
  local kb_file="${GATE_KNOWN_BLOCKERS:-$ROOT/tools/gate-known-blockers.txt}"
  local -A kb_card=() kb_reason=() kb_due=()
  local gy_known=0 gy_known_expired=0
  if [[ -f "$kb_file" ]]; then
    while IFS=$'\t' read -r kb_path kb_rest; do
      [[ -z "$kb_path" || "$kb_path" == \#* ]] && continue
      kb_path="${kb_path/#\~/$HOME}"
      kb_card["$kb_path"]="$(printf '%s' "$kb_rest" | sed -n 's/.*card=\([^\t]*\).*/\1/p')"
      kb_due["$kb_path"]="$(printf '%s' "$kb_rest" | sed -n 's/.*due=\([0-9-]*\).*/\1/p')"
      kb_reason["$kb_path"]="$(printf '%s' "$kb_rest" | sed -n 's/.*reason=\(.*\)\tdue=.*/\1/p')"
    done < "$kb_file"
  fi
  local -a gy_noexp_paths=() gy_anom_paths=()
  if command -v python3 >/dev/null 2>&1 && [[ -f "$ROOT/tools/gate.py" ]]; then
    local gy_stream gy_status gy_path gy_judged gy_msg
    gy_stream="$(python3 - "$scanroot" "$ROOT/tools/gate.py" "$CHECK_REMOTE" <<'PYFLEET' 2>/tmp/gate-yaml-scan.err
import glob, importlib.util, os, re, subprocess, sys

scanroot, runner, check_remote = sys.argv[1], sys.argv[2], (len(sys.argv) > 3 and sys.argv[3] == "1")
spec = importlib.util.spec_from_file_location("gate_runner", runner)
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)


def sh(repo, *args):
    try:
        r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=20)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def repo_of(path):
    cur = os.path.dirname(path)
    while cur and cur != "/":
        if os.path.isdir(os.path.join(cur, ".git")):
            return cur
        cur = os.path.dirname(cur)
    return None


def default_branch(repo):
    ref = sh(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if ref and "/" in ref:
        return ref.split("/", 1)[1]
    for cand in ("main", "master"):
        if sh(repo, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{cand}"):
            return cand
        if sh(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{cand}"):
            return cand
    return None


def pick_remote(repo):
    """选一个**能免交互跑通**的 remote：ssh/gitea 优先（http 常要凭据 ⇒ 会挂）。
    实测：http 形态的 origin 会卡到超时（42 仓 2m14s），ssh 形态 ~几十 ms。"""
    urls = {}
    for line in (sh(repo, "remote", "-v") or "").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            urls.setdefault(parts[0], parts[1])
    for name in ("gitea", "origin"):
        if name in urls:
            if urls[name].startswith("http"):
                continue
            return name
    for name, url in urls.items():
        if not url.startswith("http"):
            return name
    return next(iter(urls), None)


def remote_default_sha(repo, remote, branch):
    """只看 ref 指针，不传对象：`ls-remote <remote> refs/heads/<branch>`。失败返回 None。"""
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    try:
        r = subprocess.run(
            ["git", "-c", "credential.helper=", "-C", repo, "ls-remote", remote, f"refs/heads/{branch}"],
            capture_output=True, text=True, timeout=12, env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].endswith(f"refs/heads/{branch}"):
            return parts[0]
    return None


def fetch_default(repo, remote, branch):
    """只拉这一个分支的指针+对象（避免全量 fetch）。"""
    try:
        subprocess.run(
            ["git", "-C", repo, "fetch", "--quiet", remote,
             f"+refs/heads/{branch}:refs/remotes/{remote}/{branch}"],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return True


def assess(text):
    """返回 (status, msg, n_gates)：OK / FLAT / ANOM / NOEXP / MISM。"""
    lines = text.splitlines()
    try:
        gates = g.parse_gates(text)
    except Exception as exc:            # noqa: BLE001 - 解析器任何异常都按"不可解析"
        return "FLAT", f"解析失败: {exc}", -1
    anom, anom_gatelike = [], []
    cur = None
    for ln in lines:
        if not ln.strip() or ln.strip().startswith("#"):
            continue
        ind = len(ln) - len(ln.lstrip())
        if ind == 0:
            if ln.strip().startswith(("gates:", "expected_gates:")):
                cur = None
                continue
            cur = ln.strip()
            anom.append(cur)
            anom_gatelike.append(False)
        elif cur is not None and re.match(r"^\s+(cmd|stage|type|on|require|forbid):", ln):
            anom_gatelike[-1] = True
    last = ""
    for ln in lines:
        if ln.strip():
            last = ln.rstrip("\n")
    if last.startswith("/"):
        return "FLAT", f"末行是绝对路径（门禁块被压平）: {last[:80]}", len(gates)
    if anom:
        # 严重度对齐（steward 2026-10-23）：顶层未知 key 若**块里有门禁子键**（cmd/stage/type/on/require/forbid）
        # ⇒ 等价于"压平"：该门禁被丢弃、从未执行 = false-green ⇒ **rc=1**；纯配置项才保持 WARN。
        gate_like = [a for a, g in zip(anom, anom_gatelike) if g]
        if gate_like:
            return "SWALLOWED", "顶层 key 形如门禁（含 cmd:/stage: 等）⇒ 该门禁被丢弃、**从未执行**: " + "; ".join(gate_like)[:160], len(gates)
        return "ANOM", "顶层未知 key（配置项，非门禁）: " + "; ".join(anom)[:160], len(gates)
    exp = [ln for ln in lines if ln.strip().startswith("expected_gates:")]
    if not exp:
        return "NOEXP", f"解析到 {len(gates)} 项但未声明 expected_gates", len(gates)
    m = re.search(r"expected_gates:\s*(\d+)", exp[0])
    if not m:
        return "NOEXP", "expected_gates 行无法解析为整数", len(gates)
    if int(m.group(1)) != len(gates):
        return "MISM", f"声明 expected_gates={int(m.group(1))} 实际解析={len(gates)}", len(gates)
    return "OK", f"gates={len(gates)}", len(gates)


paths = []
for depth in (1, 2, 3):
    paths += glob.glob(os.path.join(scanroot, "/".join(["*"] * depth), "gate.yaml"))

# ---- ref 过期检查：**并发**跑 ls-remote（串行实测 42 仓 2m14s；并发 ~10s）----
stale = {}
if check_remote:
    import concurrent.futures

    def _check_one(p):
        repo = repo_of(p)
        if not repo:
            return p, None
        remote = pick_remote(repo)
        d = default_branch(repo)
        if not (remote and d):
            return p, None
        local_sha = sh(repo, "rev-parse", f"refs/remotes/{remote}/{d}") or ""
        remote_sha = remote_default_sha(repo, remote, d)
        if remote_sha is None:
            return p, ("REFUNKNOWN", remote, (local_sha or "?")[:12], "")
        if remote_sha != local_sha:
            fetch_default(repo, remote, d)
            return p, ("REFSTALE", remote, remote_sha[:12], (local_sha or "?")[:12])
        return p, None

    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as ex:
        for _p, _res in ex.map(_check_one, sorted(set(paths))):
            if _res:
                stale[_p] = _res

for p in sorted(set(paths)):
    repo = repo_of(p)
    if not repo:
        continue
    br = sh(repo, "rev-parse", "--abbrev-ref", "HEAD") or "?"
    head = (sh(repo, "rev-parse", "--short", "HEAD") or "?")[:12]
    rel = os.path.relpath(p, repo)
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            wt_text = fh.read()
    except OSError as exc:
        print("FLAT\t%s\tworktree\t%s\t%s\t读取失败: %s" % (p, br, head, exc))
        continue
    wt_status, wt_msg, wt_n = assess(wt_text)
    dflt = default_branch(repo)
    if not dflt:
        print("%s\t%s\tnodefault(%s)\t%s\t%s\t%s" % (wt_status, p, br, br, head, wt_msg))
        continue
    # ref 过期检查结果（并发预计算，见上方 stale 字典）
    if check_remote and p in stale:
        _kind, _remote, _rsha, _lsha = stale[p]
        if _kind == "REFUNKNOWN":
            print("REFUNKNOWN\t%s\t%s\t%s\t%s\tls-remote 失败（网络/权限）⇒ 按本地 ref 判定，结果可能过期" % (p, _remote, _lsha, br))
        else:
            print("REFSTALE\t%s\t%s@%s\t%s\t%s\t远端 %s@%s ≠ 本地 %s ⇒ 已只对该仓 fetch 默认分支后重判" % (
                p, _remote, _rsha, br, head, _remote, _rsha, _lsha))
    # 判定基线：优先远端跟踪 ref（别人/CI 读到的就是它），其次本地默认分支
    judged = None
    for cand in (f"refs/remotes/origin/{dflt}", f"refs/heads/{dflt}"):
        sha = sh(repo, "rev-parse", "--short", cand)
        if sha:
            judged = f"{cand.split('/refs/')[-1].replace('refs/remotes/', '').replace('refs/heads/', '')}@{sha}"
            break
    judged = judged or f"{dflt}@?"
    # ⚠️ 只能用**远端跟踪 ref**读：多数克隆本地没有 master/main 分支（只有 origin/master）
    d_text = sh(repo, "show", f"origin/{dflt}:{rel}")
    if d_text is None:
        d_text = sh(repo, "show", f"{dflt}:{rel}")
    if d_text is None:
        # 判据基线**整份 gate.yaml 都不存在** ⇒ 这是"能力真缺失"（不是发布节奏）：
        #   分支上解析出 N 个门禁，默认分支 0 个；措辞必须守住边界（不能说"CI 无门禁"）。
        mb = sh(repo, "merge-base", f"origin/{dflt}", "HEAD")
        days = "?"
        if mb:
            ct = sh(repo, "log", "-1", "--format=%ct", mb)
            if ct and ct.isdigit():
                import time
                days = int((time.time() - int(ct)) // 86400)
        ahead = sh(repo, "rev-list", "--count", f"origin/{dflt}..HEAD") or "?"
        print("BRANCHONLY-REAL\t%s\t%s\t%s\t%s\t默认分支无 gate.yaml；%d 个门禁只在领先 %s 提交的分支上，分叉 %s 天；是否影响 CI 待确认（看 Jenkinsfile branch spec）"
              % (p, judged, br, head, wt_n, ahead, days))
        continue
    d_status, d_msg, d_n = assess(d_text)
    print("%s\t%s\t%s\t%s\t%s\t%s" % (d_status, p, judged, br, head, d_msg))
    if (wt_status, wt_msg) != (d_status, d_msg):
        # 分档：两侧都是"随批次"类（OK/NOEXP）⇒ INFO（只计数，防告警疲劳）；
        #       任一侧是 FLAT/MISM/ANOM（假绿/不可解析/门禁被吞）⇒ ACTION（逐条打印）
        if d_status in {"FLAT", "MISM", "SWALLOWED"}:
            # 基线本身已判红（❌ 已打印并带已知阻塞标注）⇒ 不再重复 WTDIFF
            continue
        actionable = {"FLAT", "MISM", "ANOM", "SWALLOWED"}
        # 「分支上多出 N 个门禁」也是**行动项**（今天 #456 的真根因：门禁只在分支、从未合入默认分支）。
        #   只比 status 会漏掉它（两侧同为 NOEXP），必须比门禁数。
        branch_only = wt_n > d_n >= 0
        if ({wt_status, d_status} & actionable) or branch_only:
            kind = "WTDIFF-ACTION"
            if branch_only:
                mb = sh(repo, "merge-base", f"origin/{dflt}", "HEAD")
                days = "?"
                if mb:
                    ct = sh(repo, "log", "-1", "--format=%ct", mb)
                    if ct and ct.isdigit():
                        import time
                        days = int((time.time() - int(ct)) // 86400)
                ahead = sh(repo, "rev-list", "--count", f"origin/{dflt}..HEAD") or "?"
                extra = "；分支上多 %d 个门禁（未合入默认分支）· 分叉 %s 天 / 领先 %s 提交" % (wt_n - d_n, days, ahead)
            else:
                extra = ""
        else:
            kind = "WTDIFF-INFO"
            extra = ""
        print("%s\t%s\t%s\t%s\t%s\t工作树=%s(%s) vs 判据基线 %s=%s(%s)%s" % (kind, p, judged, br, head, wt_status, wt_msg, judged, d_status, d_msg, extra))
PYFLEET
)"
    if [[ -s /tmp/gate-yaml-scan.err ]] && grep -qvE "^ERROR gate.yaml 顶层存在未知 key" /tmp/gate-yaml-scan.err; then
      # 巡检器自身出错 ⇒ 不能当"没有发现问题"（P-SILENCE 第六形态：降级即通过）
      echo "⚠️  gate.yaml 巡检器有 stderr（结论可能不完整，先修巡检器）: $(head -2 /tmp/gate-yaml-scan.err | tr '\n' ' ')"
      warn=$((warn+1)); warn_fleet=$((warn_fleet+1))
    fi
    while IFS=$'\t' read -r gy_status gy_path gy_judged gy_branch gy_head gy_msg; do
      [[ -z "$gy_status" ]] && continue
      case "$gy_status" in
        REFSTALE | REFUNKNOWN)
          if [[ "$gy_status" == "REFSTALE" ]]; then gy_refstale=$((gy_refstale+1)); else gy_refunknown=$((gy_refunknown+1)); fi
          warn=$((warn+1)); warn_fleet=$((warn_fleet+1))
          echo "🔄 ref 过期/${gy_status}（${gy_msg}）: ${gy_path/#$HOME/~}"
          ;;
        BRANCHONLY-REAL)
          gy_wt_branchonly=$((gy_wt_branchonly+1)); gy_real=$((gy_real+1))
          warn=$((warn+1)); warn_fleet=$((warn_fleet+1))
          echo "🔴 gate.yaml 真缺口（判据基线 ${gy_judged}·工作树 ${gy_branch}@${gy_head}）: ${gy_path/#$HOME/~}"
          echo "      ${gy_msg}"
          ;;
        WTDIFF-ACTION | WTDIFF-INFO)
          gy_wtdiff=$((gy_wtdiff+1)); warn=$((warn+1)); warn_fleet=$((warn_fleet+1))
          case "$gy_msg" in
            *"工作树=ANOM"*) gy_wt_anom=$((gy_wt_anom+1)) ;;
            *"工作树=FLAT"* | *"工作树=MISM"*) gy_wt_flat=$((gy_wt_flat+1)) ;;
          esac
          # INFO 只计数（两侧都是 OK/NOEXP，属"分支上多几个门禁"），ACTION 才逐条打印
          if [[ "$gy_status" == "WTDIFF-ACTION" ]]; then
            # 分档：模板仓（worktree 就是模板态）⇒ 节奏差异 INFO；其余 ⇒ 待确认（需人看 CI 构建分支）
            if [[ "$gy_msg" == *"未合入默认分支"* ]]; then
              if [[ "${gy_path}" == */template/* || "${gy_path}" == */game/* ]]; then
                gy_rhythm=$((gy_rhythm+1))
                gy_wt_branchonly=$((gy_wt_branchonly+1))
              else
                gy_confirm=$((gy_confirm+1)); gy_wt_branchonly=$((gy_wt_branchonly+1))
                echo "🟡 gate.yaml 待确认（判据基线 ${gy_judged}·工作树 ${gy_branch}@${gy_head}）: ${gy_path/#$HOME/~}"
                echo "      ${gy_msg} ⇒ 需确认 CI 实际构建哪个分支（Jenkinsfile branch spec），确认后才判是否为缺口"
              fi
            else
              gy_wt_anom_printed=$((gy_wt_anom_printed+1))
              echo "⚠️  gate.yaml 工作树 ≠ 判据基线（工作树 ${gy_branch}@${gy_head}；判据基线 ${gy_judged}）: ${gy_path/#$HOME/~}"
              echo "      ${gy_msg}"
            fi
          else
            gy_wt_info=$((gy_wt_info+1))
          fi
          ;;
        FLAT | MISM | SWALLOWED)
          gy_total=$((gy_total+1)); rc=1; n_fail=$((n_fail+1))
          [[ "$gy_status" == "SWALLOWED" ]] && gy_swallowed=$((gy_swallowed+1))
          local kb_note=""
          if [[ -n "${kb_card[$gy_path]:-}" ]]; then
            if [[ "${kb_due[$gy_path]}" < "$(date +%Y-%m-%d)" ]]; then
              gy_known_expired=$((gy_known_expired+1))
              kb_note=" ⇒ ⏰ 已知阻塞**已过期**（due=${kb_due[$gy_path]} < 今天）⇒ 阻塞失效，按普通缺陷处理"
            else
              gy_known=$((gy_known+1))
              kb_note=" ⇒ 📌 已知阻塞 ${kb_card[$gy_path]}（due=${kb_due[$gy_path]}）：${kb_reason[$gy_path]}｜**rc 仍成立，不豁免、不调 budget**"
            fi
          fi
          echo "❌ gate.yaml(${gy_status} · 判据基线 ${gy_judged} · 工作树 ${gy_branch}@${gy_head}): ${gy_path} — ${gy_msg}${kb_note}"
          ;;
        ANOM)
          gy_total=$((gy_total+1)); gy_anom=$((gy_anom+1)); warn=$((warn+1)); warn_fleet=$((warn_fleet+1))
          gy_anom_paths+=("${gy_path}|${gy_msg}|判据基线 ${gy_judged}")
          ;;
        NOEXP)
          gy_total=$((gy_total+1)); gy_noexp=$((gy_noexp+1)); warn=$((warn+1)); warn_fleet=$((warn_fleet+1))
          gy_noexp_paths+=("${gy_path}|判据基线 ${gy_judged}")
          ;;
        OK)
          gy_total=$((gy_total+1))
          ;;
      esac
    done <<< "$gy_stream"
  fi
  if [[ "$gy_anom" -gt 0 ]]; then
    echo "⚠️  gate.yaml 顶层未知 key（该门禁从没跑过 · 舰队 WARN，归属各仓 owner）: ${gy_anom} 份"
    local gy_a
    for gy_a in "${gy_anom_paths[@]}"; do
      local _p="${gy_a%%|*}"; local _rest="${gy_a#*|}"; local _m="${_rest%|*}"; local _w="${_rest##*|}"
      echo "    · ${_p/#$HOME/~} [${_w}] — ${_m}"
    done
  fi
  if [[ "$gy_noexp" -gt 0 ]]; then
    echo "⚠️  gate.yaml 缺 expected_gates: ${gy_noexp} 份（少跑不会红 ⇒ #668 必须补，值 == 实际解析数）"
    local gy_i=0 gy_a
    for gy_a in "${gy_noexp_paths[@]}"; do
      gy_i=$((gy_i+1)); [[ "$gy_i" -gt 5 ]] && { echo "    …（其余 $((gy_noexp - 5)) 份省略）"; break; }
      echo "    · ${gy_a%%|*} [${gy_a##*|}]"
    done
  fi
  if [[ "$gy_wtdiff" -gt 0 ]]; then
    echo "ℹ️  gate.yaml 工作树 ≠ 判据基线: ${gy_wtdiff} 份（逐条=$((gy_wtdiff - gy_wt_info)) · 仅计数=${gy_wt_info}）⇒ 有人 checkout 过；判据按基线 ref（**未 fetch，按本地 origin/* 跟踪 ref**，要最新先 git fetch）"
  fi

  local uniq; uniq="$(printf '%s\n' ${seen_shas[@]+"${seen_shas[@]}"} | sort -u | wc -l)"
  if [[ "$uniq" -gt 1 ]]; then
    echo "⚠️  多份指纹并存（$uniq 种）——须收敛为单 REV 序列（见 tools/gate-fingerprints.txt）"; warn=$((warn+1)); warn_fleet=$((warn_fleet+1)); c_multi=$((c_multi+1))
  fi
  # --strict 只对本仓自身问题（warn_local）判红；舰队级未登记/待收敛**永远是 WARN+计数**
  #   （atlas 2026-10-22：--strict 只允许在本仓 PR 门禁里开，舰队级一律 WARN —— 否则 39 仓一夜全红）
  if [[ "$rc" -eq 0 && "$warn_local" -gt 0 && "$STRICT" -eq 1 ]]; then
    echo "❌ --strict: 本仓存在 $warn_local 条 WARN ⇒ rc=1"; rc=1; n_fail=$((n_fail+1))
  fi
  # 棘轮（atlas 2026-10-22）：收敛报必须有**会红的维度**，否则 41→39 靠人盯 = 另一种"绿但无牙"。
  #   欠账定义 = 未登记副本（pending 有主有期 / deprecated 归档件**不计**：混进总数两个方向都失真）
  if [[ -z "$DEBT_BUDGET" && -n "$DEBT_BUDGET_FILE" && -f "$DEBT_BUDGET_FILE" ]]; then
    DEBT_BUDGET="$(sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DEBT_BUDGET_FILE" | head -1)"
  fi
  if [[ -n "$DEBT_BUDGET" ]]; then
    local debt="${c_unreg:-0}"
    if ! [[ "$DEBT_BUDGET" =~ ^[0-9]+$ ]]; then
      echo "❌ --budget 必须是十进制整数（收到 '$DEBT_BUDGET'）⇒ rc=2（用法错误，不是欠账超标）"; return 2
    fi
    if [[ "$debt" -gt "$DEBT_BUDGET" ]]; then
      echo "❌ 欠账棘轮：未登记副本 debt=${debt} > budget=${DEBT_BUDGET}（新增未登记副本 ⇒ 判红；处置：登记/收敛/降级为 pending+owner+due）"
      rc=1
    elif [[ "$debt" -lt "$DEBT_BUDGET" ]]; then
      echo "✅ 欠账棘轮：debt=${debt} ≤ budget=${DEBT_BUDGET}（**budget 可下调到 ${debt}** —— 请在同一 PR 里下调，否则棘轮不前进）"
    else
      echo "✅ 欠账棘轮：debt=${debt} = budget=${DEBT_BUDGET}（持平；降一份就下调一份）"
    fi
  fi
  if [[ "$warn" -gt 0 ]]; then
    # 汇总分两桶（steward 2026-10-23）：**需要动作的置顶**，随批次的不抢注意力。
    #   否则 c_noexp=23 这类"随批次"数字会把 c_yanom=2 / rc=1 这些真要人动手的项淹掉。
    # 判据新鲜度必须常驻输出（steward 2026-10-23）：`c_branchonly` 10→5 的差额全是过期 ref 注水。
    #   没有这一行，读的人无法判断"本次数字是不是 fetch 过的"。
    if [[ "$CHECK_REMOTE" -eq 1 ]]; then
      echo "🔄 判据新鲜度: --check-remote=**on**（ls-remote 比对 ${gy_total} 仓：ref 过期并已 fetch 重判 ${gy_refstale} · 不可判 ${gy_refunknown}）"
    else
      echo "🔄 判据新鲜度: --check-remote=**off**（未校验 ref ⇒ c_branchonly/🟡🟢 可能因过期本地 ref 注水；要准请加 --check-remote）"
    fi
    if [[ "$gy_known" -gt 0 || "$gy_known_expired" -gt 0 ]]; then
      echo "📌 已知阻塞（仅标注·rc 不豁免）: 有效 ${gy_known} 条 · 已过期 ${gy_known_expired} 条（表：tools/gate-known-blockers.txt）"
    fi
    echo "── 需动作（置顶）: rc=1 项=${n_fail} · 未登记副本(c_unreg)=${c_unreg}（棘轮口径）· gate.yaml 顶层未知 key(c_yanom)=${gy_anom}（配置项类）· 门禁被吞(c_swallowed=${gy_swallowed})· 工作树侧异常(c_wt)=$((gy_wt_anom + gy_wt_flat))（不进 rc）· 门禁只在分支(c_branchonly=${gy_wt_branchonly}：真缺口 ${gy_real} / 待确认 ${gy_confirm} / 节奏差异 ${gy_rhythm})"
    echo "── 随批次（不阻断）: gate.yaml 缺 expected_gates(c_noexp)=${gy_noexp} · pending(c_pending)=${c_pending} · deprecated(c_deprecated)=${c_deprecated} · 缺真源声明(c_nodecl)=${c_nodecl} · 副本不存在(c_missing)=${c_missing} · 多指纹并存(c_multi)=${c_multi}"
    echo "warn 分类（按原因·机读）: 未登记副本(c_unreg)=${c_unreg} · 缺真源声明(c_nodecl)=${c_nodecl} · pending(c_pending)=${c_pending} · 副本不存在(c_missing)=${c_missing} · deprecated(c_deprecated)=${c_deprecated} · 多指纹并存(c_multi)=${c_multi} · gate.yaml 缺 expected_gates(c_noexp)=${gy_noexp} · gate.yaml 顶层未知 key(c_yanom)=${gy_anom} · 门禁被吞(c_swallowed)=${gy_swallowed} · 工作树侧异常(c_wt)=$((gy_wt_anom + gy_wt_flat)) · 门禁只在分支未合入(c_branchonly)=${gy_wt_branchonly}"
  fi
  echo "verify-source: checked=${checked} warn=${warn}（本仓 ${warn_local} · 舰队 ${warn_fleet}）⇒ rc=${rc}"
  return "$rc"
}

if [[ "$VERIFY_SOURCE" -eq 1 ]]; then
  verify_source; exit $?
fi

# --- 1. 从 gate.yaml 取「门禁项 → cmd」（零依赖极简解析，与 tools/gate.py 同一子集约定）---
GATE_DUMP="$(
python3 - "${GATE_YAML:-gate.yaml}" <<'PY' 2>/dev/null
import re, sys
path = sys.argv[1]
try:
    text = open(path, encoding="utf-8").read()
except OSError:
    sys.exit(3)
gates, cur = {}, None
for raw in text.splitlines():
    s = raw.strip()
    if not s or s.startswith("#"):
        continue
    ind = len(raw) - len(raw.lstrip())
    if ind == 0:
        cur = None
    elif ind == 2:
        m = re.match(r"^([\w-]+):\s*(.*)$", s)
        if m:
            cur = m.group(1); gates.setdefault(cur, {})
    elif ind == 4 and cur:
        m = re.match(r"^([\w-]+):\s*(.*)$", s)
        if m:
            k, v = m.group(1), m.group(2).strip().strip('"').strip("'")
            if v:
                gates[cur][k] = v
for name, cfg in gates.items():
    # ⚠️ 分隔符必须用**非空白**字符（\x1f）：用 TAB 时 bash 的 `IFS=$'\t' read` 会把连续空字段**折叠**，
    # 导致 `structure: type: structure`（无 cmd）被读成 cmd="structure" ⇒ 用例跑 `bash -c structure` ⇒ rc=127 假红。
    print(f"{name}\x1f{cfg.get('cmd','')}\x1f{cfg.get('type','')}")
PY
)"
if [[ -z "$GATE_DUMP" ]]; then
  echo "❌ 无法解析 ${GATE_YAML:-gate.yaml}（不存在或为空）⇒ rc=3（无法判定）" >&2
  exit 3
fi

declare -A GATE_CMD=() GATE_TYPE=()
while IFS=$'\x1f' read -r gid gcmd gtype; do
  [[ -z "$gid" ]] && continue
  GATE_CMD["$gid"]="$gcmd"; GATE_TYPE["$gid"]="$gtype"
done <<< "$GATE_DUMP"

if [[ -n "$ONLY" && -z "${GATE_CMD[$ONLY]+x}" ]]; then
  echo "❌ --only $ONLY：gate.yaml 里没有这个门禁项 ⇒ rc=2（用法错误）" >&2
  exit 2
fi

# --- 2. 用例枚举 ---
# 自检项本身不参与（否则递归）。判定方式：id=gate-selftest，或 cmd 里调用本脚本。
is_selftest_gate() { [[ "$1" == "gate-selftest" ]] || [[ "${GATE_CMD[$1]:-}" == *gate-selftest* ]]; }

# 目录名 `gate-<id>` 视为"针对该门禁判据本身"的用例（约定，便于区分"验判据"与"验主题"）
resolve_gid() {  # $1=用例目录名 → 真实 gate-id
  local g="$1"
  if [[ -z "${GATE_CMD[$g]+x}" && "$g" == gate-* && -n "${GATE_CMD[${g#gate-}]+x}" ]]; then
    printf '%s' "${g#gate-}"
  else
    printf '%s' "$g"
  fi
}

# 用例存在性 = **文件系统上 case.conf 存在且非空**（#650 A 方案 · hermetic）
#   · 不依赖 .git：`git archive` 解出的树（无 .git）与 clone 结论必须一致（§11.3.1 环境无关）
#   · 空目录/只有 files/ 的目录 ⇒ 不算用例（缺陷根因是"拿目录当用例"，不是"没用 git"）
#   · 附加（仅 git 可用时）：case.conf 未跟踪 ⇒ WARN（提醒"CI archive 看不到"，但不判红）
VALID_CASE_RE='^tests/(negative|positive)/[^/]+/[^/]+/case\.conf$'

# 路径合法性：只有 tests/<kind>/<gate-id>/<case>/case.conf（三层）才是用例。
# 其它层级不静默跳过 —— 打 WARN 并指出正确层级（否则别人会以为"负控没生效"）。
warn_bad_paths() {
  local f
  find tests -name case.conf 2>/dev/null | while IFS= read -r f; do
    [[ "$f" =~ $VALID_CASE_RE ]] && continue
    echo "⚠️  路径不合法的用例（会被跳过）：$f"
    echo "    正确层级：tests/<negative|positive>/<gate-id>/<case>/case.conf（三层，缺一层或多一层都不算用例）"
  done
}

collect_cases() {   # $1=kind(negative|positive) → 打印 "gate-id<TAB>case 路径"
  local kind="$1" conf rel rest
  for conf in tests/"$kind"/*/*/case.conf; do
    [[ -f "$conf" ]] || continue
    rel="${conf%/case.conf}"; rest="${rel#tests/$kind/}"
    printf '%s\t%s\n' "${rest%%/*}" "$rel"
  done
}

# 目录层级/材料校验：把"看起来是用例其实不是"的形态点名，而不是静默跳过
audit_case_dirs() {
  local kind="$1" d conf
  for d in tests/"$kind"/*/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"; conf="$d/case.conf"
    if [[ ! -f "$conf" ]]; then
      if [[ -d "$d/files" ]]; then
        echo "❌ 有 files/ 但缺 case.conf（无法判定期望，按 ERROR）: ${d#tests/}"; RC_CASE_ERR=$((RC_CASE_ERR+1))
      else
        echo "⚠️  目录存在但没有 case.conf ⇒ 不算用例（WARN）: ${d#tests/}"; WARN_N=$((WARN_N+1))
      fi
      continue
    fi
    if [[ ! -s "$conf" ]]; then
      echo "❌ case.conf 为空（无法判定期望，按 ERROR）: ${d#tests/}"; RC_CASE_ERR=$((RC_CASE_ERR+1)); continue
    fi
    if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      if ! git -C "$ROOT" ls-files --error-unmatch "$d/case.conf" >/dev/null 2>&1; then
        echo "⚠️  case.conf 未被 git 跟踪（CI 的 archive 树看不到它）: ${d#tests/}/case.conf"; WARN_N=$((WARN_N+1))
      fi
    fi
  done
}

RC_CASE_ERR=0
USAGE_ERR=0
STRICT_MISSING=0
WARN_N=0
NEG_CASES="$(collect_cases negative)"
POS_CASES="$(collect_cases positive)"
warn_bad_paths
audit_case_dirs negative
audit_case_dirs positive

if [[ "$LIST" -eq 1 ]]; then
  echo "门禁项 | 反例数 | 正控数 | 用例位置"
  echo "---|---|---|---"
  for gid in "${!GATE_CMD[@]}"; do
    is_selftest_gate "$gid" && continue
    n=$(grep -c "^${gid}	" <<< "$NEG_CASES" || true)
    p=$(grep -c "^${gid}	" <<< "$POS_CASES" || true)
    loc="tests/negative/${gid}/ tests/positive/${gid}/"
    [[ "${n:-0}" -eq 0 ]] && loc="**缺（未接入负控）**"
    echo "${gid} | ${n:-0} | ${p:-0} | ${loc}"
  done
  exit 0
fi

# --- 3. 边界：完全没有负控用例 ⇒ WARN + rc=0（存量仓不应一夜全红）---
if [[ -z "$NEG_CASES" && -z "$POS_CASES" ]]; then
  if [[ "$STRICT" -eq 1 ]]; then
    echo "❌ 本仓没有 tests/negative|positive/ 用例，且开了 --strict ⇒ rc=1"
    exit 1
  fi
  echo "⚠️  WARN: 本仓未接入负控用例（缺 tests/negative/）⇒ 放行（rc=0）"
  echo "    这不是「已具备」，只是「尚未接入」：按门禁规范 §11，判据需要有可执行反例。"
  echo "    接入方式：tests/negative/<gate-id>/<case>/files/ + case.conf（见 $0 头部注释）"
  exit 0
fi

# --- 4. 工作区与断言 ---
WORK_BASE="$(mktemp -d "${TMPDIR:-/tmp}/gate-selftest.XXXXXX")" || exit 3
trap 'rm -rf "$WORK_BASE"' EXIT

materialize() {  # $1=目标目录 $2=base(repo|empty)
  local ws="$1" base="$2"
  mkdir -p "$ws" || return 3
  [[ "$base" == "empty" ]] && return 0
  # 非 git 树（`git archive` 解出的发布包 / tarball）：没有 .git 可查 —— **整棵树就是工作区**，
  # 直接复制过去即可（#650 验收⑤：archive 树与 clone 结论必须一致）。
  if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    tar -c -C "$ROOT" . 2>/dev/null | tar -x -C "$ws" 2>/dev/null && return 0
    return 3
  fi
  if [[ "$BASE_MODE" == "worktree" ]]; then
    # 工作区口径：取**被 git 跟踪的文件当前的字节**（含未提交改动）——
    # 用于本地验证"我把某条判据改坏了，selftest 会不会红"，不必先提交坏代码。
    if git -C "$ROOT" ls-files -z 2>/dev/null | tar -c --null -C "$ROOT" -T - 2>/dev/null | tar -x -C "$ws" 2>/dev/null; then
      return 0
    fi
  fi
  if git -C "$ROOT" archive --format=tar HEAD 2>/dev/null | tar -x -C "$ws" 2>/dev/null; then
    return 0
  fi
  # 无 HEAD（空仓）或 archive 失败 ⇒ 用 index/工作树列表兜底
  if git -C "$ROOT" ls-files -z 2>/dev/null | tar -c --null -C "$ROOT" -T - 2>/dev/null | tar -x -C "$ws" 2>/dev/null; then
    return 0
  fi
  return 3
}

kv() {  # $1=case.conf 路径 $2=键 → 值（转义反斜杠原样返回）
  local f="$1" k="$2"
  [[ -f "$f" ]] || return 0
  sed -n "s/^${k}=//p" "$f" | head -1
}

PASS_N=0 FAIL_N=0 IO_N=0
FAILED_DESC=()

run_case() {  # $1=gate-id $2=case 路径 $3=expect
  local gid="$1" dir="$2" expect="$3"
  local conf="$dir/case.conf"
  local conf_expect; conf_expect="$(kv "$conf" expect)"; [[ -n "$conf_expect" ]] && expect="$conf_expect"
  local why; why="$(kv "$conf" why)"
  if [[ -z "$why" ]]; then
    echo "❌ 用例缺 why=（§11.1 交付物②「一句为何必须红」）: ${dir#tests/}"
    FAIL_N=$((FAIL_N+1)); FAILED_DESC+=("${gid}: ${dir#tests/} 缺 why="); return 1
  fi
  local cmd; cmd="$(kv "$conf" cmd)"; [[ -z "$cmd" ]] && cmd="${GATE_CMD[$gid]:-}"
  local base; base="$(kv "$conf" base)"; [[ -z "$base" ]] && base="repo"

  if [[ -z "$cmd" ]]; then
    # type: structure 的门禁项没有 cmd ⇒ 跑整个 runner（保持单一实现，不重复写结构判定）。
    # 不用 --only-gate：各仓 runner 可能是不同代的 gate.py（模板/技能/各仓三代并存），
    # 依赖新参数会让老 runner 上的用例假红。整跑同样满足"改坏 ⇒ 必红"。
    # 整跑 runner 时必须**排除自身**：runner 里含 `gate-selftest` 门禁 ⇒ 不排除就是自己跑自己（无限递归，实测挂死）
    if python3 tools/gate.py --help 2>/dev/null | grep -q -- "--exclude-gate"; then
      _excl="gate-selftest"
      [[ "$gid" != "gate-selftest" ]] && _excl="${_excl} --exclude-gate ${gid}"
      cmd="python3 tools/gate.py --stage all --exclude-gate ${_excl}"
    else
      cmd="python3 tools/gate.py --stage all"   # 旧 runner 无该参数：靠"跳过自身用例"兜底
    fi
  fi

  local ws; ws="$(mktemp -d "$WORK_BASE/ws.XXXXXX")" || { IO_N=$((IO_N+1)); return 3; }
  if ! materialize "$ws" "$base"; then
    echo "❌ 无法构造工作区（$dir）⇒ rc=3"; IO_N=$((IO_N+1)); return 3
  fi
  # 工作区空壳守卫（#649 复盘）：tar 参数顺序写错（`-T -` 之后的 `-C` 不生效）会解出**空工作区**，
  # 判据改坏了也照样绿 —— "负控看起来跑了其实没跑"。空壳一律 rc=3，绝不判 PASS。
  if [[ "$base" == "repo" && -z "$(find "$ws" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "❌ 工作区为空壳（${dir}）：materialize 失败 ⇒ rc=3（禁止把空壳当绿）"; IO_N=$((IO_N+1)); return 3
  fi
  # 依赖目录（node_modules/.venv）不入 git ⇒ fixture 里跑 npm/uv 脚本必然 127（"工具没装"），
  # 那是**假红**而不是判据生效。这里把仓根的依赖目录**软链**进 fixture（只读使用，不复制、不改动）。
  local dep
  for dep in node_modules .venv; do
    if [[ -d "$ROOT/$dep" && ! -e "$ws/$dep" ]]; then
      ln -s "$ROOT/$dep" "$ws/$dep" 2>/dev/null || true
    fi
  done

  # remove=<路径>[,<路径>]：从 fixture 里**删除**已跟踪的路径（"删掉必需目录/文件"这类反例需要减法，
  # 而 files/ 只能加法）。路径必须是相对仓根、且不能逃出工作区。
  local rm_list; rm_list="$(kv "$conf" remove)"
  if [[ -n "$rm_list" ]]; then
    local one
    IFS=',' read -ra _rms <<< "$rm_list"
    for one in "${_rms[@]}"; do
      [[ -z "$one" ]] && continue
      case "$one" in /*|..|../*) echo "❌ remove= 路径不合法（$one）: ${dir#tests/}"; IO_N=$((IO_N+1)); return 3 ;; esac
      rm -rf "${ws:?}/$one"
    done
  fi

  if [[ -d "$dir/files" ]]; then
    cp -a "$dir/files/." "$ws/" || { echo "❌ 叠加 files/ 失败（$dir）"; IO_N=$((IO_N+1)); return 3; }
    # `名称.__fixture__` → 落盘时去掉后缀：反例内容入库，但不会被本仓的**真实门禁**误扫
    while IFS= read -r -d '' f; do
      mv -- "$f" "${f%.__fixture__}"
    done < <(find "$ws" -name '*.__fixture__' -print0 2>/dev/null)
  fi

  local out rc
  out="$(cd "$ws" && ROOT="$ws" bash -c "${cmd//\{root\}/$ws}" 2>&1)"; rc=$?

  # 假绿守卫（2026-10-27 实测）：rc=127（命令不存在）/126（不可执行）说明**环境不全**，
  # 不能算"判据把坏的抓住了"。典型翻车：node 模板的负控在无 node_modules 的 fixture 里
  # 全部 rc=127，于是"expect=red"全绿 —— 判据其实一次都没跑。
  if [[ "$rc" -eq 127 || "$rc" -eq 126 ]] || grep -qE 'command not found|未找到命令|No such file or directory|not found: ' <<<"$out"; then
    # 用 `expect=case_err` 的用例来**负控这条守卫自身**（期望它被判无效）。
    if [[ "$expect" == "case_err" ]]; then
      PASS_N=$((PASS_N+1)); echo "PASS  ${gid}/${dir##*/}  expect=case_err rc=${rc}（守卫生效）"
    else
      echo "❌ 用例环境不全（rc=${rc}）⇒ 按 case_err 计，禁止当 PASS: ${dir#tests/}"
      printf '%s\n' "$out" | sed 's/^/      | /' | head -6
      RC_CASE_ERR=$((RC_CASE_ERR+1))
    fi
    return 1
  fi
  if [[ "$expect" == "case_err" ]]; then
    echo "❌ 该用例声明 expect=case_err，但 rc=${rc} 属正常返回（未触发环境守卫）: ${dir#tests/}"
    FAIL_N=$((FAIL_N+1)); FAILED_DESC+=("${gid}: ${dir#tests/} expect=case_err 未触发"); return 1
  fi

  local want="nonzero"; [[ "$expect" == "green" ]] && want="zero"
  local ok=0
  if [[ "$want" == "nonzero" && "$rc" -ne 0 ]]; then ok=1; fi
  if [[ "$want" == "zero" && "$rc" -eq 0 ]]; then ok=1; fi

  if [[ "$ok" -eq 1 ]]; then
    PASS_N=$((PASS_N+1))
    [[ "$QUIET" -eq 0 ]] && echo "PASS  ${gid}/${dir##*/}  expect=${expect} rc=${rc}"
  else
    FAIL_N=$((FAIL_N+1))
    FAILED_DESC+=("${gid}: ${dir#tests/} expect=${expect} 实际 rc=${rc}")
    echo "FAIL  ${gid}  ${dir#tests/}"
    echo "      expect=${expect}（${want}） 实际 rc=${rc}"
    [[ -n "$why" ]] && echo "      为何必须红: ${why}"
    printf '%s\n' "$out" | sed 's/^/      | /' | head -12
  fi
}

while IFS=$'\t' read -r gid dir; do
  [[ -z "$gid" ]] && continue
  gid="$(resolve_gid "$gid")"
  [[ -n "$ONLY" && "$gid" != "$ONLY" ]] && continue
  is_selftest_gate "$gid" && { [[ "$QUIET" -eq 0 ]] && echo "SKIP  ${gid}（自检项不自我递归）"; continue; }
  if [[ -z "${GATE_CMD[$gid]+x}" ]]; then
    # 用法错误不能静默：既点名，也**不把该用例算成覆盖**（否则"我加了个负控"是自我安慰）
    echo "⚠️  WARN: 用例指向 gate.yaml 里不存在的门禁项 '${gid}'（不是用例）: ${dir}"
    echo "    正确层级：tests/<negative|positive>/<gate-id>/<case>/case.conf（<gate-id> 必须是 gate.yaml 里的项）"
    WARN_N=$((WARN_N+1)); USAGE_ERR=$((USAGE_ERR+1)); continue
  fi
  run_case "$gid" "$dir" red
done <<< "$NEG_CASES"

while IFS=$'\t' read -r gid dir; do
  [[ -z "$gid" ]] && continue
  gid="$(resolve_gid "$gid")"
  [[ -n "$ONLY" && "$gid" != "$ONLY" ]] && continue
  is_selftest_gate "$gid" && continue
  [[ -z "${GATE_CMD[$gid]+x}" ]] && continue
  run_case "$gid" "$dir" green
done <<< "$POS_CASES"

# --- 5. 未接入的门禁项：WARN（不是 FAIL）---
MISSING=()
for gid in "${!GATE_CMD[@]}"; do
  is_selftest_gate "$gid" && continue
  [[ -n "$ONLY" && "$gid" != "$ONLY" ]] && continue
  if ! grep -q "^${gid}	" <<< "$NEG_CASES"; then MISSING+=("$gid"); fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "⚠️  WARN: 以下门禁项没有负控用例（缺 tests/negative/<id>/）：${MISSING[*]}"
  echo "    按规范 §11 它们是「未实现」，但本脚本默认放行（存量仓不应一夜全红）；建议各仓 owner 补用例后开 --strict。"
  WARN_N=$((WARN_N + ${#MISSING[@]}))
  if [[ "$STRICT" -eq 1 ]]; then
    STRICT_MISSING=1        # 不在中途 exit：统一在收尾按顺序报告（否则后面的判据不可达）
  fi
fi

echo "gate-selftest: pass=${PASS_N} fail=${FAIL_N} warn=${WARN_N} io=${IO_N} case_err=${RC_CASE_ERR} usage_err=${USAGE_ERR:-0}"
# warn 的语义（#802 A 项验收）：warn>0 表示"有门禁没有负控用例"= 规范 §11 的「未实现」。
# 这一行**必须始终打印 warn 计数**：--strict 通过时也要求 warn=0 出现，否则"少了用例"
# 会以"没报错"的形式隐身（atlas 2026-10-27 口径）。
[[ "${STRICT:-0}" == "1" && "${WARN_N}" == "0" ]] && echo "  └─ --strict: warn=0（无「未实现」门禁项，§11 达标）"

# 收尾：**先报告完所有判据，再决定 rc**（中途 exit 会让后面的判据永远不可达 —— #650 实锤）
RC=0
if [[ "${USAGE_ERR:-0}" -gt 0 ]]; then
  if [[ "$STRICT" -eq 1 ]]; then
    echo "❌ 用法错误：有 ${USAGE_ERR} 个用例指向不存在的门禁项（--strict ⇒ 判红）"; RC=1
  else
    echo "⚠️  用法错误：有 ${USAGE_ERR} 个用例指向不存在的门禁项（非 strict ⇒ WARN 放行）"
  fi
fi
if [[ "${STRICT_MISSING:-0}" -eq 1 ]]; then
  echo "❌ --strict：缺负控用例（${MISSING[*]:-}）⇒ rc=1"; RC=1
fi
if [[ "${RC_CASE_ERR:-0}" -gt 0 ]]; then
  echo "❌ 有 ${RC_CASE_ERR} 个用例无法判定（缺/空 case.conf、有 files/ 无 case.conf、或环境不全 rc=126/127）⇒ rc=1"; RC=1
fi
if [[ "$FAIL_N" -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_DESC[@]}"; RC=1
fi
if [[ "$RC" -eq 0 && "$IO_N" -gt 0 ]]; then
  echo "❌ 有 ${IO_N} 个用例无法判定（夹具/工作区问题）⇒ rc=3"; RC=3
fi
exit "$RC"
