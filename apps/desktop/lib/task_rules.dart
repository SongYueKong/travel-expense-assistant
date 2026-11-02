import 'dart:convert';
import 'dart:math';

typedef TripTask = Map<String, dynamic>;

String validateTaskName(String value) {
  final name = value.trim();
  if (name.isEmpty) throw const FormatException('任务名称不能为空');
  if (name.runes.any((c) => c < 32 || c == 127)) {
    throw const FormatException('任务名称不能包含换行或控制字符');
  }
  return name;
}

void requireAvailableTaskName(String name, Iterable<TripTask> tasks,
    {String? exceptId}) {
  if (tasks.any((t) =>
      t['id'] != exceptId &&
      t['name'].toString().trim().toLowerCase() == name.toLowerCase())) {
    throw const FormatException('已有同名差旅，请使用其他名称');
  }
}

String newTaskId() {
  final random = Random.secure();
  return List.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String suggestDuplicateName(String source, Iterable<TripTask> tasks) {
  final used =
      tasks.map((t) => t['name'].toString().trim().toLowerCase()).toSet();
  var name = '${source.trim()}（副本）', index = 2;
  while (used.contains(name.toLowerCase())) {
    name = '${source.trim()}（副本 ${index++}）';
  }
  return name;
}

TripTask duplicateTask(TripTask source, String name) {
  final result = jsonDecode(jsonEncode(source)) as TripTask;
  result['id'] = newTaskId();
  result['name'] = validateTaskName(name);
  result['createdAt'] = DateTime.now().toIso8601String();
  result['copiedFromTaskId'] = source['id'];
  for (final group in (result['groups'] as List? ?? [])) {
    group['confirmed'] = false;
    group['complete'] = false;
  }
  return result;
}
