import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

/// Step timers: when each running one ends, keyed by [timerKey].
///
/// The end time, not the time left. A phone locks, the app is suspended, and
/// a countdown that ticked in memory would come back wrong; one read off the
/// wall clock is right whenever it is looked at. The same global-notifier
/// pattern as `themeMode` and the unit settings: the detail screen listens,
/// nothing in between needs to know.
// ponytail: in memory only. If the process dies the notification still fires,
// but the step shows Start again. Persist to a .meta sidecar if that bites.
final timers = ValueNotifier<Map<String, DateTime>>(const {});

/// One step of one version. An edit mid-cook mints a new version id, so the
/// running timer stays with the version it was started on.
String timerKey(String recipeId, String stepId) => '$recipeId/$stepId';

/// Ends [key]'s countdown [length] from now, and asks the phone to say so
/// when it does — the app is rarely open on the counter two hours later.
Future<void> startTimer(
  String key, {
  required Duration length,
  required String title,
  required String body,
}) async {
  final end = DateTime.now().add(length);
  timers.value = {...timers.value, key: end};
  await _notify(key, end, title: title, body: body);
}

/// Stops [key]'s countdown, or clears it once it has finished.
Future<void> clearTimer(String key) async {
  timers.value = {...timers.value}..remove(key);
  await _plugin?.cancel(id: _id(key));
}

/// "4:59", "1:59:32". Rounded up, so a timer never reads 0:00 while it still
/// has most of a second to go.
String formatCountdown(Duration left) {
  final total = (left.inMilliseconds / 1000).ceil().clamp(0, 1 << 31);
  final h = total ~/ 3600;
  final m = total % 3600 ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// A stable notification id per key. Code units rather than [String.hashCode],
/// which is not specified stable across SDK versions.
int _id(String key) =>
    key.codeUnits.fold(17, (sum, unit) => (sum * 31 + unit) & 0x7fffffff);

/// The plugin, on a phone only. The desktop harness and `flutter test` have no
/// implementation behind its channel, and a timer there just counts down on
/// screen — the same rule an empty `PHOTO_PROXY` follows.
final FlutterLocalNotificationsPlugin? _plugin =
    !kIsWeb && (Platform.isAndroid || Platform.isIOS)
    ? FlutterLocalNotificationsPlugin()
    : null;

/// Initialised on the first timer, not at launch: the permission prompt
/// arrives when the cook has just asked for something that needs it, rather
/// than on first open with no reason given.
Future<bool>? _ready;

Future<bool> _setUp(FlutterLocalNotificationsPlugin plugin) async {
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_launcher_monochrome'),
      iOS: DarwinInitializationSettings(
        // Asked below, once a timer is actually started.
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
      ),
    ),
  );
  final android = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  final ios = plugin
      .resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin
      >();
  final granted =
      await android?.requestNotificationsPermission() ??
      await ios?.requestPermissions(alert: true, sound: true) ??
      false;
  return granted;
}

Future<void> _notify(
  String key,
  DateTime end, {
  required String title,
  required String body,
}) async {
  final plugin = _plugin;
  if (plugin == null) return;
  // A refused permission isn't an error: the timer still runs on screen.
  if (!await (_ready ??= _setUp(plugin))) return;
  final android = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  // Exact when the phone allows it. Android 14 denies exact alarms to new
  // installs by default, and an inexact one can land a few minutes late —
  // still better than none, and the countdown on screen stays exact.
  final exact = await android?.canScheduleExactNotifications() ?? true;
  await plugin.zonedSchedule(
    id: _id(key),
    // UTC on both ends: an instant, so no zone database or local zone needed.
    scheduledDate: tz.TZDateTime.from(end.toUtc(), tz.UTC),
    title: title,
    body: body,
    androidScheduleMode: exact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'timers',
        'Step timers',
        channelDescription: 'When a timed step in a recipe is done',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentSound: true,
      ),
    ),
  );
}
