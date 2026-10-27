package com.iamcanincan.tsautoadd

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import com.iamcanincan.tsautoadd.data.AppState
import com.iamcanincan.tsautoadd.ui.TsApp
import com.iamcanincan.tsautoadd.ui.theme.TsTheme

class MainActivity : ComponentActivity() {
  private val state = AppState()

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    // 和 WebUI 那一版同一个决定：不藏系统栏，只让内容铺到边、由 insets 让位。
    enableEdgeToEdge()
    setContent {
      TsTheme {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
          TsApp(state)
        }
        LaunchedEffect(Unit) { state.refresh() }
      }
    }
  }
}
