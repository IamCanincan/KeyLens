package com.iamcanincan.tsautoadd.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import com.iamcanincan.tsautoadd.data.AppState
import com.iamcanincan.tsautoadd.data.PropState
import com.iamcanincan.tsautoadd.ui.GroupTitle
import com.iamcanincan.tsautoadd.ui.Hint
import com.iamcanincan.tsautoadd.ui.StatBlock
import com.iamcanincan.tsautoadd.ui.StatusPill
import com.iamcanincan.tsautoadd.ui.Tone
import com.iamcanincan.tsautoadd.ui.TsCard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/* ============================ 概览 ============================ */

@Composable
fun OverviewScreen(state: AppState, contentPadding: androidx.compose.ui.unit.Dp) {
  val scope = rememberCoroutineScope()
  val st = state.status
  val have = state.targets.isNotEmpty() || state.installed.isNotEmpty()
  val conflict = st["conflict"] == "1"
  val stateTone = when (st["state"]) {
    "ok" -> Tone.OK
    "stopped", "failed" -> Tone.BAD
    else -> Tone.NA
  }

  LazyColumn(
    modifier = Modifier.fillMaxSize(),
    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 4.dp, bottom = contentPadding),
    verticalArrangement = Arrangement.spacedBy(16.dp),
  ) {
    item { HeroCard(state, stateTone) }
    item {
      TsCard {
        GroupTitle("同步链路")
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
          Box(Modifier.weight(1f)) {
            StatBlock("后端", st["backend_name"] ?: "—",
              tone = if (conflict) Tone.BAD else Tone.OK, note = st["data_dir"])
          }
          Box(Modifier.weight(1f)) {
            StatBlock("事件监听", state.env["inotify_mode"] ?: "读取中",
              tone = if (state.env["inotify_mode"] == "none") Tone.BAD else Tone.OK)
          }
        }
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
          Box(Modifier.weight(1f)) {
            StatBlock("守护进程", st["daemon_alive"]?.let { if (it == "0") "未运行" else "$it 个" } ?: "—",
              tone = if (st["daemon_alive"] == "0") Tone.BAD else Tone.OK, num = true)
          }
          Box(Modifier.weight(1f)) {
            StatBlock("日志缓冲", bytes(st["log_bytes"]), note = "${st["log_lines"] ?: 0} 行", num = true)
          }
        }
        Spacer(Modifier.height(20.dp))
        GroupTitle("配置与写入")
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
          Box(Modifier.weight(1f)) {
            StatBlock("常驻 rules.txt", "${state.rulesSet.size} 条",
              tone = if (st["rules_exists"] == "1") Tone.OK else Tone.BAD, note = st["rules_file"], num = true)
          }
          Box(Modifier.weight(1f)) {
            StatBlock("目标文件",
              if (st["target_exists"] == "1") "存在 · " + (if (st["target_writable"] == "1") "可写" else "不可写") else "不存在",
              tone = if (st["target_exists"] == "1" && st["target_writable"] == "1") Tone.OK else Tone.BAD,
              note = st["target_file"])
          }
        }
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
          Box(Modifier.weight(1f)) {
            StatBlock("上次写入", st["target_mtime"]?.toLongOrNull()?.let { timeLabel(it) } ?: "—")
          }
          Box(Modifier.weight(1f)) {
            StatBlock("属性伪装", if (st["props_masking"] == "off") "已关闭" else "开启",
              tone = if (st["props_masking"] == "off") Tone.NA else Tone.OK,
              note = if (state.env["resetprop"] == "1") "resetprop 可用" else "未找到 resetprop")
          }
        }
        Hint("模块只在开机与文件变化时同步，界面不会后台轮询；上面的数字每次下拉或点「重新读取」才更新。")
      }
    }
    if (!have && !state.busy) {
      item { Hint("正在读取列表…") }
    }
  }
}

