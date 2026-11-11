# R8 rules for the release build (Flutter adds its own on top).

# Conscrypt's pre-Lollipop socket adapters reference platform classes that
# don't exist on minSdk 26; those paths are never reached.
-dontwarn com.android.org.conscrypt.SSLParametersImpl
-dontwarn org.apache.harmony.xnet.provider.jsse.SSLParametersImpl

# 不打扰模式: the privileged process is started by class name, outside R8's
# view (Shizuku UserService, `app_process … PrivilegedDisplayMain` over self-ADB),
# and talks to the app through a hand-written Binder and Parcel/Bundle protocol.
-keep class io.github.ccch1mneyyy.dsh_app.phone.background.** { *; }

# Bouncy Castle and Conscrypt look providers and algorithms up by name;
# libadb-android drives both for wireless-debugging pairing and TLS.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-keep class org.conscrypt.** { *; }
-keep class io.github.muntashirakon.adb.** { *; }

# Dimina 容器的 MiniProgram 以 Parcelable extra 跨进程传给 DiminaActivity;
# Android 的 Bundle 惰性解包 + 任务记录会把 parcel 缓存到下一次读取,跨构建
# 版本时旧 parcel 里的混淆类名在新 dex 无对应 → BadParcelableException 在
# onCreate 炸掉整个宿主进程。bean 类保持原名原成员,parcel 永远可解。
-keep class com.didi.dimina.bean.** { *; }
