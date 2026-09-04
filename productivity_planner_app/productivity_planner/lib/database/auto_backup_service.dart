import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database_helper.dart';

/// A snapshot written by a different computer, newer than anything this one
/// has written.
///
/// Two computers share one snapshot folder and neither can merge with the
/// other, so the app offers the newer side rather than guessing.
class IncomingSnapshot {
  /// Creates a description of a snapshot found in the shared folder.
  const IncomingSnapshot({
    required this.file,
    required this.machine,
    required this.stamp,
    required this.data,
  });

  /// The snapshot file in the shared folder.
  final File file;

  /// Name of the computer that wrote it.
  final String machine;

  /// When it was written, parsed from the filename.
  final DateTime stamp;

  /// Decoded contents, ready to hand to the database import.
  final Map<String, dynamic> data;

  /// Number of queues the snapshot holds.
  int get queueCount => (data['queues'] as List?)?.length ?? 0;

  /// Number of tasks the snapshot holds.
  int get taskCount => (data['tasks'] as List?)?.length ?? 0;

  /// Short local time label for the prompt, e.g. "9/3 at 7:16 PM".
  String get whenLabel {
    final hour12 = stamp.hour % 12 == 0 ? 12 : stamp.hour % 12;
    final suffix = stamp.hour < 12 ? 'AM' : 'PM';
    final minute = stamp.minute.toString().padLeft(2, '0');
    return '${stamp.month}/${stamp.day} at $hour12:$minute $suffix';
  }
}

/// Writes automatic, timestamped JSON backups to a cloud-synced folder.
///
/// The live Hive database deliberately lives outside any synced folder, because
/// whole-file sync cannot safely merge a database that the app holds open. JSON
/// snapshots are a better fit: each one is a complete, self-contained file that
/// is only ever written once, so syncing them carries no risk of a torn or
/// conflicted database. The newest snapshot can be restored on another machine
/// through the existing import feature.
class AutoBackupService {
  /// Number of snapshots to keep per machine before the oldest are deleted.
  static const int keepCount = 20;

  /// Prefix shared by every automatic snapshot file.
  static const String filePrefix = 'autobackup_';

  /// This computer's name, embedded in the filenames it writes.
  ///
  /// Several machines share one snapshot folder, so a file has to say which
  /// one produced it. Without that, opening the app on a stale machine writes
  /// a snapshot that looks newest purely by timestamp, and importing it would
  /// overwrite fresher work done elsewhere.
  static String get machineName {
    var raw = Platform.environment['COMPUTERNAME'] ?? '';
    if (raw.isEmpty) {
      try {
        raw = Platform.localHostname;
      } on Exception {
        raw = '';
      }
    }
    final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '-');
    return safe.isEmpty ? 'unknown' : safe;
  }

  /// Filename prefix for snapshots written by this machine.
  static String get myPrefix => '$filePrefix${machineName}_';

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
      final file = File(p.join(dir.path, '$myPrefix$stamp.json'));
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

  /// Finds the newest snapshot from another computer worth offering.
  ///
  /// Returns null when there is nothing newer than this computer's own most
  /// recent snapshot, so a machine that is already current never prompts.
  /// Snapshots from before filenames carried a computer name are skipped:
  /// their origin is unknown, and this computer's own old files would
  /// otherwise look foreign. Never throws.
  Future<IncomingSnapshot?> findIncoming() async {
    try {
      final dir = await resolveBackupDir();
      if (dir == null) return null;

      final mine = await _snapshots(dir);
      final mineStamp =
          mine.isEmpty ? null : stampOf(p.basename(mine.first.path));

      File? bestFile;
      DateTime? bestStamp;
      String? bestMachine;

      for (final candidate in await _snapshots(dir, onlyThisMachine: false)) {
        final name = p.basename(candidate.path);
        if (name.startsWith(myPrefix)) continue;

        final machine = machineOf(name);
        final stamp = stampOf(name);
        if (machine == null || stamp == null) continue;
        if (mineStamp != null && !stamp.isAfter(mineStamp)) continue;
        if (bestStamp != null && !stamp.isAfter(bestStamp)) continue;

        bestFile = candidate;
        bestStamp = stamp;
        bestMachine = machine;
      }

      if (bestFile == null || bestStamp == null || bestMachine == null) {
        return null;
      }

      final decoded =
          jsonDecode(await bestFile.readAsString()) as Map<String, dynamic>;
      if (_isEmpty(decoded)) return null;

      return IncomingSnapshot(
        file: bestFile,
        machine: bestMachine,
        stamp: bestStamp,
        data: decoded,
      );
    } on Exception {
      return null;
    } on Error {
      return null;
    }
  }

  /// Timestamp encoded in a snapshot filename, or null if it does not parse.
  static DateTime? stampOf(String basename) {
    if (!basename.startsWith(filePrefix) || !basename.endsWith('.json')) {
      return null;
    }
    final body =
        basename.substring(filePrefix.length, basename.length - '.json'.length);
    final cut = body.lastIndexOf('_');
    final raw = cut == -1 ? body : body.substring(cut + 1);
    final parts = raw.split('T');
    if (parts.length != 2) return null;
    return DateTime.tryParse('${parts[0]}T${parts[1].replaceAll('-', ':')}');
  }

  /// Computer name encoded in a snapshot filename, or null for older files
  /// written before names carried one.
  static String? machineOf(String basename) {
    if (!basename.startsWith(filePrefix) || !basename.endsWith('.json')) {
      return null;
    }
    final body =
        basename.substring(filePrefix.length, basename.length - '.json'.length);
    final cut = body.lastIndexOf('_');
    return cut <= 0 ? null : body.substring(0, cut);
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
  /// Defaults to this machine's own snapshots, which is what comparison and
  /// pruning need: one computer must never prune or overwrite another's
  /// history. Names embed an ISO-8601 timestamp after a fixed prefix, so a
  /// reverse name sort is also a reverse chronological sort.
  Future<List<File>> _snapshots(
    Directory dir, {
    bool onlyThisMachine = true,
  }) async {
    final prefix = onlyThisMachine ? myPrefix : filePrefix;
    final files = <File>[];
    await for (final entity in dir.list()) {
      final name = p.basename(entity.path);
      if (entity is File &&
          name.startsWith(prefix) &&
          name.endsWith('.json')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    return files;
  }

  /// True when [data] is identical to this machine's newest snapshot apart
  /// from its timestamp, so an unchanged database does not fill the folder
  /// with copies.
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

  /// Deletes this machine's oldest snapshots beyond [keepCount].
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
