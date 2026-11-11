// Whether this build can run the on-device Linux runtime at all.
//
// Every platform this app ships on can: Android unpacks a rootfs, and the
// foundation iOS line carries the NodeMobile engine in-process
// (EngineChannel.swift). Availability itself is dynamic — watch
// [localRuntimeProvider] (engine present and startable) and
// [localEngineAvailableProvider] (the person hasn't declined it) — this
// getter only gates what no build can ever do.
//
// Kept as an indirection so the「远程主机-only」shape stays expressible for
// future stripped builds (e.g. a pure-remote App Store variant).
bool get localRuntimeSupported => true;
