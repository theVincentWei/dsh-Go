// 上次播放到哪:每个视频一条记录,存在 SharedPreferences 的单键 JSON 里
// (与外观/宠物等偏好同一套存储)。键按 主机+会话+路径 哈希,换主机或文件
// 改名互不串位;条目数有上限,最旧的先淘汰。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding the whole `{hash: entry}` map as one JSON.
const String videoProgressPrefsKey = 'video_progress';

/// One remembered playback position.
@immutable
class VideoProgressEntry {
  const VideoProgressEntry({
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  /// Where playback stopped.
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static VideoProgressEntry? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final position = (json['positionMs'] as num?)?.toInt();
    final duration = (json['durationMs'] as num?)?.toInt();
    final updated = (json['updatedAt'] as num?)?.toInt();
    if (position == null || position <= 0 || duration == null || duration <= 0 || updated == null) return null;
    return VideoProgressEntry(
      positionMs: position,
      durationMs: duration,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updated),
    );
  }
}

/// Reads and writes the remembered positions. Plain values, no secrets —
/// SharedPreferences is the same home as the other appearance prefs.
class VideoProgressStore {
  VideoProgressStore({SharedPreferences? prefs, this.maxEntries = 200, DateTime Function()? now})
    : _prefsOverride = prefs,
      _now = now ?? DateTime.now;

  final SharedPreferences? _prefsOverride;
  final int maxEntries;
  final DateTime Function() _now;

  /// Stable identity of one video on one Host: 主机 + 会话 + 路径, hashed so
  /// the stored map stays flat. A different Host (or a renamed file) never
  /// inherits another entry.
  static String keyFor({String? hostId, required String sessionId, required String path}) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode('$hostId\n$sessionId\n$path')) {
      hash ^= byte & 0xff;
      hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Future<SharedPreferences> _store() async => _prefsOverride ?? await SharedPreferences.getInstance();

  Future<Map<String, VideoProgressEntry>> _all() async {
    final raw = (await _store()).getString(videoProgressPrefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return {};
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (key is String) key: ?VideoProgressEntry.fromJson(value),
      };
    } on Object {
      // A corrupted entry must never break playback; start from nothing.
      return {};
    }
  }

  Future<void> _writeAll(Map<String, VideoProgressEntry> entries) async {
    while (entries.length > maxEntries) {
      String? oldest;
      var stamp = DateTime.now();
      for (final MapEntry(key: key, value: entry) in entries.entries) {
        if (entry.updatedAt.isBefore(stamp)) {
          stamp = entry.updatedAt;
          oldest = key;
        }
      }
      if (oldest == null) break;
      entries.remove(oldest);
    }
    await (await _store()).setString(
      videoProgressPrefsKey,
      jsonEncode({for (final MapEntry(key: key, value: entry) in entries.entries) key: entry.toJson()}),
    );
  }

  /// The remembered position for [key], or null.
  Future<VideoProgressEntry?> load(String key) async => (await _all())[key];

  /// Remembers [positionMs] for [key]; keeps at most [maxEntries] entries.
  Future<void> save(String key, {required int positionMs, required int durationMs}) async {
    if (positionMs <= 0 || durationMs <= 0) return;
    final entries = await _all();
    entries[key] = VideoProgressEntry(positionMs: positionMs, durationMs: durationMs, updatedAt: _now());
    await _writeAll(entries);
  }

  /// Forgets [key] (看完的视频下次从头播).
  Future<void> clear(String key) async {
    final entries = await _all();
    if (entries.remove(key) == null) return;
    final store = await _store();
    if (entries.isEmpty) {
      await store.remove(videoProgressPrefsKey);
      return;
    }
    await _writeAll(entries);
  }
}

final videoProgressStoreProvider = Provider<VideoProgressStore>((ref) => VideoProgressStore());
