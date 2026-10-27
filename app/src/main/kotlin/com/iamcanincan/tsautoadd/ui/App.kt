package com.iamcanincan.tsautoadd.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.iamcanincan.tsautoadd.data.AppState
import com.iamcanincan.tsautoadd.ui.screens.AppsScreen
import com.iamcanincan.tsautoadd.ui.screens.LogScreen
import com.iamcanincan.tsautoadd.ui.screens.OverviewScreen
import com.iamcanincan.tsautoadd.ui.screens.PropsScreen
import com.iamcanincan.tsautoadd.ui.screens.RulesScreen
import kotlinx.coroutines.launch

enum class Tab(val label: String, val icon: ImageVector) {
  OVER("概览", Icons.Default.Home),
  RULES("常驻", Icons.Default.List),
  APPS("应用", Icons.Default.Apps),
  LOG("日志", Icons.Default.Article),
  PROPS("属性", Icons.Default.Tune),
}

/**
 * 外壳：顶栏 + 五个页面（HorizontalPager）+ 悬浮药丸底栏。
 *
 * Pager 是「当前在第几页」的唯一真相：左右滑动由它更新，点底栏则滚过去，
 * 两边不会各存一份而打架。顶栏标题也跟着它变 —— 原生这边标题栏和底栏都常驻，
 * 不像 WebUI 那边要滚走英雄卡。
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun TsApp(state: AppState) {
  val pager = rememberPagerState(pageCount = { Tab.entries.size })
  val scope = rememberCoroutineScope()

  Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize()) {
      TopBar(state, Tab.entries[pager.currentPage])
      HorizontalPager(
        state = pager,
        modifier = Modifier.fillMaxSize(),
        verticalAlignment = Alignment.Top,
        key = { Tab.entries[it].name },
      ) { page ->
        when (Tab.entries[page]) {
          Tab.OVER -> OverviewScreen(state, contentPadding = navSpace())
          Tab.RULES -> RulesScreen(state, contentPadding = navSpace())
          Tab.APPS -> AppsScreen(state, contentPadding = navSpace())
          Tab.LOG -> LogScreen(state, contentPadding = navSpace())
          Tab.PROPS -> PropsScreen(state, contentPadding = navSpace())
        }
      }
    }

    FloatingNavBar(
      selected = pager.currentPage,
      onSelect = { scope.launch { pager.animateScrollToPage(it) } },
      modifier = Modifier
        .align(Alignment.BottomCenter)
        .navigationBarsPadding()
        .padding(bottom = 20.dp),
    )
  }
}

/** 列表底部给药丸让出的空间：药丸约 56 + 距导航栏 20 + 一点余量 */
private fun navSpace() = 96.dp

@Composable
private fun TopBar(state: AppState, tab: Tab) {
  val dev = listOfNotNull(
    state.env["brand"]?.takeIf { it.isNotBlank() },
    state.env["device"]?.takeIf { it.isNotBlank() },
    state.env["android"]?.takeIf { it.isNotBlank() }?.let { "Android $it" },
  ).joinToString(" · ")
  Row(
    modifier = Modifier
      .fillMaxWidth()
      .padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 8.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Column {
      Text(
        dev.ifBlank { "TS-AUTO-ADD" },
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
      )
      Text(
        tab.label,
        style = MaterialTheme.typography.titleLarge,
        fontWeight = FontWeight.Bold,
      )
    }
    Spacer(Modifier.weight(1f))
    state.status["mod_version"]?.let {
      Text(
        it,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}

/**
 * 悬浮药丸底栏：选中那格展开文字、其余只留图标，所以宽度随当前页变化。
 * 底色用 surfaceContainerHigh + 1dp 描边，不靠阴影 —— 深色下阴影看不见。
 */
@Composable
private fun FloatingNavBar(
  selected: Int,
  onSelect: (Int) -> Unit,
  modifier: Modifier = Modifier,
) {
  Surface(
    modifier = modifier,
    shape = RoundedCornerShape(28.dp),
    color = MaterialTheme.colorScheme.surfaceContainerHigh,
    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    shadowElevation = 8.dp,
  ) {
    Row(
      modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
      horizontalArrangement = Arrangement.spacedBy(4.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      Tab.entries.forEachIndexed { i, tab ->
        NavItem(tab, i == selected) { onSelect(i) }
      }
    }
  }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun NavItem(tab: Tab, active: Boolean, onClick: () -> Unit) {
  val scheme = MaterialTheme.colorScheme
  val motion = MaterialTheme.motionScheme
  val container by animateColorAsState(
    if (active) scheme.secondaryContainer else androidx.compose.ui.graphics.Color.Transparent,
    motion.defaultEffectsSpec(),
    label = "navContainer",
  )
  val content by animateColorAsState(
    if (active) scheme.onSecondaryContainer else scheme.onSurfaceVariant,
    motion.defaultEffectsSpec(),
    label = "navContent",
  )
  Surface(
    modifier = Modifier.semantics { selected = active },
    onClick = onClick,
    shape = RoundedCornerShape(50),
    color = container,
    contentColor = content,
  ) {
    Row(
      modifier = Modifier
        .animateContentSize(motion.defaultSpatialSpec())
        .padding(horizontal = 12.dp, vertical = 10.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      Icon(tab.icon, contentDescription = tab.label, modifier = Modifier.size(24.dp))
      if (active) {
        Spacer(Modifier.width(6.dp))
        Text(tab.label, style = MaterialTheme.typography.labelLarge, maxLines = 1)
      }
    }
  }
}

/** 页面通用的左右内边距：和顶栏的 20dp 对齐 */
@Composable
fun ScreenScaffold(
  contentPadding: androidx.compose.foundation.layout.PaddingValues,
  content: @Composable () -> Unit,
) {
  Box(Modifier.fillMaxSize()) {
    Column(
      modifier = Modifier
        .fillMaxSize()
        .padding(horizontal = 20.dp),
    ) {
      content()
      Spacer(Modifier.height(1.dp))
    }
  }
}
