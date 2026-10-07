#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
grep -qs "{{" pom.xml 2>/dev/null && { echo "  （模板占位符未实例化，跳过）"; exit 0; }
true
