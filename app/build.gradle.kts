import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.kotlin.compose)
}

android {
  namespace = "com.iamcanincan.tsautoadd"
  compileSdk = 37

  buildFeatures {
    compose = true
    buildConfig = true
  }

  defaultConfig {
    applicationId = "com.iamcanincan.tsautoadd"
    minSdk = 31
    targetSdk = 37
    versionCode = 1
    versionName = "1.0.0"
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }

  buildTypes {
    release {
      // 先用 debug 签名出包：这是新装的一个普通应用，不走模块签名那套。
      signingConfig = signingConfigs.getByName("debug")
      isMinifyEnabled = false
    }
  }
}

// 不要用 jvmToolchain(17)：这台机器只装了 JDK 21，声明 toolchain 会让 Gradle
// 去找一个不存在的 JDK 17（"Cannot find a Java installation"）。直接钉字节码目标即可。
kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_17 } }

dependencies {
  implementation(platform(libs.compose.bom))
  implementation(libs.compose.ui)
  implementation(libs.compose.ui.graphics)
  implementation(libs.compose.ui.tooling.preview)
  implementation(libs.compose.material3)
  implementation(libs.compose.material.icons.extended)
  implementation(libs.activity.compose)
  implementation(libs.core.ktx)
  debugImplementation(libs.compose.ui.tooling)
}
