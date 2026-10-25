import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_timers.dart';

void main() {
  test('a countdown reads as m:ss, or h:mm:ss past the hour', () {
    expect(formatCountdown(const Duration(minutes: 5)), '5:00');
    expect(formatCountdown(const Duration(seconds: 59)), '0:59');
    expect(formatCountdown(const Duration(hours: 1, seconds: 5)), '1:00:05');
    // Rounded up: most of a second left is not zero.
    expect(formatCountdown(const Duration(milliseconds: 4100)), '0:05');
    expect(formatCountdown(Duration.zero), '0:00');
    expect(formatCountdown(const Duration(seconds: -3)), '0:00');
  });

  test('starting and clearing a timer moves its end time in and out', () async {
    await startTimer(
      'r/s1',
      length: const Duration(minutes: 2),
      title: 't',
      body: 'b',
    );
    expect(timers.value['r/s1']!.isAfter(DateTime.now()), isTrue);
    await clearTimer('r/s1');
    expect(timers.value, isEmpty);
  });
}
