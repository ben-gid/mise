import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Run by `flutter test` before every file in this directory, which is why no
/// individual test has to opt in.
///
/// `CachedNetworkImageProvider` resolves through `flutter_cache_manager`, which
/// asks `path_provider` where to put its cache. Under `flutter test` there is no
/// plugin behind that channel, and the resulting `MissingPluginException` never
/// reaches the `ImageStreamListener` — the stream simply never completes, so
/// `ImageChain` hangs instead of walking to its next url and every test about a
/// dead photo times out. A temp dir is all it wants.
///
/// On macOS (and the phones) it also keeps its index in sqflite, where Linux
/// uses a JSON file — so a missing sqflite plugin hangs the chain the same way,
/// on this platform only. The FFI factory is a real sqlite with no plugin.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Not deleted afterwards: this returns once the tests are *declared*, long
  // before they have run. It is under systemTemp, which the OS sweeps.
  final cache = Directory.systemTemp.createTempSync('mise-image-cache');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => cache.path,
      );
  databaseFactory = databaseFactoryFfi..setDatabasesPath(cache.path);
  await testMain();
}
