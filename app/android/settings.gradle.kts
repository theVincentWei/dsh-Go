pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Keep local mirror defaults; cloud CI can use the official upstreams.
        if (System.getenv("DSH_MAVEN_MIRRORS") != "0") {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/central") }
            maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

// Dimina 源码化说明:不使用复合构建(AGP 9.4/9.1 同构建互斥)。改为「它编它的、
// 我们编我们的」:在 ~/Code/dimina/android 用它自己的 gradle wrapper 执行
//   ./gradlew :dimina:publishToMavenLocal :engine_qjs:publishToMavenLocal
// 产物落 ~/.m2(com.github.didi.dimina:dimina:1.8.1),app 经上面 build.gradle.kts
// 的 mavenLocal() 优先命中——补丁迭代循环 = 改源码 → publishToMavenLocal → 重编 app。
