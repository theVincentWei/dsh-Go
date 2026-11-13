/// The Host's own filesystem (`hostFiles/*`), as the desktop 文件 app browses
/// it: one folder at a time, folders and files alike, with sizes and times.
///
/// Contract (engine side):
/// `hostFiles/list` args `{path?: string, showHidden: boolean}` →
/// `{path, home, parent, entries: [{name, path, type, size?, mtime, hidden}],
/// truncated}`, where `type` is `directory | file | symlink | other` and
/// `mtime` is milliseconds since the epoch. Every `path` is absolute; clients
/// never join segments themselves.
///
/// The endpoint cannot be probed before its first call: [DshCarrier]
/// .allowsEndpoint returns true on the HTTP carrier whatever is registered, so
/// the first call decides (HTTP 404, or `METHOD_NOT_ALLOWED` from a relay) and
/// the caller caches the answer for that connection.
library;

import 'json.dart';
import 'session_api.dart';

/// What one `hostFiles/list` entry is.
enum DshHostFileType { directory, file, symlink, other }

/// One direct child of a host folder (`hostFiles/list`).
class DshHostFileEntry {
  const DshHostFileEntry({
    required this.name,
    required this.path,
    required this.type,
    this.size,
    this.mtime,
    this.hidden = false,
  });

  factory DshHostFileEntry.fromJson(Map<String, Object?> json) => DshHostFileEntry(
    name: asString(json['name']) ?? '',
    path: asString(json['path']) ?? '',
    type: switch (asString(json['type'])) {
      'directory' => DshHostFileType.directory,
      'file' => DshHostFileType.file,
      'symlink' => DshHostFileType.symlink,
      _ => DshHostFileType.other,
    },
    size: asInt(json['size']),
    mtime: asEpochMs(json['mtime']),
    hidden: json['hidden'] == true,
  );

  /// Base name inside the listed folder.
  final String name;

  /// Absolute Host path.
  final String path;
  final DshHostFileType type;

  /// Byte size of a regular file, when the Host reports it.
  final int? size;

  /// When the entry last changed.
  final DateTime? mtime;

  /// Dot-prefixed on POSIX; the client decides whether to show it.
  final bool hidden;

  bool get isDirectory => type == DshHostFileType.directory;
  bool get isFile => type == DshHostFileType.file;
}

/// One `hostFiles/list` level.
class DshHostFileListing {
  const DshHostFileListing({
    required this.path,
    this.home = '',
    this.parent,
    this.entries = const [],
    this.truncated = false,
  });

  factory DshHostFileListing.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DshHostFileListing(
      path: asString(map['path']) ?? '',
      home: asString(map['home']) ?? '',
      parent: asString(map['parent']),
      entries: [
        for (final entry in asListOrEmpty(map['entries']))
          if (asMap(entry) case final e? when (asString(e['name']) ?? '').isNotEmpty) DshHostFileEntry.fromJson(e),
      ],
      truncated: map['truncated'] == true,
    );
  }

  /// The listed folder, absolute.
  final String path;

  /// The Host account's home folder, absolute.
  final String home;

  /// The folder above [path]; null at the filesystem root.
  final String? parent;

  /// In the Host's order, cut to its entry cap.
  final List<DshHostFileEntry> entries;

  /// Whether the cap dropped children.
  final bool truncated;
}

extension DshHostFilesApi on DshClient {
  /// `hostFiles/list`: [path] (absolute) or, null, the Host's home folder.
  Future<DshHostFileListing> listHostFiles({String? path, bool showHidden = false}) async =>
      DshHostFileListing.fromJson(await rpc.call('hostFiles/list', {'path': ?path, 'showHidden': showHidden}));
}