@Composable
private fun HeroCard(state: AppState, tone: Tone) {
  val scope = rememberCoroutineScope()
  val st = state.status
  TsCard {
    Row(verticalAlignment = Alignment.CenterVertically) {
      StatusPill(
        when (st["state"]) {
          "ok" -> "运行中"
          "stopped" -> "已停止"
          "failed" -> "写入失败"
          else -> if (state.ready) "未知" else "连接中…"
        },
        tone,
      )
      Spacer(Modifier.width(8.dp))
      Text(
        st["mod_version"] ?: "—",
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
    Spacer(Modifier.height(10.dp))
    Row(verticalAlignment = Alignment.Bottom) {
      Text(
        if (state.ready) state.targets.size.toString() else "—",
        style = MaterialTheme.typography.displaySmall,
        fontWeight = FontWeight.ExtraBold,
        color = MaterialTheme.colorScheme.primary,
      )
      Spacer(Modifier.width(12.dp))
      Column(Modifier.padding(bottom = 6.dp)) {
        Text("生效应用数", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
        Text(
          "常驻 ${state.rulesSet.size} · 第三方 ${state.installed.size}",
          style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
      Spacer(Modifier.weight(1f))
      Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = { scope.launch { state.sync() } }, enabled = !state.busy) {
          Icon(Icons.Default.Sync, null, Modifier.size(18.dp))
          Spacer(Modifier.width(6.dp))
          Text("立即同步")
        }
        FilledTonalButton(onClick = { scope.launch { state.refresh() } }, enabled = !state.busy) {
          Icon(Icons.Default.Refresh, null, Modifier.size(18.dp))
          Spacer(Modifier.width(6.dp))
          Text("重新读取")
        }
      }
    }
  }
}

/* ============================ 常驻列表 ============================ */

@Composable
fun RulesScreen(state: AppState, contentPadding: androidx.compose.ui.unit.Dp) {
  val scope = rememberCoroutineScope()
  var draft by remember(state.rulesText) { mutableStateOf(state.rulesText) }
  var note by remember { mutableStateOf<String?>(null) }
  val dirty = draft != state.rulesText
  val stat = remember(draft) { rulesStats(draft) }

  LazyColumn(
    modifier = Modifier.fillMaxSize(),
    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 4.dp, bottom = contentPadding),
    verticalArrangement = Arrangement.spacedBy(16.dp),
  ) {
    item {
      TsCard {
        GroupTitle("每行一个包名 · # 开头为注释")
        OutlinedTextField(
          value = draft,
          onValueChange = { draft = it; note = null },
          modifier = Modifier.fillMaxWidth().height(240.dp),
          textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
        )
        Spacer(Modifier.height(8.dp))
        Text(
          buildString {
            append("有效包名 ${stat.valid} · 注释 ${stat.comment} · 空行 ${stat.blank}")
            if (dirty) append(" · 未保存")
          },
          style = MaterialTheme.typography.bodySmall,
          color = if (dirty) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (stat.suspect.isNotEmpty()) {
          Spacer(Modifier.height(8.dp))
          Surface(
            shape = MaterialTheme.shapes.small,
            color = MaterialTheme.colorScheme.errorContainer,
          ) {
            Text(
              "有 ${stat.suspect.size} 行不像包名，会一直匹配不到任何应用：" +
                stat.suspect.take(5).joinToString("、") { "第 ${it.first} 行「${it.second}」" },
              style = MaterialTheme.typography.bodySmall,
              color = MaterialTheme.colorScheme.onErrorContainer,
              modifier = Modifier.padding(10.dp),
            )
          }
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          Button(
            enabled = dirty && !state.busy,
            onClick = {
              scope.launch {
                val r = state.saveRules(draft)
                note = if (r.ok) "已保存并同步" else (r.err.ifBlank { "保存失败（退出码 ${r.code}）" })
              }
            },
          ) { Text("保存并同步") }
          TextButton(enabled = dirty, onClick = { draft = state.rulesText }) { Text("放弃修改") }
          TextButton(
            enabled = !state.busy,
            onClick = { draft = header() + draft },
          ) { Text("补默认注释头") }
        }
        note?.let { Hint(it) }
      }
    }
    if (state.rulesSet.isNotEmpty()) {
      item {
        TsCard {
          GroupTitle("当前常驻项 · ${state.rulesSet.size}")
          state.rulesSet.sorted().forEach { pkg ->
            AppLine(pkg, inTargets = pkg in state.targetSet, showAdd = false)
          }
        }
      }
    }
  }
}

private data class RulesStat(
  val valid: Int, val comment: Int, val blank: Int,
  val suspect: List<Pair<Int, String>>,
)

private fun rulesStats(text: String): RulesStat {
  var valid = 0; var comment = 0; var blank = 0
  val suspect = mutableListOf<Pair<Int, String>>()
  val pkgRe = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*$")
  text.lines().forEachIndexed { i, raw ->
    val l = raw.trim()
    when {
      l.isEmpty() -> blank++
      l.startsWith("#") -> comment++
      else -> {
        valid++
        if (!pkgRe.matches(l)) suspect += (i + 1) to l.take(40)
      }
    }
  }
  return RulesStat(valid, comment, blank, suspect)
}

private fun header() = """
  |# TS-AUTO-ADD 常驻应用列表
  |# 每行一个包名；以 # 开头的行是注释，空行会被忽略。
  |# 这里列出的包名会始终并入目标列表（即使应用当前未安装）。
  |
  |
""".trimMargin()

/* ============================ 应用 ============================ */

private data class Meta(val label: String, val icon: ImageBitmap?)

@Composable
fun AppsScreen(state: AppState, contentPadding: androidx.compose.ui.unit.Dp) {
  val scope = rememberCoroutineScope()
  val ctx = LocalContext.current
  var src by remember { mutableStateOf("targets") }
  var onlyMissing by remember { mutableStateOf(false) }
  var query by remember { mutableStateOf("") }

  val shown = remember(src, onlyMissing, query, state.targets, state.installed, state.rulesText) {
    val base = if (src == "targets") state.targets else state.installed
    var list = base
    if (src == "apps" && onlyMissing) list = list.filter { it !in state.targetSet }
    if (query.isNotBlank()) list = list.filter { it.contains(query, ignoreCase = true) }
    list
  }

  // 显示名与图标：PackageManager 直接给，比 WebUI 那边去读桌面图标缓存干净得多
  var meta by remember { mutableStateOf<Map<String, Meta>>(emptyMap()) }
  LaunchedEffect(shown) {
    val missing = shown.filter { it !in meta }
    if (missing.isEmpty()) return@LaunchedEffect
    val loaded = withContext(Dispatchers.IO) {
      missing.mapNotNull { pkg ->
        try {
          val pm = ctx.packageManager
          val ai = pm.getApplicationInfo(pkg, 0)
          pkg to Meta(pm.getApplicationLabel(ai).toString(), pm.getApplicationIcon(ai).toBitmap(96, 96).asImageBitmap())
        } catch (t: Throwable) {
          null
        }
      }.toMap()
    }
    meta = meta + loaded
  }

  LazyColumn(
    modifier = Modifier.fillMaxSize(),
    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 4.dp, bottom = contentPadding),
    verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    item {
      Column {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
          listOf("targets" to "生效列表", "apps" to "已安装").forEachIndexed { i, (v, label) ->
            SegmentedButton(
              selected = src == v,
              onClick = { src = v; if (v != "apps") onlyMissing = false },
              shape = SegmentedButtonDefaults.itemShape(i, 2),
            ) { Text(label) }
          }
        }
        Spacer(Modifier.height(10.dp))
        OutlinedTextField(
          value = query,
          onValueChange = { query = it },
          label = { Text("搜索应用名或包名") },
          singleLine = true,
          modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
          Text(
            if (src == "targets") "生效 ${state.targets.size}" else "已安装 ${state.installed.size}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
          Spacer(Modifier.width(6.dp))
          Text("· 显示 ${shown.size}", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
          Spacer(Modifier.weight(1f))
          if (src == "apps") {
            TextButton(onClick = { onlyMissing = !onlyMissing }) {
              Text(if (onlyMissing) "显示全部" else "只看未纳入")
            }
          }
        }
      }
    }
    items(shown, key = { it }) { pkg ->
      TsRow {
        AppLine(
          pkg = pkg,
          meta = meta[pkg],
          inTargets = pkg in state.targetSet,
          showAdd = src == "apps",
          onAdd = {
            scope.launch {
              val base = state.rulesText.trimEnd()
              val next = if (base.isBlank()) pkg else base + "\n" + pkg
              state.saveRules(next)
            }
          },
        )
      }
    }
  }
}

@Composable
private fun TsRow(content: @Composable () -> Unit) {
  Surface(
    shape = MaterialTheme.shapes.medium,
    color = MaterialTheme.colorScheme.surfaceContainerLow,
  ) { Box(Modifier.padding(horizontal = 10.dp, vertical = 8.dp)) { content() } }
}

@Composable
private fun AppLine(
  pkg: String,
  meta: Meta? = null,
  inTargets: Boolean,
  showAdd: Boolean,
  onAdd: (() -> Unit)? = null,
) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Box(
      Modifier.size(36.dp).background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(10.dp)),
      contentAlignment = Alignment.Center,
    ) {
      if (meta?.icon != null) {
        Image(meta.icon, null, Modifier.size(32.dp))
      } else {
        Text(
          pkg.substringAfterLast('.').take(1).uppercase(),
          style = MaterialTheme.typography.labelLarge,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
    }
    Spacer(Modifier.width(12.dp))
    Column(Modifier.weight(1f)) {
      Text(
        meta?.label ?: pkg,
        style = MaterialTheme.typography.bodyLarge,
        fontWeight = FontWeight.SemiBold,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
      )
      if (meta != null) {
        Text(
          pkg,
          style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
        )
      }
    }
    if (showAdd) {
      IconButton(onClick = { onAdd?.invoke() }) {
        Icon(Icons.Default.Add, "加入常驻列表", Modifier.size(20.dp))
      }
    } else if (inTargets) {
      Text(
        "生效",
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}

/* ============================ 日志 ============================ */

@Composable
fun LogScreen(state: AppState, contentPadding: androidx.compose.ui.unit.Dp) {
  val scope = rememberCoroutineScope()
  var tail by remember { mutableStateOf(60) }
  LaunchedEffect(Unit) { if (state.logLines.isEmpty()) state.loadLog(tail) }

  LazyColumn(
    modifier = Modifier.fillMaxSize(),
    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 4.dp, bottom = contentPadding),
    verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    item {
      Row(verticalAlignment = Alignment.CenterVertically) {
        SingleChoiceSegmentedButtonRow {
          listOf(30, 60, 120, 300).forEachIndexed { i, n ->
            SegmentedButton(
              selected = tail == n,
              onClick = { tail = n; scope.launch { state.loadLog(n) } },
              shape = SegmentedButtonDefaults.itemShape(i, 4),
            ) { Text("$n") }
          }
        }
        Spacer(Modifier.weight(1f))
        IconButton(onClick = { scope.launch { state.loadLog(tail) } }) {
          Icon(Icons.Default.Refresh, "刷新")
        }
        TextButton(onClick = { scope.launch { state.clearLog(); state.loadLog(tail) } }) { Text("清空") }
      }
    }
    item {
      TsCard {
        Text(
          "显示末尾 ${state.logLines.size} 行 · 缓冲 ${bytes(state.status["log_bytes"])} · 共 ${state.status["log_lines"] ?: 0} 行",
          style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        Surface(
          shape = MaterialTheme.shapes.medium,
          color = MaterialTheme.colorScheme.surfaceContainerLowest,
        ) {
          Column(Modifier.padding(10.dp)) {
            state.logLines.forEach { line ->
              val tone = when {
                line.contains("❌") || line.contains("失败") -> MaterialTheme.colorScheme.error
                line.contains("⚠") -> MaterialTheme.colorScheme.onSecondaryContainer
                else -> MaterialTheme.colorScheme.onSurface
              }
              Text(
                line,
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = tone,
                modifier = Modifier.padding(vertical = 1.dp),
              )
            }
          }
        }
      }
    }
  }
}

/* ============================ 属性 ============================ */

@Composable
fun PropsScreen(state: AppState, contentPadding: androidx.compose.ui.unit.Dp) {
  val scope = rememberCoroutineScope()
  LaunchedEffect(Unit) { if (state.props.isEmpty()) state.loadProps() }
  val bad = state.props.count { it.state != PropState.OK }
  val maskingOn = state.status["props_masking"] != "off"

  LazyColumn(
    modifier = Modifier.fillMaxSize(),
    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 4.dp, bottom = contentPadding),
    verticalArrangement = Arrangement.spacedBy(16.dp),
  ) {
    item {
      TsCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
          Column(Modifier.weight(1f)) {
            Text("开机时重置属性", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
            Text(
              if (maskingOn) "开机（Zygote 前）把上表写入" else "已关闭：下次开机不再写入",
              style = MaterialTheme.typography.bodySmall,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
          }
          Switch(
            checked = maskingOn,
            onCheckedChange = { on -> scope.launch { state.setPropsMasking(on) } },
            enabled = !state.busy,
          )
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          Button(enabled = !state.busy, onClick = { scope.launch { state.applyProps() } }) {
            Icon(Icons.Default.Check, null, Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("立即应用一次")
          }
          TextButton(onClick = { scope.launch { state.loadProps() } }) { Text("重新读取") }
        }
        Hint("共 ${state.props.size} 项 · 不符 $bad")
      }
    }
    item {
      TsCard {
        state.props.forEach { p ->
          Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
              Text(
                p.name,
                style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Monospace),
                maxLines = 1, overflow = TextOverflow.Ellipsis,
              )
              Text(
                if (p.state == PropState.DIFF) "实际 ${p.actual.ifBlank { "(空)" }} · 期望 ${p.expect}" else p.actual.ifBlank { "(空)" },
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
              )
            }
            Spacer(Modifier.width(10.dp))
            StatusPill(
              when (p.state) {
                PropState.OK -> "一致"
                PropState.DIFF -> "不符"
                PropState.MISSING -> "未定义"
              },
              when (p.state) {
                PropState.OK -> Tone.OK
                PropState.DIFF -> Tone.BAD
                PropState.MISSING -> Tone.NA
              },
            )
          }
        }
      }
    }
  }
}

/* ============================ 工具 ============================ */

private fun bytes(v: String?): String {
  val n = v?.toLongOrNull() ?: return "—"
  return when {
    n >= 1 shl 20 -> "%.1f MB".format(n / 1048576.0)
    n >= 1 shl 10 -> "%.1f KB".format(n / 1024.0)
    else -> "$n B"
  }
}

private fun timeLabel(epoch: Long): String {
  val f = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.getDefault())
  return f.format(java.util.Date(epoch * 1000))
}

@Suppress("unused")
@Composable
private fun Dot(color: androidx.compose.ui.graphics.Color, size: Int = 7) {
  Spacer(Modifier.size(size.dp).background(color, CircleShape))
}
