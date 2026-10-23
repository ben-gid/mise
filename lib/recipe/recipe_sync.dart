import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'recipe_account.dart';
import 'recipe_parser.dart';
import 'recipe_store.dart';
import 'recipe_units.dart';

/// Bumped each time a sync writes anything another phone made — a recipe, a
/// cook, the units — so the screens showing them reload. The same global
/// pattern as [account].
final pulled = ValueNotifier<int>(0);

/// Set by [startSync]; null in a build with accounts off, and in tests.
Future<void> Function()? _run;

/// Syncs now, for pull-to-refresh, finishing when the run does. A run already
/// going is joined rather than doubled. Does nothing where sync never started.
Future<void> syncNow() => _run?.call() ?? Future.value();

/// What one run decided: rows to upload, rows to write to the phone, and the
/// fingerprints to remember as "last synced".
typedef Merge = ({
  Map<String, Object?> push,
  Map<String, Object?> apply,
  Map<String, String> base,
});

/// A row's identity for "has this changed since the last sync". Keys are
/// sorted first because jsonb doesn't keep them in order, and a recipe that
/// came back reordered would otherwise look edited. Null is a deleted row.
String? fingerprint(Object? value) => value == null
    ? null
    : sha1.convert(utf8.encode(jsonEncode(_sorted(value)))).toString();

Object? _sorted(Object? value) => switch (value) {
  Map() => {
    for (final key in [...value.keys.cast<String>()]..sort())
      key: _sorted(value[key]),
  },
  List() => [for (final e in value) _sorted(e)],
  _ => value,
};

/// The three-way compare a run turns on. [base] is each row's fingerprint at
/// the last sync, [local] is [RecipeStore.rows] now, [remote] is every row
/// another phone changed since — null for a deletion.
///
/// Touched only on the other phone: take theirs. Touched here: keep the
/// phone's own and upload it, whatever the other phone did — the files on
/// this phone are the source of truth, and a recipe edit never collides
/// anyway, because it is a new version under a new id. What's left to collide
/// is a photo re-picked in place, a re-imported recipe and the unit settings.
///
/// With no [base] at all — the first sync for this account on this phone —
/// everything local counts as touched, which is the whole library uploading.
Merge merge({
  required Map<String, String> base,
  required Map<String, Object?> local,
  required Map<String, Object?> remote,
}) {
  final push = <String, Object?>{}, apply = <String, Object?>{};
  final next = {...base};
  for (final key in {...base.keys, ...local.keys, ...remote.keys}) {
    final was = base[key];
    final mine = fingerprint(local[key]);
    final theirs = remote.containsKey(key) ? fingerprint(remote[key]) : was;
    final String? now;
    if (mine == was) {
      if (theirs != was) apply[key] = remote[key];
      now = theirs;
    } else {
      if (theirs != mine) push[key] = local[key];
      now = mine;
    }
    if (now == null) {
      next.remove(key);
    } else {
      next[key] = now;
    }
  }
  return (push: push, apply: apply, base: next);
}

/// Starts syncing for as long as the app runs: when a linked account
/// appears, on every resume, after every write, and live whenever another
/// phone changes something (see [_listen]). Never awaited and never
/// blocking — a run that fails logs and waits for the next one.
void startSync(RecipeStore store, RecipeParser parser) {
  if (!accountsOn) return;
  Future<void>? running;
  var again = false;
  Future<void> loop() async {
    do {
      again = false;
      try {
        await _syncOnce(store, parser);
      } catch (e) {
        debugPrint('Sync failed, will retry on the next change: $e');
      }
    } while (again);
  }

  // One at a time; a trigger mid-run buys exactly one more run after it, and
  // waits for that one too.
  _run = () {
    if (running != null) {
      again = true;
      return running!;
    }
    return running = loop().whenComplete(() => running = null);
  };
  RealtimeChannel? live;
  account.addListener(() {
    if (live != null) unawaited(Supabase.instance.client.removeChannel(live!));
    live = _listen();
    unawaited(syncNow());
  });
  AppLifecycleListener(onResume: () => unawaited(syncNow()));
  store.onWrite = () => unawaited(syncNow());
}

