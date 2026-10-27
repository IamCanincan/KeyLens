package com.iamcanincan.tsautoadd.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class CmdResult(val code: Int, val out: String, val err: String) {
  val ok get() = code == 0
}

/**
 * 与模块的唯一通道：仍然是 `webui.sh`。
 *
 * 为什么不把判定逻辑搬到 Kotlin 里：模块的命令行排查、WebUI、这个 App 三处必须
 * 看到同一套结论。判定只放在 shell 里一份，App 只负责显示 —— 这条在 WebUI 那一版
 * 就定下了，原生重构不改。
 */
object Shell {
  @Volatile
  var moduleDir: String = "/data/adb/modules/ts-auto-add"
    private set

  suspend fun exec(cmd: String): CmdResult = withContext(Dispatchers.IO) {
    try {
      val p = ProcessBuilder("su", "-c", cmd).start()
      val out = p.inputStream.bufferedReader().readText()
      val err = p.errorStream.bufferedReader().readText()
      val rc = p.waitFor()
      CmdResult(rc, out, err)
    } catch (t: Throwable) {
      CmdResult(-1, "", t.message ?: t.toString())
    }
  }

  /** 模块目录可能带后缀（`.update` / 停用后的重命名），按 id 找而不是写死。 */
  suspend fun resolveModuleDir(): Boolean {
    val r = exec(
      "for d in /data/adb/modules/*; do " +
        "  [ -f \"\$d/module.prop\" ] || continue; " +
        "  grep -qx 'id=ts-auto-add' \"\$d/module.prop\" && { echo \"\$d\"; break; }; " +
        "done"
    )
    val dir = r.out.lineSequence().firstOrNull { it.startsWith("/") }
    if (dir != null) moduleDir = dir
    return dir != null
  }

  suspend fun webui(cmd: String): CmdResult = exec("sh ${moduleDir}/webui.sh $cmd")

  /** key=value 输出解析（与 webui.sh 的约定一致） */
  fun parseKv(text: String): Map<String, String> {
    val out = LinkedHashMap<String, String>()
    text.lineSequence().forEach { line ->
      val i = line.indexOf('=')
      if (i > 0) out[line.substring(0, i)] = line.substring(i + 1)
    }
    return out
  }
}
