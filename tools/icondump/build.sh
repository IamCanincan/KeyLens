#!/bin/sh
# 重建 module/lib/icondump.dex（产物进模块，源在 tools/icondump/）
#
# 为什么把编译步骤写进仓库：这个 dex 是**二进制产物**，看不出它由什么源、什么参数
# 编出来的。按 Duck ToolBox 那条"可审计移植"的做法，把源与命令行一起留在库里，
# 任何人（包括未来的我）都能重放出同一份，而不是面对一个来历不明的 .dex。
#
# 依赖：JDK（javac）、Android SDK build-tools 的 d8、以及任一 platforms/android-XX/android.jar
# 用法：sh tools/icondump/build.sh [android-37.0]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SDK=${ANDROID_SDK_ROOT:-$HOME/AppData/Local/Android/Sdk}
PLATFORM=${1:-android-37.0}
AJAR="$SDK/platforms/$PLATFORM/android.jar"
D8="$SDK/build-tools/36.0.0/d8.bat"

[ -f "$AJAR" ] || { echo "找不到 $AJAR"; exit 1; }
[ -f "$D8" ] || { echo "找不到 $D8"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

javac -source 8 -target 8 -nowarn -classpath "$AJAR" -d "$TMP/cls" "$ROOT/tools/icondump/IconDump.java"
mkdir -p "$TMP/dex"          # d8 的 --output 要求目录已存在，它不会自己建
cmd //c "$(cygpath -w "$D8")" --min-api 26 --output "$(cygpath -w "$TMP/dex")" "$(cygpath -w "$TMP/cls/IconDump.class")"
cp "$TMP/dex/classes.dex" "$ROOT/module/lib/icondump.dex"
echo "已重建 module/lib/icondump.dex（$(wc -c < "$ROOT/module/lib/icondump.dex") 字节）"