/// Live sync: a change to any of this account's rows, from any phone, runs
/// the same sync as every other trigger rather than applying the change
/// itself — so there is one merge, and an event that arrives twice, late or
/// not at all costs nothing that the next run doesn't put right. A burst of
/// them (another phone's first upload) coalesces into a run or two.
///
/// This phone's own uploads come back too, each answered by one run that
/// finds nothing to do. Realtime drops events while the app is in the
/// background or offline; the run on resume is what catches those up.
RealtimeChannel? _listen() {
  final user = account.value;
  if (user == null || user.email == null) return null;
  final channel = Supabase.instance.client.channel('sync:${user.id}');
  for (final table in _tables) {
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: table,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: user.id,
      ),
      callback: (_) => unawaited(syncNow()),
    );
  }
  return channel..subscribe();
}

const _tables = ['recipe_versions', 'cook_entries', 'unit_settings'];

/// PostgREST's own cap on a page.
const _page = 1000;

/// What `addImage` names a photo, so a pulled `mise://` url can't name a file
/// outside the recipes.
final _photoName = RegExp(r'^[\w-]+(\.\w+)?$');

Future<void> _syncOnce(RecipeStore store, RecipeParser parser) async {
  // Linked accounts only: nothing else can ever sign in as an anonymous user,
  // so there is no other phone to sync with. RLS refuses them as well.
  final user = account.value;
  if (user == null || user.email == null) return;
  final db = Supabase.instance.client;

  // A different user — this phone switched accounts — starts from nothing,
  // which merges this phone's library into that account.
  final metaFile = File('${store.dir.path}/sync.meta');
  var meta = <String, dynamic>{};
  try {
    if (metaFile.existsSync()) meta = jsonDecode(await metaFile.readAsString());
  } catch (e) {
    // Forgetting costs one full upload, which every row survives unchanged.
    debugPrint('Starting sync over from an unreadable ${metaFile.path}: $e');
  }
  if (meta['user'] != user.id) meta = {};
  final cursors = Map<String, String>.from(meta['cursors'] ?? const {});
  final base = Map<String, String>.from(meta['base'] ?? const {});
  final uploaded = {...List<String>.from(meta['uploaded'] ?? const [])};

  final remote = <String, Object?>{};
  for (final table in _tables) {
    final rows = await _since(db, table, user.id, cursors[table]);
    for (final row in rows) {
      if (_fromRow(table, row, parser) case (final key, final value)) {
        remote[key] = value;
      }
    }
    if (rows.isNotEmpty) cursors[table] = rows.last['updated_at'] as String;
  }

  final local = await store.rows();
  final merged = merge(base: base, local: local, remote: remote);
  await store.applyRows(merged.apply);
  if (merged.apply.containsKey('units')) {
    applyUnitSystems(merged.apply['units'] as String?);
  }
  if (merged.apply.isNotEmpty) pulled.value++;

  final byTable = <String, List<Map<String, Object?>>>{};
  for (final MapEntry(:key, :value) in merged.push.entries) {
    final (table, row) = _toRow(key, value, user.id);
    (byTable[table] ??= []).add(row);
  }
  for (final MapEntry(key: table, value: rows) in byTable.entries) {
    await db.from(table).upsert(rows);
  }

  await _photos(db, store, user.id, {...local, ...merged.apply}, uploaded);

  await metaFile.writeAsString(
    jsonEncode({
      'user': user.id,
      'cursors': cursors,
      'base': merged.base,
      'uploaded': [...uploaded],
    }),
  );
}

/// Every row of [table] changed since [cursor], oldest first.
///
/// A minute of overlap behind the cursor, because `updated_at` is stamped at
/// write time and a slow transaction can commit behind a row already pulled.
/// Pulling a row twice costs nothing: its fingerprint already matches.
Future<List<Map<String, dynamic>>> _since(
  SupabaseClient db,
  String table,
  String user,
  String? cursor,
) async {
  final rows = <Map<String, dynamic>>[];
  while (true) {
    var query = db.from(table).select().eq('user_id', user);
    if (cursor != null) {
      final from = DateTime.parse(cursor).subtract(const Duration(minutes: 1));
      query = query.gt('updated_at', from.toUtc().toIso8601String());
    }
    final page = await query
        .order('updated_at', ascending: true)
        .range(rows.length, rows.length + _page - 1);
    rows.addAll(page);
    if (page.length < _page) return rows;
  }
}

