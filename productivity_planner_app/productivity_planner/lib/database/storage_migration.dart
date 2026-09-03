import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves where Hive box files live, and moves them out of legacy locations.
///
/// Earlier versions of the app called `Hive.initFlutter()` with no argument,
/// which drops box files directly into the user's Documents folder. That folder
/// is redirected by cloud-sync tools such as OneDrive Known Folder Move, so a
/// redirect silently pointed the app at an empty directory and it created fresh,
/// empty boxes. This class stores boxes under the application support directory
/// instead, which is never redirected or synced, and copies any existing data
/// across on first launch.
class StorageMigration {
  /// Box names owned by the app, without file extensions.
  static const List<String> boxNames = ['queues', 'tasks', 'settings'];

  /// Marker file written once the legacy copy has been attempted.
  static const String markerName = '.storage_migrated';

  /// Returns the directory Hive should use, migrating legacy boxes if needed.
  ///
  /// The returned directory is created if it does not already exist. Migration
  /// runs at most once; afterwards the marker file short-circuits the check.
  static Future<Directory> resolve() async {
    final target = await getApplicationSupportDirectory();
    if (!await target.exists()) {
      await target.create(recursive: true);
    }

    final marker = File(p.join(target.path, markerName));
    if (await marker.exists()) return target;

    final source = await _bestLegacySource(target);
    if (source != null) {
      for (final name in boxNames) {
        final src = File(p.join(source.path, '$name.hive'));
        if (await src.exists()) {
          await src.copy(p.join(target.path, '$name.hive'));
        }
      }
    }

    await marker.writeAsString(
      'migrated: ${DateTime.now().toIso8601String()}\n'
      'source: ${source?.path ?? 'none'}\n',
    );
    return target;
  }

  /// Picks the legacy directory holding the most data, or null if none beats
  /// what the target directory already contains.
  ///
  /// "Most data" is measured as the combined byte size of the box files, so an
  /// empty box left behind by a cloud redirect never overwrites a real one.
  static Future<Directory?> _bestLegacySource(Directory target) async {
    final candidates = <Directory>[];

    // Where the old code actually wrote: whatever Windows currently calls
    // Documents. After a OneDrive redirect this is the synced folder.
    try {
      candidates.add(await getApplicationDocumentsDirectory());
    } on Exception {
      // path_provider can fail on unusual shell configurations; skip it.
    }

    // The physical, non-redirected Documents folder, which is where files are
    // left behind when Known Folder Move takes over.
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'];
    if (home != null && home.isNotEmpty) {
      candidates.add(Directory(p.join(home, 'Documents')));
    }

    Directory? best;
    var bestScore = await _score(target);

    for (final dir in candidates) {
      if (p.equals(dir.path, target.path)) continue;
      if (!await dir.exists()) continue;
      final score = await _score(dir);
      if (score > bestScore) {
        bestScore = score;
        best = dir;
      }
    }
    return best;
  }

  /// Total byte size of this app's box files in [dir]. Missing files count zero.
  static Future<int> _score(Directory dir) async {
    var total = 0;
    for (final name in boxNames) {
      final file = File(p.join(dir.path, '$name.hive'));
      if (await file.exists()) {
        total += await file.length();
      }
    }
    return total;
  }
}
