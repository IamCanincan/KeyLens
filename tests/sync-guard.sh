#!/bin/sh
#=============================================================================
# tests/sync-guard.sh - 「已装读空但基线非空」的空列表保护（CI，不需要设备）
#
# 直接跑两个后端真实的 sync_* 包装：
#   · 默认（自动同步）：放弃写入、返回 2、目标文件逐字节不变、基线不推进
#   · TAA_EMPTY_OK=1（手动同步）：按当前已装处理（这里就是只剩手工项）
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/applist.sh"
. "$ROOT/module/lib/backend.sh"
. "$ROOT/module/backends/tricky.sh"

fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TAA_DIR="$T"
AWK_CMD="awk"
TAA_PATCH="$ROOT/module/backends/teesim.awk"
ST_INSTALLED="$T/.ts_installed_last"
ST_INSTALLED_NEW="$T/.ts_installed.new"

# 已装清单读空（模拟 pm 读取失败）；日志与描述写入都桩掉
cmd() { :; }
pm() { :; }
log_warn() { :; }
chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok   %-30s rc=%s\n' "$1" "$3"; else printf '  ✗    %-30s 期望 rc=%s，实得 %s\n' "$1" "$2" "$3"; fail=1; fi; }
setup() {
    printf 'a.manual\nb.inst\n' > "$1"
    printf 'b.inst\n' > "$ST_INSTALLED"
    rm -f "$ST_INSTALLED_NEW" "$T/tmp"
}

echo "── Tricky Store ──"
TAA_BACKEND="tricky"
TARGET_FILE="$T/target.txt"
setup "$TARGET_FILE"
sha=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
sync_target_list "$TARGET_FILE" "$T/tmp"; rc_is "自动同步放弃" 2 "$?"
chk "目标文件未变" "$sha" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"
[ ! -e "$ST_INSTALLED_NEW" ] && printf '  ok   基线没有推进\n' || { printf '  ✗   基线被推进了\n'; fail=1; }

setup "$TARGET_FILE"
TAA_EMPTY_OK=1 sync_target_list "$TARGET_FILE" "$T/tmp"; rc_is "手动同步写入" 0 "$?"
unset TAA_EMPTY_OK
chk "只剩手工项" "a.manual" "$(sed '/^$/d' "$TARGET_FILE" | tr '\n' ' ' | sed 's/ $//')"

echo "── TEE Simulator ──"
TAA_BACKEND="teesim"
TARGET_FILE="$T/config.json"
cat > "$TARGET_FILE" <<'EOF'
{
  "profiles": {
    "default": {
      "apps": [
        "a.manual",
        "b.inst"
      ],
      "mode": "keep"
    }
  },
  "extra": 1
}
EOF
printf 'b.inst\n' > "$ST_INSTALLED"; rm -f "$ST_INSTALLED_NEW" "$T/tmp"
sha=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
sync_teesim_config "$TARGET_FILE" "$T/tmp"; rc_is "自动同步放弃" 2 "$?"
chk "配置未变" "$sha" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"

TAA_EMPTY_OK=1 sync_teesim_config "$TARGET_FILE" "$T/tmp"; rc_is "手动同步写入" 0 "$?"
unset TAA_EMPTY_OK
chk "名单只剩手工项" "a.manual" "$(current_target_apps | tr '\n' ' ' | sed 's/ $//')"
grep -q '"mode": "keep"' "$TARGET_FILE" && printf '  ok   其它字段保留\n' || { printf '  ✗   mode 丢了\n'; fail=1; }

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit $fail
