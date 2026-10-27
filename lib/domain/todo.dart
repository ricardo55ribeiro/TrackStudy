class TodoTopic {
  final String id, title, createdAt, updatedAt;
  final int position;
  const TodoTopic({
    required this.id,
    required this.title,
    required this.position,
    required this.createdAt,
    required this.updatedAt,
  });
  factory TodoTopic.fromMap(Map<String, Object?> row) => TodoTopic(
    id: row['id'] as String,
    title: row['title'] as String,
    position: row['position'] as int,
    createdAt: row['created_at'] as String,
    updatedAt: row['updated_at'] as String,
  );
}

class TodoTask {
  final String id, topicId, text, createdAt, updatedAt;
  final int position;
  final String? completedAt;
  bool get completed => completedAt != null;
  const TodoTask({
    required this.id,
    required this.topicId,
    required this.text,
    required this.position,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
  });
  factory TodoTask.fromMap(Map<String, Object?> row) => TodoTask(
    id: row['id'] as String,
    topicId: row['topic_id'] as String,
    text: row['text'] as String,
    position: row['position'] as int,
    createdAt: row['created_at'] as String,
    updatedAt: row['updated_at'] as String,
    completedAt: row['completed_at'] as String?,
  );
}

String todoText(String value) {
  final text = value.trim();
  if (text.isEmpty) throw const FormatException('Enter a name before saving.');
  return text;
}
