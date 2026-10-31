#!/system/bin/sh
#=============================================================================
# tests/kl-src.sh - 给套子一份"命令层的完整源码"，不用关心实现落在哪个文件
#
# 背景：命令层的实现分成两份 —— module/webui.sh（读路径 + 分派 + 契约）和
#       module/lib/write.sh（只有写命令才用的 19 个实现，按命令名懒加载，
#       省掉每次调用读+解析 42.8KB 的成本）。
#       套子要"抽某个函数出来跑/查"时，这个边界是噪音：写下去的断言会因为
#       函数搬家而集体变红（这次就有 5 个套子同时红），而它们真正守的东西一条没变。
#
# 用法：在套子 cd 到仓库根之后 `. tests/kl-src.sh`，然后把原来的
#       `module/webui.sh` 换成 "$KL_SRC"。函数不跨文件，所以按 ^cmd_x() { 抽取
#       与按 ^} 收尾都照旧成立。
#
# 注意：拼起来的顺序是 webui.sh 在前 —— 分派表与读路径的断言仍然只看得到它们该看的。
#=============================================================================

KL_TMP=$(mktemp -d 2>/dev/null || echo "/tmp/kl-src-$$")
mkdir -p "$KL_TMP"
KL_SRC="$KL_TMP/kl-command-layer.sh"
cat module/webui.sh module/lib/write.sh > "$KL_SRC" || { echo '无法拼命令层源码'; exit 1; }
KL_PARTS='module/webui.sh module/lib/write.sh'
