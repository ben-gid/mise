import 'dart:convert';
import 'dart:io';

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
  // upload.wikimedia.org is where a Commons file actually lives and is not
  // what anyone calls it. Naming Wikipedia also says the quiet part out loud:
  // this is a photo of the dish, not a photo of this recipe.
  if (host.endsWith('wikimedia.org')) return 'Wikipedia';
  // Guarded rather than replaceFirst, which would eat the 'www.' out of the
  // middle of a host like 'mywww.example.com'.
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// A photo of the *dish*, for when a recipe's own urls have all failed.
///
/// The url is fetched, never remembered, and that is the whole point. A model
/// reconstructs the *shape* of a blog's CDN path perfectly and its bytes never,
/// so three guessed urls are one guess sampled three times — they 404 together
/// rather than covering for each other. A page title is the one thing about a
/// picture a model does reliably know.
///
/// Misses cleanly: "Grandma's leftover casserole" has no article, and no photo
/// is the honest answer there. Offline, a 403, malformed JSON — every failure
/// reads as null, because none of them should take a recipe screen down.
Future<String?> wikipediaImage(String title) =>
    _wikipedia.putIfAbsent(title, () => _fetchWikipediaImage(title));

/// Keyed by title rather than by recipe, and only for this run: two recipes for
/// the same dish share one lookup, and a rename correctly misses.
final _wikipedia = <String, Future<String?>>{};

Future<String?> _fetchWikipediaImage(String title) async {
  // formatversion 2 hands `pages` back as a list; version 1 keys it by page id
  // and would need a `.values.first` dance for a single title. `redirects`
  // follows "Carbonara" to whatever the article is actually filed under.
  final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
    'action': 'query',
    'format': 'json',
    'formatversion': '2',
    'redirects': '1',
    'prop': 'pageimages',
    'piprop': 'thumbnail',
    // Wide enough for a hero on a 3x phone. The original is uncapped and is
    // routinely tens of megabytes.
    'pithumbsize': '1000',
    'titles': title,
  });
  final client = HttpClient();
  try {
    // Wikimedia throttles or blocks anonymous user agents, and a 403 here would
    // look exactly like the dead links this exists to replace.
    client.userAgent = 'mise-recipes/1.0 (Flutter recipe app)';
    final response = await client.getUrl(uri).then((r) => r.close());
    if (response.statusCode != HttpStatus.ok) return null;
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    final pages = (body['query'] as Map?)?['pages'] as List?;
    if (pages == null || pages.isEmpty) return null;
    final source = (pages.first as Map)['thumbnail']?['source'];
    return source is String ? source : null;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
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
  final RecipeStore store;

  /// Fired when [winner] changes, including when the last url fails and the
  /// chain is left [exhausted]. Callers `setState` from here.
  final VoidCallback onChanged;

  /// The dish, for one last try at [wikipediaImage] once the recipe's own urls
  /// are spent — or null to skip it. The editor's preview passes null: "does
  /// the url I typed work" is a question a stand-in photo answers wrongly.
  final String? title;

  /// The recipe's urls, plus the Wikipedia fallback once it resolves. Copied
  /// rather than held: this list grows, and the caller's is the model's.
  final List<String> _urls;

  ImageChain(List<String> urls, this.store, this.onChanged, {this.title})
    : _urls = List.of(urls);

  int _index = 0;
  bool _settled = false;
  bool _disposed = false;
  bool _triedWikipedia = false;
  ImageConfiguration _config = ImageConfiguration.empty;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// The url on screen, or null while nothing has resolved and once every url
  /// has failed. Check [exhausted] to tell those two apart.
  String? get winner =>
      _settled || _index >= _urls.length ? null : _urls[_index];

  /// Every url failed, or there were none to begin with. A recipe in this state
  /// reads as a recipe with no photo.
  bool get exhausted => _settled;

  void resolve(ImageConfiguration config) {
    // Kept so the Wikipedia fallback, which arrives a round trip later, can
    // resolve against the same configuration the recipe's own urls used.
    _config = config;
    _detach();
    if (_index >= _urls.length) {
      _finish();
      return;
    }
    final provider = imageFor(_urls[_index], store);
    if (provider == null) {
      // Unparseable or http — skip it without spending a network attempt.
      _advance();
      return;
    }
    _stream = provider.resolve(config);
    _listener = ImageStreamListener((_, _) {}, onError: (_, _) => _advance());
    _stream!.addListener(_listener!);
  }

  /// Note the guard: `onError` can fire *synchronously* from `resolve` for a
  /// url the cache already knows is dead, so this recurses rather than looping,
  /// and only calls back once it has actually moved.
  void _advance() {
    _detach();
    _index++;
    if (_index >= _urls.length) {
      _finish();
      return;
    }
    onChanged();
    resolve(_config);
  }

  /// The recipe's own urls are spent. Before settling, one last try at a photo
  /// of the dish itself — [_triedWikipedia] because a fallback that also fails
  /// comes straight back through here.
  ///
  /// While the lookup is in flight the chain is neither settled nor pointing at
  /// a url, which is the same "still loading" state as a network image that
  /// hasn't arrived. The hero stays open rather than closing and reopening.
  void _finish() {
    if (_settled) return;
    if (title == null || _triedWikipedia) {
      _settled = true;
      onChanged();
      return;
    }
    _triedWikipedia = true;
    wikipediaImage(title!).then((url) {
      if (_disposed) return;
      if (url != null) {
        _urls.add(url);
        // A url that loads fires no callback of its own — the listener only
        // reports failures — so nothing else would repaint the hero.
        onChanged();
      }
      resolve(_config);
    });
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  void dispose() {
    _disposed = true;
    _detach();
  }
}
