import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_image.dart';
import 'package:mise/recipe/recipe_store.dart';

/// Waits for a chain to run out, inside a `runAsync` — its requests are real
/// `dart:io` futures that never complete in the fake-async zone (CLAUDE.md).
///
/// Every test that resolves an https url has to do this before it ends, even
/// one whose assertion has already passed: `flutter_cache_manager` takes a lock
/// per request, and one abandoned mid-flight is never released, so the next
/// test to resolve anything waits on it forever. Bounded rather than open, so a
/// chain that stops settling fails here instead of at the file timeout.
Future<void> _drain(ImageChain chain) async {
  for (var i = 0; i < 1000 && !chain.exhausted; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Like [_drain], but for a chain expected to *land* on something rather than
/// run out. Same bound, same reason.
Future<void> pumpUntil(bool Function() done) async {
  for (var i = 0; i < 1000 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A real 1x1 PNG. The chain decodes what it resolves, so a test that needs a
/// fallback to *succeed* has to hand it a real image — and a local file, since
/// no https url resolves here.
const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAC'
    'hwGA60e6kgAAAABJRU5ErkJggg==';

/// Plain `test()`, not `testWidgets`: nothing here builds a widget or touches
/// the network, so none of the fake-async traps apply.
void main() {
  final store = RecipeStore(Directory('/tmp/mise-image-test'));

  group('imageFor', () {
    test('an https url becomes a disk-cached network image', () {
      final image = imageFor('https://example.com/loaf.jpg', store);
      // Cached, not plain: a plain NetworkImage re-downloads on every launch.
      expect(image, isA<CachedNetworkImageProvider>());
      expect(
        (image! as CachedNetworkImageProvider).url,
        'https://example.com/loaf.jpg',
      );
    });

    test('a mise url resolves against the store directory', () {
      final image = imageFor('mise://1724500000000.jpg', store);
      expect(image, isA<FileImage>());
      expect(
        (image! as FileImage).file.path,
        '/tmp/mise-image-test/1724500000000.jpg',
      );
    });

    test('nothing to paint reads as nothing, never as a throw', () {
      expect(imageFor(null, store), isNull);
      expect(imageFor('', store), isNull);
      expect(imageFor('not a url at all', store), isNull);
      expect(imageFor('::::', store), isNull);
    });

    test('http is refused — phones will not load it anyway', () {
      expect(imageFor('http://example.com/loaf.jpg', store), isNull);
      expect(imageFor('ftp://example.com/loaf.jpg', store), isNull);
    });
  });

  group('creditFor', () {
    test('reads the host, so the source is a place and not a link', () {
      expect(
        creditFor('https://seriouseats.com/foo/bar.jpg'),
        'seriouseats.com',
      );
    });

    test('drops a leading www, and only a leading one', () {
      expect(creditFor('https://www.bbcgoodfood.com/a.jpg'), 'bbcgoodfood.com');
      expect(creditFor('https://mywww.example.com/a.jpg'), 'mywww.example.com');
    });

    test('a stock photo names Pexels, not the CDN it sits on', () {
      expect(
        creditFor('https://images.pexels.com/photos/1640777/loaf.jpg'),
        'Pexels',
      );
    });

    test('a picked photo says so rather than showing its filename', () {
      expect(creditFor('mise://1724500000000.jpg'), 'Your photo');
    });

    test('nothing to credit', () {
      expect(creditFor(null), isNull);
      expect(creditFor(''), isNull);
      expect(creditFor('not a url at all'), isNull);
    });
  });

  group('pexelsPhotos', () {
    test('no API key means no photos, not an error', () async {
      // `flutter test` builds without --dart-define, so the key is empty. That
      // is the state this has to survive quietly rather than throw in: a
      // checkout with no key is a working app with plainer pictures.
      expect(await pexelsPhotos('a query with no key behind it'), isEmpty);
    });

    test('a blank query is not worth a request', () async {
      expect(await pexelsPhotos('   '), isEmpty);
    });

    test('the memo is what the chain and the picker share', () async {
      seedPexels('seeded query', const ['https://a.example/1.jpg']);
      // Same list, one lookup: the hero takes the first and the picker shows
      // all of them, off a single request.
      expect(await pexelsPhotos('seeded query'), ['https://a.example/1.jpg']);
    });
  });

  /// The chain resolves real images, so this is a widget-binding test rather
  /// than a plain one — but it still touches no network: every https url fails
  /// in a test environment, which is exactly the condition being tested.
  group('ImageChain', () {
    testWidgets('starts on the first url before anything has failed', (
      tester,
    ) async {
      final chain = ImageChain(
        const ['https://a.example/1.jpg', 'https://b.example/2.jpg'],
        store,
        () {},
      );
      addTearDown(chain.dispose);

      // Optimistic on purpose: a working photo paints on the first frame
      // rather than after a round trip.
      expect(chain.winner, 'https://a.example/1.jpg');
      expect(chain.exhausted, isFalse);
    });

    testWidgets('walks past urls that could never load without a round trip', (
      tester,
    ) async {
      // http and gibberish are rejected by imageFor, so the chain should skip
      // straight to the https entry rather than spending an attempt on them.
      final chain = ImageChain(
        const [
          'http://a.example/1.jpg',
          'not a url',
          'https://c.example/3.jpg',
        ],
        store,
        () {},
      );
      addTearDown(chain.dispose);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        chain.resolve(ImageConfiguration.empty);
        // Before any round trip: http and gibberish were rejected outright.
        expect(chain.winner, 'https://c.example/3.jpg');
        await _drain(chain);
      });
    });

    testWidgets('a title buys one last try, and a miss still settles', (
      tester,
    ) async {
      final chain = ImageChain(
        const ['https://a.example/1.jpg'],
        store,
        () {},
        title: 'A dish with no article',
      );
      addTearDown(chain.dispose);

      await tester.pumpWidget(const SizedBox.shrink());
      // The lookup is a real dart:io future, which never completes inside the
      // fake-async zone (CLAUDE.md). Still no network: the test binding answers
      // every request with a 400, which is exactly the miss being tested.
      await tester.runAsync(() async {
        chain.resolve(ImageConfiguration.empty);
        await _drain(chain);
      });

      // The point of the guard in _finish: a fallback that also fails comes
      // straight back through it, and must settle rather than look itself up
      // again forever.
      expect(chain.exhausted, isTrue);
      expect(chain.winner, isNull);
    });

    testWidgets('a query is tried before the title, and wins', (tester) async {
      // A local file is the only fallback that can actually *load* in a test,
      // so the search returns one. Every https url fails here, which is what
      // makes the miss path free to test and the hit path not.
      Directory(store.dir.path).createSync(recursive: true);
      File('${store.dir.path}/found.png')
        ..createSync()
        ..writeAsBytesSync(base64Decode(_onePixelPng));
      final chain = ImageChain(
        const [],
        store,
        () {},
        title: 'A dish with no article',
        query: 'a photogenic dish',
      );
      addTearDown(chain.dispose);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        // Seeded in here, not above: a Future made in the fake-async zone
        // never delivers inside runAsync, and the chain waits on it forever.
        seedPexels('a photogenic dish', const ['mise://found.png']);
        chain.resolve(ImageConfiguration.empty);
        // Until it has decoded, not until it is named: winner is optimistic,
        // and keeping a photo waits on the real thing.
        await pumpUntil(() => chain.winnerFromSearch || chain.exhausted);
      });

      expect(chain.winner, 'mise://found.png');
      expect(chain.exhausted, isFalse);
      // The half the detail screen keys its auto-save off: this is worth
      // writing down, where a Wikipedia stand-in would not be.
      expect(chain.winnerFromSearch, isTrue);
    });

    testWidgets('a photo the recipe already carries is not a search result', (
      tester,
    ) async {
      File('${store.dir.path}/own.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(base64Decode(_onePixelPng));

      final chain = ImageChain(
        const ['mise://own.png'],
        store,
        () {},
        query: 'never reached',
      );
      addTearDown(chain.dispose);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        chain.resolve(ImageConfiguration.empty);
        await pumpUntil(() => chain.winner != null || chain.exhausted);
      });

      expect(chain.winner, 'mise://own.png');
      // Otherwise the detail screen would rewrite a recipe with the photo it
      // already had, on every visit.
      expect(chain.winnerFromSearch, isFalse);
    });

    testWidgets('a search result that never loads is never worth keeping', (
      tester,
    ) async {
      final chain = ImageChain(const [], store, () {}, query: 'a dead photo');
      addTearDown(chain.dispose);

      await tester.pumpWidget(const SizedBox.shrink());
      var claimedWhileLoading = false;
      await tester.runAsync(() async {
        seedPexels('a dead photo', const ['mise://not-there.png']);
        chain.resolve(ImageConfiguration.empty);
        for (var i = 0; i < 1000 && !chain.exhausted; i++) {
          claimedWhileLoading |= chain.winnerFromSearch;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });

      // Named as the winner for a moment, optimistically, and never once
      // reported as keepable: that would have written a dead link into the
      // recipe for good.
      expect(claimedWhileLoading, isFalse);
      expect(chain.exhausted, isTrue);
    });

    testWidgets('both fallbacks missing still settles', (tester) async {
      final chain = ImageChain(
        const ['https://a.example/1.jpg'],
        store,
        () {},
        title: 'A dish with no article',
        query: 'nothing looks like this',
      );
      addTearDown(chain.dispose);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        seedPexels('nothing looks like this', const []);
        chain.resolve(ImageConfiguration.empty);
        await _drain(chain);
      });

      // The whole argument for a queue rather than a flag per stage: two
      // fallbacks that both miss come back through _finish twice and have to
      // run out, not loop.
      expect(chain.exhausted, isTrue);
      expect(chain.winner, isNull);
    });

    testWidgets('a chain with nothing in it is exhausted immediately', (
      tester,
    ) async {
      var changed = 0;
      final chain = ImageChain(const [], store, () => changed++);
      addTearDown(chain.dispose);

      await tester.pumpWidget(const SizedBox.shrink());
      chain.resolve(ImageConfiguration.empty);

      expect(chain.exhausted, isTrue);
      expect(chain.winner, isNull);
      expect(changed, 1); // and says so exactly once
    });
  });
}
