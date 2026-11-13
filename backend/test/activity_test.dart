import 'package:cineseed_backend/src/database.dart';
import 'package:test/test.dart';

void main() {
  test('activity is logged once per person, action and film per 6 h', () {
    final db = CineseedDb.memory();
    final t = DateTime.utc(2026, 11, 13, 20);
    bool log(String who, String action, DateTime at) => db.logActivity(
      who: who,
      ip: '1.2.3.4',
      action: action,
      hash: 'abc',
      title: 'Film.mkv',
      at: at,
    );
    expect(log('Alice', 'watched', t), isTrue);
    expect(log('Alice', 'watched', t.add(const Duration(hours: 1))), isFalse);
    expect(log('Alice', 'downloaded', t), isTrue);
    expect(log('Bob', 'watched', t), isTrue);
    expect(log('Alice', 'watched', t.add(const Duration(hours: 7))), isTrue);
    expect(db.activity().map((r) => '${r['who']} ${r['action']}'), [
      'Alice watched',
      'Alice watched',
      'Alice downloaded',
      'Bob watched',
    ]);
  });
}
