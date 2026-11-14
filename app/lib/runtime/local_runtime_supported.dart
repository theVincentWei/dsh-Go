// Whether this build can run the on-device Linux runtime at all.
//
// iOS cannot: an app bundle may not carry executables or unpack a rootfs, so
// there is no runtime to install, unpack or start. Every 「本机」 entry point
// stays hidden there ([RuntimeChoiceView], HostSwitcher, RemoteScreen's
// 「切回本机」) and the app is remote-host only — the same shape as an Android
// phone whose person picked 远程主机 at first run.
//
// Widget tests run on the macOS host, so they keep exercising the Android
// (runtime-capable) behaviour.
import 'dart:io' show Platform;

bool get localRuntimeSupported => !Platform.isIOS;
