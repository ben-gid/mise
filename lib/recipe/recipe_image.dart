import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
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

/// Read at compile time: `flutter run --dart-define-from-file=env.json`.
///
/// Empty is a supported state, not a broken one. A checkout with no key — and
/// every run of `flutter test` — simply skips the stock photo link of the chain
/// and falls through to Wikipedia, which is what keeps the suite offline.
const _pexelsKey = String.fromEnvironment('PEXELS_KEY');

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
  // Cached rather than plain NetworkImage: `dart:io`'s HttpClient has no HTTP
  // cache at all — it ignores Cache-Control and ETag — and Flutter's ImageCache
  // dies with the process, so every cold start re-downloaded every photo. A
  // recipe is read at a counter on whatever signal a kitchen has.
  return CachedNetworkImageProvider(url);
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
  // images.pexels.com is where the file lives and is not what anyone calls it.
  // Naming Pexels is also the price of the photos — their terms ask for it —
  // and it says the quiet part out loud the same way Wikipedia does: this is a
  // photograph of something that looks like the dish, not of this recipe.
  if (host.endsWith('pexels.com')) return 'Pexels';
  // Guarded rather than replaceFirst, which would eat the 'www.' out of the
  // middle of a host like 'mywww.example.com'.
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// Stock photographs of what the dish looks like, best first.
///
/// Keyed on the recipe's own `image_query` rather than its title, because a
/// title is a name — "Nonna's Sunday gravy" — and a photo library is indexed by
/// what is in the frame. That is the whole trade this makes: the picture is
/// beautiful and is of *something that looks like* the dish, where
/// [wikipediaImage] is plain and is of the dish itself. [creditFor] says
/// "Pexels" so a reader can tell which they are looking at.
///
/// Holds the whole page rather than the winner: the chain takes the first and
/// the picker shows the rest, and between them that is one request.
Future<List<String>> pexelsPhotos(String query) =>
    _pexels.putIfAbsent(query, () => _fetchPexels(query));

/// Per run, keyed by query, the same bargain [wikipediaImage] makes: two
/// recipes that look alike share one lookup, and only the *images* survive a
/// restart.
final _pexels = <String, Future<List<String>>>{};

/// Drops every seeded or fetched result, so one test's photos do not show up
/// in the next — the memo outlives a test the way it outlives a screen.
@visibleForTesting
void forgetPexels() => _pexels.clear();

/// Lets a test drive the hit path. Nothing under `flutter test` reaches a
/// network — the binding answers every https request with 400 — so the only way
/// to exercise "the chain took a stock photo" is to have the answer in hand.
///
/// Call it inside `tester.runAsync`, never before. The seed is a Future, and
/// one made in the fake-async zone never delivers to a chain walking under the
/// real clock: the test just waits until it times out.
@visibleForTesting
void seedPexels(String query, List<String> urls) =>
    _pexels[query] = Future.value(urls);

Future<List<String>> _fetchPexels(String query) async {
  // No key is the normal state of a fresh checkout and of the test suite.
  // Skipping quietly beats a link in the chain that always errors.
  if (_pexelsKey.isEmpty || query.trim().isEmpty) return const [];
  final uri = Uri.https('api.pexels.com', '/v1/search', {
    'query': query,
    // One page serves both the hero and the picker's three-by-three grid.
    'per_page': '9',
    // A hero is a wide band and a list tile is a square; a portrait shot crops
    // to the middle of its subject in both.
    'orientation': 'landscape',
  });
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    // Pexels takes the bare key — no 'Bearer'.
    request.headers.set(HttpHeaders.authorizationHeader, _pexelsKey);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) return const [];
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    return [
      for (final photo in (body['photos'] as List? ?? const []))
        // 'large' is 940px. Not the larger rendition: the picker's tile and the
        // hero then share one cache entry, so a photo the sheet has already
        // shown is on disk by the time it is picked.
        if (((photo as Map)['src'] as Map?)?['large'] case final String url)
          url,
    ];
  } catch (_) {
    // Offline, a 429 off the free tier, malformed JSON — none of them should
    // take a recipe screen down, so they all read as "no photos".
    return const [];
  } finally {
    client.close();
  }
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

  /// The dish, for one last try at [wikipediaImage] once everything else is
  /// spent — or null to skip it. The editor's preview passes null: "does the
  /// url I typed work" is a question a stand-in photo answers wrongly.
  final String? title;

  /// What the dish looks like, for [pexelsPhotos] — or null to skip it. Null in
  /// the editor's preview for the same reason [title] is.
  final String? query;

  /// The recipe's urls, plus whatever the fallbacks turn up. Copied rather than
  /// held: this list grows, and the caller's is the model's.
  final List<String> _urls;

  ImageChain(
    List<String> urls,
    this.store,
    this.onChanged, {
    this.title,
    this.query,
  }) : _urls = List.of(urls);

  /// The fallbacks left to try, in order: a stock photograph of what the dish
  /// looks like, then a photo of the dish itself from Wikipedia.
  ///
  /// Wikipedia is last rather than deleted. It is a picture of *this* dish
  /// where the search is a picture of something that merely looks like it, so
  /// it is the better answer whenever the search comes back empty — and it is
  /// the only answer at all in a build with no API key.
  ///
  /// A queue popped as it is spent, rather than a flag per stage. That is the
  /// whole termination argument: a fallback whose url also fails comes straight
  /// back through [_finish] and finds a shorter list every time.
  late final List<Future<String?> Function()> _fallbacks = [
    if (query != null)
      () async {
        final photos = await pexelsPhotos(query!);
        return _fromSearch = photos.isEmpty ? null : photos.first;
      },
    if (title != null) () => wikipediaImage(title!),
  ];

  /// What the photo search turned up, if anything, so [winnerFromSearch] can
  /// tell it from a Wikipedia consolation prize.
  String? _fromSearch;

  /// The url that has actually decoded, as opposed to [winner], which is
  /// optimistic and names a url before it has loaded.
  String? _loaded;

  int _index = 0;
  bool _settled = false;
  bool _disposed = false;
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

  /// Whether what is on screen came from [pexelsPhotos] *and has loaded*.
  ///
  /// The detail screen keeps a photo that answers true and leaves one that
  /// answers false where it is: pinning a recipe to the plain Wikipedia stand-in
  /// is the thing the search exists to stop. Loaded, not merely [winner],
  /// because [winner] is optimistic — keeping a url before it decodes would
  /// write a dead link into the recipe for good, and every visit after would
  /// spend an attempt on it.
  bool get winnerFromSearch =>
      winner != null && winner == _fromSearch && winner == _loaded;

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
    final url = _urls[_index];
    _listener = ImageStreamListener((_, _) {
      // Once per url: an animated image reports every frame.
      if (_loaded == url) return;
      _loaded = url;
      onChanged();
    }, onError: (_, _) => _advance());
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

  /// The urls in hand are spent. Take the next fallback, or settle when there
  /// are none left.
  ///
  /// While a lookup is in flight the chain is neither settled nor pointing at a
  /// url, which is the same "still loading" state as a network image that
  /// hasn't arrived. The hero stays open rather than closing and reopening.
  void _finish() {
    if (_settled) return;
    if (_fallbacks.isEmpty) {
      _settled = true;
      onChanged();
      return;
    }
    _fallbacks.removeAt(0)().then((url) {
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
