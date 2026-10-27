package com.iamcanincan.tsautoadd.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * 主题：Material 3 Expressive + 跟随系统取色。
 *
 * 和 WebUI 那一版的关系：那边的配色是从 resource-cache 下的 frro 里手工解出
 * 强调色再推 OKLCH 令牌；原生这边直接 `dynamicLight/DarkColorScheme` —— 系统自己
 * 算好的 12 组色调表，一个字节都不用猜。这是"原生"最实质的一处收益。
 *
 * 形状档位与 WebUI 对齐（8 / 12 / 16 / 20 / 28），换哪边看都是同一套东西。
 */
private val TsShapes = Shapes(
  extraSmall = RoundedCornerShape(8.dp),
  small = RoundedCornerShape(12.dp),
  medium = RoundedCornerShape(16.dp),
  large = RoundedCornerShape(20.dp),
  extraLarge = RoundedCornerShape(28.dp),
)

/** Android 12 以下没有 Material You，退回模块界面同一支青蓝（跟着系统强调色走的那一支）。 */
private val FallbackLight = lightColorScheme(
  primary = Color(0xFF356570),
  onPrimary = Color(0xFFFFFFFF),
  primaryContainer = Color(0xFFB9EBF7),
  onPrimaryContainer = Color(0xFF001F25),
  secondary = Color(0xFF4B6268),
  onSecondary = Color(0xFFFFFFFF),
  secondaryContainer = Color(0xFFDCF5FC),
  onSecondaryContainer = Color(0xFF051F24),
  surface = Color(0xFFF8FDFF),
  onSurface = Color(0xFF191C1D),
  surfaceContainerLow = Color(0xFFF0F7F9),
  surfaceContainerHigh = Color(0xFFE4EBED),
  surfaceContainerHighest = Color(0xFFDEE3E5),
  onSurfaceVariant = Color(0xFF3F484A),
  outline = Color(0xFF6F797A),
  outlineVariant = Color(0xFFBFC8CA),
)

private val FallbackDark = darkColorScheme(
  primary = Color(0xFF83D3E4),
  onPrimary = Color(0xFF00363F),
  primaryContainer = Color(0xFF004E5B),
  onPrimaryContainer = Color(0xFFB9EBF7),
  secondary = Color(0xFFB2CBD2),
  onSecondary = Color(0xFF1C3439),
  secondaryContainer = Color(0xFF334A50),
  onSecondaryContainer = Color(0xFFDCF5FC),
  surface = Color(0xFF0E1415),
  onSurface = Color(0xFFDDE4E5),
  surfaceContainerLow = Color(0xFF161D1E),
  surfaceContainerHigh = Color(0xFF242B2C),
  surfaceContainerHighest = Color(0xFF2F3637),
  onSurfaceVariant = Color(0xFFBFC8CA),
  outline = Color(0xFF899394),
  outlineVariant = Color(0xFF3F484A),
)

@Composable
fun TsTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
  val ctx = LocalContext.current
  val colors = when {
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
      if (darkTheme) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
    darkTheme -> FallbackDark
    else -> FallbackLight
  }
  MaterialExpressiveTheme(colorScheme = colors, shapes = TsShapes, content = content)
}
