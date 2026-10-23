import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_sync.dart';

void main() {
  const a = {'title': 'Focaccia', 'serves': 8};
  const b = {'title': 'Focaccia', 'serves': 12};
  final synced = {'v/1': fingerprint(a)!};

  test('the first sync uploads the whole library', () {
    final m = merge(base: {}, local: {'v/1': a, 'units': 'metric'}, remote: {});

    expect(m.push, {'v/1': a, 'units': 'metric'});
    expect(m.apply, isEmpty);
    expect(m.base.keys, {'v/1', 'units'});
  });

  test("another phone's edit lands here", () {
    final m = merge(base: synced, local: {'v/1': a}, remote: {'v/1': b});

    expect(m.apply, {'v/1': b});
    expect(m.push, isEmpty);
    expect(m.base['v/1'], fingerprint(b));
  });

  test("a new recipe from another phone lands here", () {
    final m = merge(base: {}, local: {}, remote: {'v/2': b});

    expect(m.apply, {'v/2': b});
  });

  test('an edit here uploads', () {
    final m = merge(base: synced, local: {'v/1': b}, remote: {});

    expect(m.push, {'v/1': b});
    expect(m.apply, isEmpty);
  });

  test('when both phones changed it, this phone wins', () {
    const c = {'title': 'Focaccia', 'serves': 4};
    final m = merge(base: synced, local: {'v/1': b}, remote: {'v/1': c});

    expect(m.push, {'v/1': b});
    expect(m.apply, isEmpty);
    expect(m.base['v/1'], fingerprint(b));
  });

  test("another phone's delete deletes here", () {
    final m = merge(base: synced, local: {'v/1': a}, remote: {'v/1': null});

    expect(m.apply, {'v/1': null});
    expect(m.base, isEmpty);
  });

  test('a delete here uploads a tombstone', () {
    final m = merge(base: synced, local: {}, remote: {});

    expect(m.push, {'v/1': null});
    expect(m.base, isEmpty);
  });

  test('Undo after a synced delete brings it back everywhere', () {
    final deleted = merge(base: synced, local: {}, remote: {});
    // The tombstone comes back on the next pull, while the file is back.
    final undone = merge(
      base: deleted.base,
      local: {'v/1': a},
      remote: {'v/1': null},
    );

    expect(undone.push, {'v/1': a});
    expect(undone.apply, isEmpty);
  });

  test('a row coming back reordered by jsonb is not an edit', () {
    final m = merge(
      base: synced,
      local: {'v/1': a},
      remote: {
        'v/1': {'serves': 8, 'title': 'Focaccia'},
      },
    );

    expect(m.push, isEmpty);
    expect(m.apply, isEmpty);
  });

  test('a tombstone for something this phone never had does nothing', () {
    final m = merge(base: {}, local: {}, remote: {'v/9': null});

    expect(m.push, isEmpty);
    expect(m.apply, isEmpty);
    expect(m.base, isEmpty);
  });
}
