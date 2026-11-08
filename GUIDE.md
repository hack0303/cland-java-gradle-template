---
title: "cland-java-gradle-template 使用手册"
summary: "用本模板起一个 Java 25 + Gradle 项目：装、跑、常用场景、报错处置、交付判据与自检。按本页可在新机器上跑通。"
read_when:
  - "第一次用本模板起项目"
  - "交付/验收本模板生成的项目"
scope:
  - guide
status: "active"
updated: "2026-11-08"
---

# cland-java-gradle-template 使用手册

> 从模板 → 新项目：`cp -r` 后按本页改名字、跑门禁、交付。
> 规格与品味见生成项目的 `SPEC.md`；硬约束见 `RULES.md`；开发流程见 `AGENTS.md`。

## 1. 能做什么 / 不做什么

**能做**
- 一键得到一个 **Java 25 + Gradle 9 wrapper** 的可编译项目（含 spotless 格式化）
- 自带**统一门禁**：`doclint`（文档 front-matter）/ `structure` / `test` / **`guide`（GUIDE.md 合规）**
- 自带 `scripts/check.sh`（pre-commit 秒级 / CI 全量）与 `tools/gate.py`

**不做**
- 不帮你选框架（要 Web/DI 请用 `cland-quarkus-template`）
- 不含业务代码（`app/` 里只有 demo 入口）
- 不做容器化/部署（那归 `BUILD_CHAIN`/Jenkins 模板）

## 2. 前置条件

| 项 | 要求 | 怎么查 |
|---|---|---|
| JDK | **25+** | `java -version` |
| Gradle | 用仓内 wrapper（首次会下载发行版） | `bash ./gradlew --version` |
| 网络 | 首次需访问 `services.gradle.org` + `mavenCentral()` | `curl -sI https://services.gradle.org/distributions/ \| head -1` |
| Python 3 | 门禁脚本（`tools/gate.py` / `doclint.py`）需要 | `python3 -V` |

## 3. 安装与首次运行

```bash
$ cp -r ~/work/template/cland-java-gradle-template my-svc && cd my-svc
$ bash ./gradlew build
BUILD SUCCESSFUL
```
> 期望：末尾 `BUILD SUCCESSFUL`，rc=0（首次会下载 Gradle 9.5 与依赖）。

```bash
$ bash scripts/check.sh --stage fast
✅ 全部门禁通过（fast）
```
> 期望：`PASS`/`SKIP` 行之后出现 `✅ 全部门禁通过（fast）`，rc=0。

## 4. 任务配方

### 4.1 我要把模板改名成自己的项目
```bash
$ grep -rl "cland-hello" . --exclude-dir=.git --exclude-dir=gradle | xargs sed -i 's/cland-hello/my-svc/g'
$ bash ./gradlew -q build && echo ok
ok
```
> 期望：`ok`。改完必须重跑门禁（`bash scripts/check.sh --stage fast`）。

### 4.2 我要加一个可执行入口
```bash
$ $EDITOR app/src/main/java/org/cland/hello/ClandHello.java
$ bash ./gradlew -q run
Hello, World!
```
> 期望：你写的输出（模板默认为 `Hello, World!`）。

### 4.3 我要提交前快速自检（秒级）
```bash
$ bash scripts/install-hooks.sh
hooks installed
$ bash scripts/check.sh --stage fast
✅ 全部门禁通过（fast）
```
> 期望：`✅ 全部门禁通过（fast）`；pre-commit 只跑 `stage: fast` 且命中暂存文件的检查器。

### 4.4 我要检查文档是否合规（GUIDE/SPEC 等）
```bash
$ python3 tools/guide-check.py . --json
{"file": "./GUIDE.md", "sections": 10, "red": [], "warn": []}
```
> 期望：`"red": []`；有红项会打印 `❌ G1/G2/...` 并 rc=1。

## 5. 配置项

