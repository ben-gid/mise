import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_image.dart';
import 'package:mise/recipe/recipe_store.dart';

/// Plain `test()`, not `testWidgets`: nothing here builds a widget or touches
/// the network, so none of the fake-async traps apply.
void main() {
  final store = RecipeStore(Directory('/tmp/mise-image-test'));

  group('imageFor', () {
    test('an https url becomes a network image', () {
      final image = imageFor('https://example.com/loaf.jpg', store);
      expect(image, isA<NetworkImage>());
      expect((image! as NetworkImage).url, 'https://example.com/loaf.jpg');
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

    test('a picked photo says so rather than showing its filename', () {
      expect(creditFor('mise://1724500000000.jpg'), 'Your photo');
    });

    test('nothing to credit', () {
      expect(creditFor(null), isNull);
      expect(creditFor(''), isNull);
      expect(creditFor('not a url at all'), isNull);
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
      chain.resolve(ImageConfiguration.empty);

      expect(chain.winner, 'https://c.example/3.jpg');
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
