#!/system/bin/sh
#=============================================================================
# lib/common.sh - 函数库加载入口
#
# 说明：函数按功能拆分到 lib/ 下各文件，本文件只负责按顺序加载；
#       入口脚本需在 source 本文件前提供 MODDIR 或 MODPATH（模块根目录）。
#
# 加载清单（顺序即依赖顺序）：
#   core.sh     路径常量、运行期状态、系统日志
#   lock.sh     并发锁
#   tools.sh    外部工具定位（awk / inotify）
#   applist.sh  目标名单生成（增量同步）
#   backend.sh  后端探测、后端写入、模块描述、同步入口
#   props.sh    系统属性伪装
#   watch.sh    监听重启退避（纯函数，可被测试单独 source）
#=============================================================================

_kl_lib="${MODDIR:-$MODPATH}/lib"

for _kl_part in core lock tools applist backend props watch; do
    . "$_kl_lib/$_kl_part.sh" || return 1
done

unset _kl_lib _kl_part