/// A pulled row as a [RecipeStore.rows] key and value, or null when it
/// won't read. Recipes go through the validator: they come off the network,
/// and nothing on the phone parses one any other way.
(String, Object?)? _fromRow(
  String table,
  Map<String, dynamic> row,
  RecipeParser parser,
) {
  final gone = row['deleted_at'] != null;
  try {
    return switch (table) {
      'recipe_versions' => (
        'v/${row['id']}',
        gone
            ? null
            : {
                'recipe': parser.parse(jsonEncode(row['recipe'])).toJson(),
                'parent': row['parent_id'],
              },
      ),
      // Through the store's own codec, so a date Postgres wrote as
      // `+00:00` fingerprints the same as the phone's `Z`.
      'cook_entries' => (
        'e/${row['version_id']}/${row['id']}',
        gone ? null : encodeEntry(decodeEntry(row)),
      ),
      _ => ('units', gone ? null : row['value']),
    };
  } catch (e) {
    debugPrint('Skipping an unreadable synced row in $table: $e');
    return null;
  }
}

/// A [RecipeStore.rows] key and value as a row to upsert. Null is a
/// deletion, sent as a `deleted_at` so it reaches every phone. Every row of
/// a table carries the same columns, which a bulk upsert needs.
(String, Map<String, Object?>) _toRow(String key, Object? value, String user) {
  final deletedAt = value == null
      ? DateTime.now().toUtc().toIso8601String()
      : null;
  final [kind, ...rest] = key.split('/');
  switch (kind) {
    case 'v':
      final row = value as Map<String, dynamic>?;
      return (
        'recipe_versions',
        {
          'user_id': user,
          'id': rest.join('/'),
          'parent_id': row?['parent'],
          'recipe': row?['recipe'],
          'deleted_at': deletedAt,
        },
      );
    case 'e':
      final entry = value as Map<String, dynamic>?;
      return (
        'cook_entries',
        {
          'user_id': user,
          'version_id': rest.first,
          'id': rest.skip(1).join('/'),
          'date': entry?['date'],
          'servings': entry?['servings'],
          'stars': entry?['stars'],
          'note': entry?['note'],
          'deleted_at': deletedAt,
        },
      );
    default:
      return (
        'unit_settings',
        {'user_id': user, 'value': value, 'deleted_at': deletedAt},
      );
  }
}

/// Uploads each `mise://` photo a recipe uses that the account doesn't have
/// yet, and downloads each one this phone is missing. Checked on every run
/// rather than only alongside its recipe, so a download that failed offline
/// is retried by the next run. Nothing is ever deleted, the same as on the
/// phone.
Future<void> _photos(
  SupabaseClient db,
  RecipeStore store,
  String user,
  Map<String, Object?> rows,
  Set<String> uploaded,
) async {
  final bucket = db.storage.from('photos');
  final names = {
    for (final MapEntry(:key, :value) in rows.entries)
      if (key.startsWith('v/') && value is Map)
        for (final url
            in (value['recipe']['image_urls'] as List).cast<String>())
          if (url.startsWith('mise://')) url.substring('mise://'.length),
  };
  for (final name in names) {
    if (!_photoName.hasMatch(name)) continue;
    final file = store.imageFile(name);
    try {
      if (!file.existsSync()) {
        await file.writeAsBytes(await bucket.download('$user/$name'));
        uploaded.add(name);
      } else if (!uploaded.contains(name)) {
        await bucket.upload(
          '$user/$name',
          file,
          fileOptions: const FileOptions(upsert: true),
        );
        uploaded.add(name);
      }
    } catch (e) {
      // The other phone may not have uploaded it yet.
      debugPrint('Photo $name not synced, will retry: $e');
    }
  }
}
