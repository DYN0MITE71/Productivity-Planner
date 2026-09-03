import 'package:hive_flutter/hive_flutter.dart';
import '../models/queue_model.dart';
import '../models/task_model.dart';
import 'storage_migration.dart';

/// Singleton helper for working with the local Hive database.
///
/// This class owns the app's queue, task, and settings boxes and provides
/// methods for reading, writing, deleting, exporting, and importing data.
class DatabaseHelper {
  /// Single shared instance of the database helper.
  static final DatabaseHelper _instance = DatabaseHelper._internal();

  /// Private constructor used by the singleton pattern.
  DatabaseHelper._internal();

  /// Returns the shared database helper instance.
  factory DatabaseHelper() => _instance;

  /// Hive box name for queue records.
  static const String _queueBox = 'queues';

  /// Hive box name for task records.
  static const String _taskBox = 'tasks';

  /// Hive box name for app settings.
  static const String _settingsBox = 'settings';

  /// Initializes Hive, registers model adapters, and opens all app boxes.
  ///
  /// Boxes are stored in the application support directory rather than the
  /// Documents folder. Documents is redirected by cloud-sync tools such as
  /// OneDrive Known Folder Move, and a redirect leaves the app reading an empty
  /// directory. See [StorageMigration], which also copies data across from the
  /// old location on first launch.
  Future<void> init() async {
    final dir = await StorageMigration.resolve();
    Hive.init(dir.path);
    Hive.registerAdapter(QueueAdapter());
    Hive.registerAdapter(TaskAdapter());
    await Hive.openBox<Queue>(_queueBox);
    await Hive.openBox<Task>(_taskBox);
    await Hive.openBox(_settingsBox);
  }

  /// Queue storage box.
  Box<Queue> get _queues => Hive.box<Queue>(_queueBox);

  /// Task storage box.
  Box<Task> get _tasks => Hive.box<Task>(_taskBox);

  /// Settings storage box.
  Box get _settings => Hive.box(_settingsBox);

  // Settings operations (simple key/value).

  /// Gets a saved setting by key.
  ///
  /// If the setting does not exist, [defaultValue] is returned instead.
  dynamic getSetting(String key, {dynamic defaultValue}) =>
      _settings.get(key, defaultValue: defaultValue);

  /// Saves a setting value by key.
  Future<void> setSetting(String key, dynamic value) async {
    await _settings.put(key, value);
  }

  // Queue operations

  /// Inserts a new queue into the database.
  ///
  /// The generated Hive key is stored back on the queue as its id.
  Future<int> insertQueue(Queue queue) async {
    final id = await _queues.add(queue);
    queue.id = id;
    await queue.save();
    return id;
  }

