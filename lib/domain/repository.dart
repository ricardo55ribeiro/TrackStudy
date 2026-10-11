import 'models.dart';
import 'week.dart';
import 'planning.dart';

abstract interface class StudyRepository {
  String get location;
  List<Category> categories();
  List<WeeklyProgress> loadWeek(Week week, {required Week current});
  void saveCategory(String? id, GoalConfig config, Week current);
  void setCategoryStatus(
    String id, {
    required bool active,
    required bool archived,
  });
  void reorder(List<String> ids);
  void commit(String goalId, int amount, Week current);
  void undo(String goalId, Week current);
  List<LedgerEntry> entries(String goalId);
  void setUndone(String entryId, bool undone, Week current);
  List<JournalEntry> journal(String search);
  void saveJournal(JournalEntry entry);
  void answerJournal(String id, String? answer, {required String question});
  WeeklyReview review(Week week);
  void saveReview(WeeklyReview review);
  List<ScheduleBlock> schedule(int weekday);
  void saveSchedule(ScheduleBlock block);
  void deleteSchedule(String id);
  List<AcademicEvent> academicEvents(DateTime month);
  void saveAcademicEvent(AcademicEvent event);
  void deleteAcademicEvent(String id);
  String preference(String key, String fallback);
  void setPreference(String key, String value);
  String exportJson();
  void restoreJson(String data);
  void close();
}
