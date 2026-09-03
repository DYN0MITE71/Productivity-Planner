import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database_helper.dart';

/// Writes automatic, timestamped JSON backups to a cloud-synced folder.
///
/// The live Hive database deliberately lives outside any synced folder, because
/// whole-file sync cannot safely merge a database that the app holds open. JSON
/// snapshots are a better fit: each one is a complete, self-contained file that
/// is only ever written once, so syncing them carries no risk of a torn or
/// conflicted database. The newest snapshot can be restored on another machine
/// through the existing import feature.
class AutoBackupService {
  /// Number of snapshots to keep before the oldest are deleted.
  static const int keepCount = 20;

  /// Prefix shared by every automatic snapshot file.
  static const String filePrefix = 'autobackup_';

  /// Local database helper used to serialize app data.
  final DatabaseHelper _db = DatabaseHelper();

  /// Writes a snapshot unless the data is unchanged since the newest one.
  ///
  /// Returns the path written, or null if nothing was written. Never throws:
  /// a backup failure must not stop the app from opening or closing.
  Future<String?> run() async {
    try {
      final dir = await resolveBackupDir();
      if (dir == null) return null;

      final data = _db.exportData();
      if (_isEmpty(data)) return null;
      if (await _matchesNewest(dir, data)) return null;

      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File(p.join(dir.path, '$filePrefix$stamp.json'));
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );

      await _prune(dir);
      return file.path;
    } on Exception {
      return null;
    } on Error {
      return null;
    }
  }

  /// True when there is no data worth snapshotting.
  ///
  /// A fresh install comes up with empty boxes, and without this guard it would
  /// write an empty snapshot that then sits in the shared folder as the newest
  /// file. Importing that by mistake would replace a real database with nothing.
  bool _isEmpty(Map<String, dynamic> data) {
    final queues = data['queues'];
    final tasks = data['tasks'];
    final noQueues = queues is! List || queues.isEmpty;
    final noTasks = tasks is! List || tasks.isEmpty;
    return noQueues && noTasks;
  }

  /// Returns the folder snapshots are written to, creating it if needed.
  ///
  /// Prefers a OneDrive root when Windows exposes one, so snapshots sync to
  /// other machines automatically. Falls back to a local folder otherwise.
  Future<Directory?> resolveBackupDir() async {
    final env = Platform.environment;

    for (final key in const [
      'OneDriveCommercial',
      'OneDriveConsumer',
      'OneDrive',
    ]) {
      final root = env[key];
      if (root == null || root.isEmpty) continue;
      if (!await Directory(root).exists()) continue;
      return _ensure(p.join(root, 'Apps', 'ProductivityPlanner'));
    }

    try {
      final docs = await getApplicationDocumentsDirectory();
      return _ensure(p.join(docs.path, 'ProductivityPlannerBackups'));
    } on Exception {
      return null;
    }
  }

  /// Creates [path] if missing and returns it as a directory.
  Future<Directory> _ensure(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Snapshot files in [dir], newest first.
  ///
  /// Names embed an ISO-8601 timestamp, so a reverse name sort is also a
  /// reverse chronological sort.
  Future<List<File>> _snapshots(Directory dir) async {
    final files = <File>[];
    await for (final entity in dir.list()) {
      final name = p.basename(entity.path);
      if (entity is File &&
          name.startsWith(filePrefix) &&
          name.endsWith('.json')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    return files;
  }

  /// True when [data] is identical to the newest snapshot apart from its
  /// timestamp, so an unchanged database does not fill the folder with copies.
  Future<bool> _matchesNewest(Directory dir, Map<String, dynamic> data) async {
    final files = await _snapshots(dir);
    if (files.isEmpty) return false;
    try {
      final previous =
          jsonDecode(await files.first.readAsString()) as Map<String, dynamic>;
      return jsonEncode(_withoutTimestamp(previous)) ==
          jsonEncode(_withoutTimestamp(data));
    } on Exception {
      return false;
    }
  }

  /// Copy of [data] without the export timestamp, for content comparison.
  Map<String, dynamic> _withoutTimestamp(Map<String, dynamic> data) {
    final copy = Map<String, dynamic>.of(data);
    copy.remove('exportedAt');
    return copy;
  }

  /// Deletes the oldest snapshots beyond [keepCount].
  Future<void> _prune(Directory dir) async {
    final files = await _snapshots(dir);
    for (var i = keepCount; i < files.length; i++) {
      try {
        await files[i].delete();
      } on Exception {
        // A file locked by the sync client will be pruned on a later run.
      }
    }
  }
}
