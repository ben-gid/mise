import 'package:flutter/widgets.dart';

import 'recipe_store.dart';

/// The one place a recipe's `image_url` becomes something paintable, and the
/// one place it becomes a line of credit.
///
/// Both take the url as a plain string rather than a `Recipe` so the editor can
/// call them on live controller text, before anything has been saved or
/// validated. A second copy of the scheme check would drift the credit away
/// from the picture it names — the same reason `amountLabel` is the only place
/// an amount is formatted.

/// How a photo picked from the device is addressed: the filename follows,
/// resolved against the store's directory rather than baked into the recipe as
/// an absolute path. See [RecipeStore.addImage] for why it can't be absolute.
const _localScheme = 'mise://';

/// Something to paint, or null when the recipe has no usable image.
///
/// Never throws on a bad url. A hallucinated link is the expected failure for
/// an LLM-supplied field, and it should read as "no picture" rather than as a
/// crash. A url that parses but 404s fails later, in the widget's
/// `errorBuilder`, which is where the fallback art lives.
ImageProvider? imageFor(String? url, RecipeStore store) {
  if (url == null || url.isEmpty) return null;
  if (url.startsWith(_localScheme)) {
    // Substring rather than Uri.host: Uri lowercases a host, and what follows
    // the scheme here is a filename, not one.
    return FileImage(store.imageFile(url.substring(_localScheme.length)));
  }
  // The schema enforces https too, but this is also called on unvalidated
  // editor text — a url phones would refuse to load should preview as nothing
  // rather than as a picture that only fails on the device.
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.isScheme('https')) return null;
  return NetworkImage(url);
}

/// Where the picture came from, for the credit line under it — a host, not the
/// whole url. The reader is asking whether they are looking at the dish or at a
/// stock photo, and `seriouseats.com` answers that where a 120-character link
/// does not.
String? creditFor(String? url) {
  if (url == null || url.isEmpty) return null;
  if (url.startsWith(_localScheme)) return 'Your photo';
  final host = Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return null;
  // Guarded rather than replaceFirst, which would eat the 'www.' out of the
  // middle of a host like 'mywww.example.com'.
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// Walks a recipe's urls and settles on the first that actually loads.
///
/// A guessed url is often dead, so a recipe carries several and the later ones
/// are fallbacks. This resolves them through the image cache **without
/// painting**, which is the whole point: the detail screen sizes its app bar on
/// the outcome, and a widget that rendered the chain and reported upwards would
/// loop — child says exhausted, parent shrinks, child rebuilds, reports again.
///
/// Own one from a `State`: [resolve] from `didChangeDependencies`, [dispose]
/// from `dispose`. Then paint whatever `imageFor(chain.winner, store)` gives.
class ImageChain {
  final List<String> urls;
  final RecipeStore store;

  /// Fired when [winner] changes, including when the last url fails and the
  /// chain is left [exhausted]. Callers `setState` from here.
  final VoidCallback onChanged;

  ImageChain(this.urls, this.store, this.onChanged);

  int _index = 0;
  bool _settled = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// The url on screen, or null while nothing has resolved and once every url
  /// has failed. Check [exhausted] to tell those two apart.
  String? get winner => _settled || _index >= urls.length ? null : urls[_index];

  /// Every url failed, or there were none to begin with. A recipe in this state
  /// reads as a recipe with no photo.
  bool get exhausted => _settled;

  void resolve(ImageConfiguration config) {
    _detach();
    if (_index >= urls.length) {
      _finish();
      return;
    }
    final provider = imageFor(urls[_index], store);
    if (provider == null) {
      // Unparseable or http — skip it without spending a network attempt.
      _advance(config);
      return;
    }
    _stream = provider.resolve(config);
    _listener = ImageStreamListener(
      (_, _) {},
      onError: (_, _) => _advance(config),
    );
    _stream!.addListener(_listener!);
  }

  /// Note the guard: `onError` can fire *synchronously* from `resolve` for a
  /// url the cache already knows is dead, so this recurses rather than looping,
  /// and only calls back once it has actually moved.
  void _advance(ImageConfiguration config) {
    _detach();
    _index++;
    if (_index >= urls.length) {
      _finish();
      return;
    }
    onChanged();
    resolve(config);
  }

  void _finish() {
    if (_settled) return;
    _settled = true;
    onChanged();
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  void dispose() => _detach();
}
