package com.iamcanincan.tsautoadd.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * 全应用统一的卡片：一档底色 + 1dp 描边 + shapes.large。
 *
 * 与 Opticon 的 [OpticonCard] 同一套做法：底色用 surfaceContainerLow 而不是 surface ——
 * 深色下 surface 与背景几乎同色，靠阴影分界在深色里等于没有；描边把边界钉死。
 */
@Composable
fun TsCard(
  modifier: Modifier = Modifier,
  onClick: (() -> Unit)? = null,
  content: @Composable ColumnScopeAlias.() -> Unit,
) {
  val shape = MaterialTheme.shapes.large
  val base = modifier.fillMaxWidth()
  if (onClick != null) {
    Surface(
      modifier = base,
      shape = shape,
      color = MaterialTheme.colorScheme.surfaceContainerLow,
      border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
      onClick = onClick,
      content = { Column(Modifier.padding(20.dp)) { content() } },
    )
  } else {
    Surface(
      modifier = base,
      shape = shape,
      color = MaterialTheme.colorScheme.surfaceContainerLow,
      border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
      Column(Modifier.padding(20.dp)) { content() }
    }
  }
}

/** 只是为了在签名里写 content 而不引入 ColumnScope 的别名 */
typealias ColumnScopeAlias = androidx.compose.foundation.layout.ColumnScope

/** 组标题：卡内的小节名，和外面的大标题区分开 */
@Composable
fun GroupTitle(text: String, modifier: Modifier = Modifier) {
  Text(
    text = text,
    style = MaterialTheme.typography.labelLarge,
    color = MaterialTheme.colorScheme.onSurfaceVariant,
    modifier = modifier.padding(bottom = 8.dp),
  )
}

/** 状态点 + 文字：正常态只画灰点（不刷一片绿），异常才用容器色 */
@Composable
fun StatusPill(text: String, tone: Tone, modifier: Modifier = Modifier) {
  val scheme = MaterialTheme.colorScheme
  val fg = when (tone) {
    Tone.OK -> scheme.onSurfaceVariant
    Tone.NA -> scheme.onSurfaceVariant
    Tone.WARN -> scheme.onSecondaryContainer
    Tone.BAD -> scheme.onErrorContainer
  }
  val bg = when (tone) {
    Tone.WARN -> scheme.secondaryContainer
    Tone.BAD -> scheme.errorContainer
    else -> androidx.compose.ui.graphics.Color.Transparent
  }
  val dot = when (tone) {
    Tone.OK -> scheme.primary
    Tone.BAD -> scheme.error
    Tone.WARN -> scheme.secondary
    Tone.NA -> scheme.outline
  }
  Row(
    modifier = modifier
      .then(if (bg != androidx.compose.ui.graphics.Color.Transparent) Modifier.background(bg, CircleShape) else Modifier)
      .padding(horizontal = if (bg != androidx.compose.ui.graphics.Color.Transparent) 10.dp else 0.dp, vertical = 2.dp),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(6.dp),
  ) {
    if (tone != Tone.OK) {
      Spacer(Modifier.size(7.dp).background(dot, CircleShape))
    }
    Text(text, style = MaterialTheme.typography.bodyMedium, color = fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
  }
}

enum class Tone { OK, NA, WARN, BAD }

/** 一格：标签在上、值在下。数字走大一号，靠字号分层而不是给每个值上色。 */
@Composable
fun StatBlock(
  label: String,
  value: String,
  modifier: Modifier = Modifier,
  note: String? = null,
  tone: Tone? = null,
  num: Boolean = false,
) {
  Surface(
    modifier = modifier,
    shape = MaterialTheme.shapes.medium,
    color = MaterialTheme.colorScheme.surfaceContainerHigh,
  ) {
    Column(Modifier.padding(14.dp)) {
      Text(
        label,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
      )
      Spacer(Modifier.height(3.dp))
      if (tone != null) {
        StatusPill(value, tone)
      } else {
        Text(
          value,
          style = if (num) MaterialTheme.typography.headlineSmall else MaterialTheme.typography.bodyLarge,
          color = MaterialTheme.colorScheme.onSurface,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
        )
      }
      if (note != null) {
        Spacer(Modifier.height(3.dp))
        Text(
          note,
          style = MaterialTheme.typography.labelSmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
        )
      }
    }
  }
}

/** 图标底座：和 Opticon 的 IconBadge 同尺寸，避免每个页面各画一个 */
@Composable
fun IconTile(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
  Surface(
    modifier = modifier.size(40.dp),
    shape = RoundedCornerShape(12.dp),
    color = MaterialTheme.colorScheme.surfaceContainerHighest,
  ) {
    Column(Modifier.padding(8.dp)) { content() }
  }
}

@Composable
fun Hint(text: String, modifier: Modifier = Modifier) {
  Text(
    text,
    style = MaterialTheme.typography.bodySmall,
    color = MaterialTheme.colorScheme.onSurfaceVariant,
    modifier = modifier.padding(top = 8.dp),
  )
}

@Suppress("unused")
@Composable
private fun ClickableRowPreview() {
  Row(Modifier.clickable { }.fillMaxWidth().padding(horizontal = 4.dp)) { }
  Spacer(Modifier.width(0.dp))
}