  /// Gets all queues from the database.
  ///
  /// Archived queues are excluded unless [includeArchived] is true. Queues are
  /// returned in their saved sort order.
  List<Queue> getQueues({bool includeArchived = false}) {
    final list = _queues.values
        .where((q) => includeArchived || !q.isArchived)
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  /// Saves changes to an existing queue.
  Future<void> updateQueue(Queue queue) async {
    await queue.save();
  }

  /// Deletes a queue and all tasks that belong to it.
  Future<void> deleteQueue(int hiveKey) async {
    final tasksToDelete = _tasks.values
        .where((t) => t.queueId == hiveKey)
        .toList();
    for (final task in tasksToDelete) {
      await task.delete();
    }
    await _queues.delete(hiveKey);
  }

  // Task operations

  /// Inserts a new task into the database.
  ///
  /// The generated Hive key is stored back on the task as its id.
  Future<int> insertTask(Task task) async {
    final id = await _tasks.add(task);
    task.id = id;
    await task.save();
    return id;
  }

  /// Gets all tasks belonging to a specific queue.
  ///
  /// Archived tasks are excluded unless [includeArchived] is true.
  List<Task> getTasksForQueue(int queueId, {bool includeArchived = false}) {
    return _tasks.values
        .where((t) =>
            t.queueId == queueId && (includeArchived || !t.isArchived))
        .toList();
  }

  /// Gets all tasks across every queue.
  ///
  /// Archived tasks are excluded unless [includeArchived] is true.
  List<Task> getAllTasks({bool includeArchived = false}) {
    return _tasks.values
        .where((t) => includeArchived || !t.isArchived)
        .toList();
  }

  /// Saves changes to an existing task.
  Future<void> updateTask(Task task) async {
    await task.save();
  }

  /// Deletes a task by its Hive key.
  Future<void> deleteTask(int hiveKey) async {
    await _tasks.delete(hiveKey);
  }

  // Wipe everything: all queues, all tasks, and all settings. Used by the
  // "Reset all data" option. Irreversible.

  /// Permanently deletes all queues, tasks, and settings.
  Future<void> resetAllData() async {
    await _queues.clear();
    await _tasks.clear();
    await _settings.clear();
  }

  // Permanently delete everything that's been archived: archived tasks, plus
  // archived queues and ALL of their tasks (archived or not). Returns the
  // number of items removed (queues + tasks) so the UI can report it.

  /// Permanently deletes archived queues and archived tasks.
  ///
  /// If a queue is archived, all of its tasks are also deleted. Returns the
  /// total number of deleted queues and tasks.
  Future<int> deleteArchived() async {
    var removed = 0;

    // Archived queues: delete the queue and every task belonging to it.
    final archivedQueueKeys = _queues.toMap().entries
        .where((e) => e.value.isArchived)
        .map((e) => e.key)
        .toList();
    final archivedQueueIds =
        archivedQueueKeys.map((k) => k as int).toSet();

    for (final task in _tasks.values.toList()) {
      // Remove if the task itself is archived, or it belongs to an archived
      // queue that's about to be deleted.
      if (task.isArchived || archivedQueueIds.contains(task.queueId)) {
        await task.delete();
        removed++;
      }
    }
    for (final key in archivedQueueKeys) {
      await _queues.delete(key);
      removed++;
    }
    return removed;
  }

  // ---- Backup / restore ----------------------------------------------------

  // Serialize every queue and task into a plain map (JSON-encodable). Queues
  // are keyed by their current Hive key so tasks can be re-linked on import.

  /// Converts all queue and task data into a JSON-safe map.
  ///
  /// Queue keys are included so tasks can be matched back to their queues during
  /// import.
  Map<String, dynamic> exportData() {
    final queueList = _queues.toMap().entries.map((e) {
      final q = e.value;
      return {
        'key': e.key,
        'name': q.name,
        'isArchived': q.isArchived,
        'isComplete': q.isComplete,
        'orderModeIndex': q.orderModeIndex,
        'description': q.description,
        'sortOrder': q.sortOrder,
        'hiddenFromHome': q.hiddenFromHome,
      };
    }).toList();

    final taskList = _tasks.values.map((t) {
      return {
        'queueKey': t.queueId,
        'title': t.title,
        'dueDate': t.dueDate,
        'isComplete': t.isComplete,
        'isArchived': t.isArchived,
        'preferredOrder': t.preferredOrder,
        'description': t.description,
        'homeOrder': t.homeOrder,
        'completedAt': t.completedAt,
        'isFiled': t.isFiled,
      };
    }).toList();

    return {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'queues': queueList,
      'tasks': taskList,
    };
  }

  // Replace all current data with the contents of a previously-exported map.
  // Old queue keys are remapped to the new keys so tasks stay linked.

  /// Replaces current queue and task data with imported backup data.
  ///
  /// Old queue keys from the backup are remapped to new Hive keys so imported
  /// tasks stay connected to the correct imported queues.
  Future<void> importData(Map<String, dynamic> data) async {
    await _queues.clear();
    await _tasks.clear();

    final keyRemap = <int, int>{};

    final queues = (data['queues'] as List?) ?? [];
    for (final raw in queues) {
      final q = raw as Map;
      final oldKey = q['key'] as int;
      final queue = Queue(
        name: q['name'] as String,
        isArchived: (q['isArchived'] as bool?) ?? false,
        isComplete: (q['isComplete'] as bool?) ?? false,
        orderModeIndex: (q['orderModeIndex'] as int?) ?? 0,
        description: q['description'] as String?,
        sortOrder: (q['sortOrder'] as int?) ?? 0,
        hiddenFromHome: (q['hiddenFromHome'] as bool?) ?? false,
      );
      final newKey = await _queues.add(queue);
      queue.id = newKey;
      await queue.save();
      keyRemap[oldKey] = newKey;
    }

    final tasks = (data['tasks'] as List?) ?? [];
    for (final raw in tasks) {
      final t = raw as Map;
      final oldQueueKey = t['queueKey'] as int;
      final newQueueKey = keyRemap[oldQueueKey];
      if (newQueueKey == null) continue; // orphaned task; skip
      final task = Task(
        queueId: newQueueKey,
        title: t['title'] as String,
        dueDate: t['dueDate'] as String?,
        isComplete: (t['isComplete'] as bool?) ?? false,
        isArchived: (t['isArchived'] as bool?) ?? false,
        preferredOrder: (t['preferredOrder'] as int?) ?? 0,
        description: t['description'] as String?,
        homeOrder: (t['homeOrder'] as int?) ?? -1,
        completedAt: (t['completedAt'] as int?) ?? 0,
        isFiled: (t['isFiled'] as bool?) ?? false,
      );
      final newKey = await _tasks.add(task);
      task.id = newKey;
      await task.save();
    }
  }
}