| 键 | 类型 | 默认 | 必填 | 生效方式 | 影响面 |
|---|---|---|---|---|---|
| `JAVA_HOME` | path | 系统默认 | 否 | 环境变量 | 决定工具链 JDK |
| `gate.yaml` `expected_gates` | int | 模板内置 | ✅（改门禁时） | 改文件 | **声明数必须等于实际解析数**，否则 gate 判红（防静默少跑） |
| `app/build.gradle` `applicationName` | string | `cland-hello` | 否 | 改文件 | 生成的启动脚本名 |

## 6. 常见错误与处置

### 6.1 `timeout: 无法运行命令 "./gradlew": 权限不够`
- **原因**：从模板 `cp -r` 后 `gradlew` 丢了执行位。
- **处置**：`chmod +x gradlew` 或改用 `bash ./gradlew …`（门禁里已统一用 `bash ./gradlew`）。

### 6.2 `gate: declared=3 parsed=2 ... fail=1` / `expected_gates` 不符
- **原因**：改了 `gate.yaml` 但没同步 `expected_gates`（或顶格写了未知 key 让解析中断）。
- **处置**：加/删 gate 后同步 `expected_gates`；确认新 gate 是**块状列表**缩进（禁止内联 `["a","b"]`）。

### 6.3 `FAIL guide: ❌ G2 安装 ... 代码块后无期望输出`
- **原因**：`GUIDE.md` 里贴了命令但没写期望输出/退出码（规范要求每条命令给期望输出）。
- **处置**：命令块后补一行 `> 期望：…`，或写进代码块（`rc=0` 也可）。

### 6.4 `FAIL doclint: MISSING HEADER`
- **原因**：新增 `.md` 缺 front-matter（`title/summary/read_when`）。
- **处置**：照任一现有 `.md` 补 front-matter；`read_when` 需 **2–4 条**。

## 7. 交付与验收

**交付物**：生成项目的源码仓（`gradlew` 可跑）+ `SPEC.md`/`RULES.md`/`GUIDE.md` 三件套 + 门禁全绿
**交付给**：项目 owner / 接手开发者（新机器照 `GUIDE.md` 能跑通即可接手）

| 判据 | 怎么验 | pass 条件 |
|---|---|---|
| 可构建 | `bash ./gradlew build` | `BUILD SUCCESSFUL` |
| 门禁全绿 | `bash scripts/check.sh --stage fast` | 末行 `✅ 全部门禁通过` |
| 文档合规 | `python3 tools/doclint.py .` | `rc=0` |
| GUIDE 合规 | `python3 tools/guide-check.py .` | `red: []`，rc=0 |
| 模板占位已清 | `grep -rn "cland-hello" . --exclude-dir=.git` | 无输出（或仅历史说明） |

## 8. 升级与回滚

- **升级模板**：`git remote add tmpl <模板仓>` → `git fetch tmpl && git merge tmpl/<branch>`；冲突多在 `gate.yaml` 与 `build.gradle`。
- **回滚**：`git revert <merge sha>`；门禁脚本与 `tools/` 属于模板自带，回滚后需重跑 `check.sh` 确认。
- **判据**：回滚后 `bash scripts/check.sh --stage fast` 仍全绿。

## 9. 边界与安全

- **不该做**：不要把业务代码写进 `app/src/main/java/org/cland/hello/`（包名应随项目改）；不要绕过 `check.sh` 用 `--no-verify` 提交。
- **数据敏感面**：模板不含凭据；凭据一律 `~/.env/<service>/<role>.env`（见 `env-spec`），**不得进仓**。
- **容量/并发**：模板本身无状态；并发只在构建层（Gradle daemon）。

## 10. 自检

```bash
$ bash scripts/check.sh --stage fast && python3 tools/guide-check.py . >/dev/null && echo SELFCHECK-OK
✅ 全部门禁通过（fast）
SELFCHECK-OK
```
> 期望：输出最后一行 `SELFCHECK-OK`，rc=0。
