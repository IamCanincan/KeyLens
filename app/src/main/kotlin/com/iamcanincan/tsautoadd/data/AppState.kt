package com.iamcanincan.tsautoadd.data

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.Base64

/** 属性的三态：与 webui.sh 的 props 输出一致 */
enum class PropState { OK, DIFF, MISSING }

data class PropRow(val name: String, val actual: String, val expect: String, val state: PropState)

/**
 * 界面状态的唯一持有者。
 *
 * 每条数据都对应一次 `webui.sh` 调用；界面不做任何判定，只把返回值摊开。
 * 刷新是**拉取式**的：和 WebUI 一样不后台轮询，只在进入/点按/写操作后取。
 */
class AppState {
  var ready by mutableStateOf(false)
  var busy by mutableStateOf(false)
  var error by mutableStateOf<String?>(null)

  var status by mutableStateOf<Map<String, String>>(emptyMap())
  var env by mutableStateOf<Map<String, String>>(emptyMap())

  var targets by mutableStateOf<List<String>>(emptyList())
  var installed by mutableStateOf<List<String>>(emptyList())
  var rulesText by mutableStateOf("")

  var props by mutableStateOf<List<PropRow>>(emptyList())
  var logLines by mutableStateOf<List<String>>(emptyList())

  /** 包名 → (显示名, 图标)；来自 PackageManager，不再去抠桌面的图标缓存 */
  val appMeta = mutableStateMapOf<String, AppMeta>()

  val rulesSet: Set<String>
    get() = rulesText.lineSequence()
      .map { it.trim() }
      .filter { it.isNotEmpty() && !it.startsWith("#") }
      .toSet()

  val targetSet: Set<String> get() = targets.toHashSet()

  suspend fun refresh(deep: Boolean = true) {
    busy = true
    error = null
    try {
      if (Shell.resolveModuleDir().not()) {
        error = "找不到模块目录（/data/adb/modules/ts-auto-add*）"
        return
      }
      val st = Shell.webui("status")
      if (!st.ok) { error = st.err.ifBlank { "status 退出码 ${st.code}" }; return }
      status = Shell.parseKv(st.out)

      if (deep) {
        env = Shell.parseKv(Shell.webui("env").out)
        targets = Shell.webui("targets").out.lines().filter { it.isNotBlank() }
        installed = Shell.webui("apps").out.lines().filter { it.isNotBlank() }
        rulesText = Shell.webui("rules").out
      }
      ready = true
    } finally {
      busy = false
    }
  }

  suspend fun loadProps() {
    val r = Shell.webui("props")
    props = r.out.lines().filter { it.isNotBlank() }.mapNotNull { line ->
      val f = line.split('\t')
      if (f.size < 4) null else PropRow(
        name = f[0],
        actual = f[1],
        expect = f[2],
        state = when (f[3]) {
          "ok" -> PropState.OK
          "diff" -> PropState.DIFF
          else -> PropState.MISSING
        },
      )
    }
  }

  suspend fun loadLog(tail: Int) {
    logLines = Shell.webui("log $tail").out.lines().filter { it.isNotBlank() }
  }

  suspend fun saveRules(text: String): CmdResult {
    val b64 = Base64.getEncoder().encodeToString(text.toByteArray())
    val r = Shell.webui("save-rules $b64")
    if (r.ok) rulesText = text
    return r
  }

  suspend fun clearLog() { Shell.webui("clear-log") }

  suspend fun applyProps() {
    Shell.webui("props-apply")
    loadProps()
  }

  suspend fun setPropsMasking(on: Boolean) {
    Shell.webui(if (on) "props-on" else "props-off")
    refresh(deep = false)
  }

  suspend fun sync(): CmdResult {
    val r = Shell.webui("sync")
    if (r.ok) refresh(deep = true)
    return r
  }
}

data class AppMeta(val label: String, val pkg: String)
