import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_local_data/local_data.dart';
import 'package:fideflow_local_data/local_data_io.dart';
import 'package:flutter/foundation.dart';

/// The app-managed artwork cache: the disk files, their index, and the network
/// scheduler behind them (design §3, §8).
///
/// Flutter's `ImageCache` stays the in-process decode cache — it is what makes
/// one decoded cover serve many rows — and this is the layer that survives a
/// restart. Nothing here blocks the queue or playback: a cover that is missing,
/// stale, oversized or broken is a placeholder, never a delay.
///
/// Reading is fetch-on-demand rather than prefetch-and-cancel. A row that scrolls
/// away simply stops consuming its result, and because the request is the
/// `ImageCache` key, a row that scrolls back asks for exactly its own artwork
/// instead of inheriting another row's.
final class ArtworkService implements ArtworkRepository {
  ArtworkService({
    required this.store,
    required this.files,
    required this.namespace,
    HttpClient? client,
    DateTime Function()? now,
    this.backgroundRefresh = true,
    this.concurrency = 4,
    this.requestBudget = const Duration(seconds: 15),
    this.maxDownloadBytes = ArtworkLimits.maxDownloadBytes,
    this.onDiagnostic,
  }) : _client = client ?? HttpClient(),
       _now = now ?? DateTime.now;

  final MetadataCacheStore store;
  final ArtworkFileStore files;

  /// Which provider deployment the assets belong to (docs/design/provider.md, docs/design/provider.md).
  final String namespace;

  final HttpClient _client;
  final DateTime Function() _now;

  /// Whether a stale cover may be revalidated behind the caller. Tests turn it
  /// off to keep the timing deterministic.
  final bool backgroundRefresh;

  /// How many downloads may be in flight at once (design §8).
  final int concurrency;

  final Duration requestBudget;
  final int maxDownloadBytes;

  /// Receives stable, payload-free codes only (design §11).
  final void Function(String code)? onDiagnostic;

  final Map<String, Future<ArtworkData?>> _inFlight = {};
  final Map<String, DateTime> _lastAccessWrite = {};
  int _active = 0;
  bool _disposed = false;

  /// How many times this service's own artwork cache was cleared.
  ///
  /// [MetadataCacheStore.cacheGeneration] covers a cache-wide clear and an
  /// account switch, but not [clear] — which drops the artwork alone and
  /// deliberately keeps the metadata records that outlive it. A download in
  /// flight must be invalidated by both (design §9).
  int _clearGeneration = 0;

  /// The artwork the current view is on, used as the pin set when the artwork
  /// budget is enforced. An approximation of "the current and adjacent covers"
  /// (design §10) that costs nothing to maintain: the last few requests.
  final List<String> _recentKeys = [];

  static const int _recentKeyLimit = 24;

  /// The partition public covers belong to.
  CacheScope get publicScope => CacheScope.public(namespace: namespace);

  /// The partition an account's private artwork (an avatar) belongs to.
  CacheScope accountScopeFor(String accountId) =>
      CacheScope(namespace: namespace, accountId: accountId);

  /// A request for a public cover.
  ArtworkRequest publicRequest(
    Uri uri,
    ArtworkSizeBucket bucket, {
    String? resourceVersion,
  }) => ArtworkRequest(
    scope: publicScope,
    uri: uri,
    sizeBucket: bucket,
    resourceVersion: resourceVersion,
  );

  /// The index key for [request].
  ///
  /// A provider that published a stable asset id could be keyed by it; none of
  /// this deployment's cover URLs does, so the *whole* URL is digested — query
  /// parameters included, because a signature, a size or a resource version can
  /// select different bytes (design §4).
  String assetKeyOf(ArtworkRequest request) =>
      '${_digest(request.uri.toString())}-'
      '${request.resourceVersion ?? 'r0'}-'
      '${request.sizeBucket.pixels}';

  @override
  Future<ArtworkData?> load(
    ArtworkRequest request, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    if (_disposed) return null;
    final key = assetKeyOf(request);
    _remember(key);

    final entry = await store.readArtworkIndex(request.scope, key);
    if (_disposed) return null;
    final cached = entry == null ? null : await _read(entry);
    if (_disposed) return null;

    // Past its maximum display age a cover is a miss rather than something to
    // show: the server's own rules (`must-revalidate`, `no-cache`) and the
    // default 180-day cap all end up here (design §5).
    final showable = cached != null && cached.freshness != CacheFreshness.miss;

    if (policy == RefreshPolicy.localOnly) {
      // Even here: bytes the server said must be validated first, and bytes
      // past their maximum display age, are not something to hand out
      // (design §5).
      if (!showable) return null;
      _touchAccess(key, request.scope);
      return cached;
    }

    // `forceRefresh` deliberately goes past this: the caller asked for a
    // validation of a cover that already looks fresh (design §5).
    if (showable && policy != RefreshPolicy.forceRefresh) {
      if (cached.freshness == CacheFreshness.fresh) {
        _touchAccess(key, request.scope);
        return cached;
      }
      if (policy == RefreshPolicy.cacheFirst) {
        // A stale cover is shown now and revalidated behind the caller
        // (design §5, §8).
        _refreshBehind(request, key);
        return cached;
      }
    }

    final fetched = await _singleFlight(key, () => _fetch(request, key, entry));
    if (fetched != null) {
      _touchAccess(key, request.scope);
      return fetched;
    }
    // A download that failed keeps whatever is displayable: replacing a picture
    // with a placeholder is not an improvement (design §8).
    return showable ? cached : null;
  }

  /// Deletes files the metadata store reports as orphaned.
  ///
  /// The store does no file I/O on purpose, so whoever clears records hands the
  /// paths back here (design §10).
  Future<void> deleteFiles(Iterable<String> relativePaths) =>
      files.deleteAll(relativePaths);

  /// Forgets an artwork a decoder rejected, so the next read fetches it again
  /// (design §4: a corrupt record is a miss, isolated or deleted and refetched).
  Future<void> discard(ArtworkRequest request) async {
    if (_disposed) return;
    final key = assetKeyOf(request);
    final entry = await store.readArtworkIndex(request.scope, key);
    if (_disposed || entry == null) return;
    _diagnose('artwork.undecodable');
    await store.deleteArtworkIndex(request.scope, key);
    await files.delete(entry.filePath);
  }

  @override
  Future<void> clear() async {
    if (_disposed) return;
    // Artwork alone: the covers are rebuildable, and dropping them must not cost
    // the playlists and song labels around them (design §10).
    //
    // The generation moves first, so a download that is already in flight
    // cannot land its file and its index row behind the clear (design §9).
    _clearGeneration++;
    final orphans = await store.clearArtwork();
    await files.deleteAll(orphans);
    _lastAccessWrite.clear();
    _recentKeys.clear();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _client.close(force: true);
  }

  // -------------------------------------------------------------------------
  // Reads, fetches and writes
  // -------------------------------------------------------------------------

  Future<ArtworkData?> _read(ArtworkIndexEntry entry) async {
    final bytes = await files.read(entry.filePath);
    if (bytes == null) {
      // The index outlived its file: a miss, and the row is not worth keeping.
      return null;
    }
    if (bytes.length != entry.byteSize) {
      // A truncated or replaced file is not handed to the decoder (design §4).
      _diagnose('artwork.sizeMismatch');
      return null;
    }
    return ArtworkData(
      bytes: bytes,
      freshness: entry.envelope.freshnessAt(_now()),
      mimeType: entry.mimeType,
      pixelWidth: entry.pixelWidth,
      pixelHeight: entry.pixelHeight,
    );
  }

  Future<ArtworkData?> _fetch(
    ArtworkRequest request,
    String key,
    ArtworkIndexEntry? existing,
  ) async {
    // The ticket is taken before the queue, not after it: a task that waited
    // while the cache was cleared must not be born into the generation that
    // replaced it (design §9).
    final ticket = _FetchTicket(
      storeGeneration: store.cacheGeneration,
      clearGeneration: _clearGeneration,
    );

    // The stored cover this download may fall back on. Only one that may still
    // be shown counts: a row the server said must be validated first, or one
    // past its maximum display age, is a miss, and showing it anyway would be
    // exactly the reuse the response forbade (design §5).
    Future<ArtworkData?> previous() async {
      final entry = existing;
      if (entry == null || !entry.envelope.isDisplayableAt(_now())) {
        return null;
      }
      return _read(entry);
    }

    await _acquire();
    // One budget covers the whole exchange — connect, response head and body.
    // A peer that sends its headers and then stops is exactly what holds a
    // download slot forever when only the head of the request is timed
    // (design §8).
    final clock = Stopwatch()..start();
    try {
      // Waiting for a slot is not a place a task may survive a clear in.
      if (!_isTicketCurrent(ticket)) return null;

      final targetUri = resolveFetchUri(request.uri, request.sizeBucket);
      final httpRequest = await _client
          .getUrl(targetUri)
          .timeout(_remaining(clock));
      httpRequest.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      );
      httpRequest.headers.set(
        HttpHeaders.acceptHeader,
        'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
      );
      // Conditional revalidation: a 304 keeps the file and moves only the
      // validation time (design §5, §8).
      final etag = existing?.envelope.etag;
      final modified = existing?.envelope.lastModified;
      if (etag != null && etag.isNotEmpty) {
        httpRequest.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      // A validator that could not be parsed is stored as null and simply not
      // sent: an unusable date must never fail a cover (design §5).
      if (modified != null) {
        httpRequest.headers.set(
          HttpHeaders.ifModifiedSinceHeader,
          HttpDate.format(modified),
        );
      }

      final response = await httpRequest.close().timeout(_remaining(clock));
      if (response.statusCode == HttpStatus.notModified && existing != null) {
        // A 304 states only what changed. The window it does not mention is the
        // one the stored copy already has, so the policy is merged onto the
        // entry's own rather than onto the default: a `no-cache` cover must not
        // become a month-fresh one because the revalidation said nothing
        // (design §5).
        final policy = _cachePolicyOf(
          response,
          carried: _windowOf(existing.envelope),
        );
        await _discardBody(response, clock);
        if (!_isTicketCurrent(ticket)) return null;
        if (!policy.storable) {
          // The server has taken the right to keep the entry away: the stored
          // copy goes with it, and only these validated bytes are shown
          // (design §5).
          final validated = await _read(existing);
          await store.deleteArtworkIndex(request.scope, key);
          await files.delete(existing.filePath);
          return validated;
        }
        final refreshed = existing.withEnvelope(
          existing.envelope.revalidatedAt(_now(), policy.window),
        );
        await store.putArtworkIndex(refreshed);
        return await _read(refreshed);
      }
      if (response.statusCode != HttpStatus.ok) {
        String errorSnippet = '';
        try {
          final errorBytes = await _consumeBody(response, clock, keep: true);
          if (errorBytes.isNotEmpty) {
            final text = utf8
                .decode(errorBytes.take(512).toList(), allowMalformed: true)
                .replaceAll('\n', ' ')
                .trim();
            if (text.isNotEmpty) {
              errorSnippet = ' | body: $text';
            }
          }
        } catch (_) {}
        _diagnose('artwork.http.${response.statusCode}');
        debugPrint(
          'Fideflow: artwork download HTTP ${response.statusCode} for ${request.uri} (scope: ${request.scope}, bucket: ${request.sizeBucket})$errorSnippet',
        );
        return await previous();
      }

      final policy = _cachePolicyOf(response);
      final bytes = await _readCapped(response, clock);
      final inspected = _inspect(bytes);
      if (inspected == null) {
        _diagnose('artwork.unrecognisedFormat');
        return await previous();
      }
      if (inspected.pixels > ArtworkLimits.maxDecodedPixels) {
        // Too large to decode safely: refused rather than expanded (design §8).
        _diagnose('artwork.tooManyPixels');
        return await previous();
      }

      // A response the server forbade keeping is still this launch's cover: it
      // is shown from memory, and nothing about it is written down — including
      // whatever the same asset left in the cache before. A copy an earlier
      // response stored is still a copy this response forbids serving
      // (design §5).
      if (!policy.storable) {
        if (!_isTicketCurrent(ticket)) return null;
        if (existing != null) {
          await store.deleteArtworkIndex(request.scope, key);
          await files.delete(existing.filePath);
        }
        return _displayed(bytes, inspected);
      }

      final relative = _relativePath(request, key, inspected.extension);
      final staged = await files.stage(relative, bytes);
      if (!_isTicketCurrent(ticket)) {
        // The cache was cleared while these bytes were in flight. The task is
        // over, and it leaves nothing behind (design §9).
        await files.discard(staged);
        return null;
      }
      try {
        await files.commit(staged, relative);
      } catch (_) {
        await files.discard(staged);
        rethrow;
      }
      if (!_isTicketCurrent(ticket)) {
        // The file is already renamed into place and no index row was written
        // for it, so the orphan is removed explicitly.
        await files.delete(relative);
        return null;
      }

      final entry = ArtworkIndexEntry(
        assetKey: key,
        filePath: relative,
        byteSize: bytes.length,
        envelope: CacheEnvelope.fresh(
          scope: request.scope,
          at: _now(),
          window: policy.window,
          etag: response.headers.value(HttpHeaders.etagHeader),
          lastModified: _httpDate(
            response.headers.value(HttpHeaders.lastModifiedHeader),
          ),
        ),
        mimeType: inspected.mimeType,
        pixelWidth: inspected.width,
        pixelHeight: inspected.height,
        sizeBucket: request.sizeBucket,
        resourceVersion: request.resourceVersion,
      );
      try {
        await store.putArtworkIndex(entry);
      } catch (_) {
        // The picture arrived; only the record of it did not. A cache that
        // cannot write its index loses the file rather than the cover
        // (design §4, §8).
        _diagnose('artwork.storage');
        await files.delete(relative);
        return _displayed(bytes, inspected);
      }
      await _enforceArtworkBudget();
      return _displayed(bytes, inspected);
    } on _ArtworkRefused {
      // Already reported by the cap check; the old cover stays.
      return await previous();
    } on FileSystemException catch (e) {
      if (_disposed) return null;
      // A cache root this process cannot write is a miss for this launch, not a
      // reason for a page to fail (design §4, §10).
      _diagnose('artwork.storage');
      debugPrint('Fideflow: artwork file storage error for ${request.uri}: $e');
      return await previous();
    } on TimeoutException catch (e) {
      if (_disposed) return null;
      _diagnose('artwork.timeout');
      debugPrint('Fideflow: artwork download timeout for ${request.uri}: $e');
      return await previous();
    } on SocketException catch (e) {
      if (_disposed) return null;
      _diagnose('artwork.unreachable');
      debugPrint(
        'Fideflow: artwork download unreachable for ${request.uri}: $e',
      );
      return await previous();
    } on HttpException catch (e) {
      if (_disposed) return null;
      _diagnose('artwork.transport');
      debugPrint(
        'Fideflow: artwork download transport error for ${request.uri}: $e',
      );
      return await previous();
    } finally {
      _release();
    }
  }

  /// Consumes a response body — collecting it, or emptying it when [keep] is
  /// false — within what is left of the request's budget (design §8).
  ///
  /// The read is a subscription rather than an `await for` or a `drain`
  /// because every ending has to *cancel* it: cancelling is what closes the
  /// connection. A body that is merely stopped waiting for keeps its socket
  /// open, and with `maxConnectionsPerHost` exhausted the covers queued behind
  /// it never reach the server at all (design §8). Every exit cancels in
  /// [Future.whenComplete], including the two endings below.
  Future<Uint8List> _consumeBody(
    HttpClientResponse response,
    Stopwatch clock, {
    bool keep = true,
  }) {
    final builder = BytesBuilder(copy: false);
    final completer = Completer<Uint8List>();
    var finished = false;

    void finish([Object? error, StackTrace? stack]) {
      if (finished) return;
      finished = true;
      if (error == null) {
        completer.complete(builder.takeBytes());
      } else {
        completer.completeError(error, stack);
      }
    }

    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      keep
          ? (chunk) {
              builder.add(chunk);
              if (builder.length > maxDownloadBytes) {
                // Refused rather than truncated, and the rest of a body the app
                // will not keep is not worth reading (design §8).
                _diagnose('artwork.tooLarge');
                finish(const _ArtworkRefused());
              }
            }
          : (chunk) {},
      onDone: finish,
      onError: (Object error, StackTrace stack) => finish(error, stack),
      cancelOnError: true,
    );

    final timer = Timer(_remaining(clock), () {
      // The budget is gone. The cancelled subscription closes the connection,
      // so a peer that stopped sending cannot hold either the slot or the
      // connection behind it (design §8).
      finish(TimeoutException('artwork body read exceeded its budget'));
    });

    return completer.future.whenComplete(() async {
      timer.cancel();
      await subscription.cancel();
    });
  }

  /// Reads the body, refusing rather than truncating one over the cap, and
  /// giving up on a body whose peer stopped sending once what is left of the
  /// request's budget runs out (design §8).
  Future<Uint8List> _readCapped(HttpClientResponse response, Stopwatch clock) =>
      _consumeBody(response, clock);

  /// Empties a response the caller will not keep, within what is left of the
  /// request's budget (design §8).
  ///
  /// The failure is swallowed because the caller has already decided the body
  /// is worthless — and because the connection is closed either way, so the
  /// next request can have it.
  Future<void> _discardBody(
    HttpClientResponse response,
    Stopwatch clock,
  ) async {
    try {
      await _consumeBody(response, clock, keep: false);
    } on TimeoutException {
      // The budget is spent; the connection went with it.
    } on HttpException {
      // The peer closed it early: there was nothing left to keep either way.
    } on SocketException {
      // Same.
    }
  }

  /// What is left of [requestBudget] since [clock] started, never negative.
  Duration _remaining(Stopwatch clock) {
    final left = requestBudget - clock.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// [bytes] as the result of a download that succeeded, without reading the
  /// file back: a cover that arrived must not become a placeholder because the
  /// cache could not read its own file (design §8).
  static ArtworkData _displayed(Uint8List bytes, _Inspected inspected) =>
      ArtworkData(
        bytes: bytes,
        freshness: CacheFreshness.fresh,
        mimeType: inspected.mimeType,
        pixelWidth: inspected.width,
        pixelHeight: inspected.height,
      );

  /// Whether a download may still commit bytes, write an index row and hand a
  /// result back: the cache it was started for still exists (design §9).
  bool _isTicketCurrent(_FetchTicket ticket) =>
      !_disposed &&
      store.cacheGeneration == ticket.storeGeneration &&
      _clearGeneration == ticket.clearGeneration;

  /// What the response's own headers allow the cache to do with the body and
  /// how long it may reuse it without asking again (design §5).
  ///
  /// `no-store` forbids keeping the body at all; `no-cache` (or `max-age=0`)
  /// allows keeping it but forbids reusing it before it has been validated
  /// again; `must-revalidate` forbids showing it once it is stale; `max-age`
  /// states the fresh window and can never shorten the maximum display age
  /// below it. A response that states nothing falls back to [carried] — the
  /// policy the stored copy already had, which is what a 304 that mentions no
  /// directives has to keep — and only a first fetch reaches the default
  /// artwork window.
  ///
  /// Requests carry no variant selectors, so an ordinary `Vary` cannot split one
  /// asset key into several bodies; `Vary: *` is the one form that must not be
  /// stored.
  static _ResponseCachePolicy _cachePolicyOf(
    HttpClientResponse response, {
    FreshnessWindow? carried,
  }) {
    final fallback = carried ?? CacheContentKind.artwork.window;
    final directives = _directivesOf(
      response.headers[HttpHeaders.cacheControlHeader],
    );
    if (directives.containsKey('no-store') || _variesOnEverything(response)) {
      return _ResponseCachePolicy(storable: false, window: fallback);
    }
    final maxAge = _maxAgeOf(response.headers, directives);
    // `no-cache` and `max-age=0` mean "store it, but never serve it again
    // without a successful validation first". That is not the stale-while-
    // revalidate treatment: the record has to read back as a miss, because a
    // stale branch is exactly the path that shows it before validating.
    final validateFirst =
        directives.containsKey('no-cache') || maxAge == Duration.zero;
    final fresh = validateFirst ? Duration.zero : (maxAge ?? fallback.fresh);
    // `must-revalidate` ends the record's life where its fresh window ends,
    // instead of letting it be shown while it is revalidated.
    final maxStale = validateFirst || directives.containsKey('must-revalidate')
        ? fresh
        : (fresh > fallback.maxStale ? fresh : fallback.maxStale);
    return _ResponseCachePolicy(
      storable: true,
      window: FreshnessWindow(fresh: fresh, maxStale: maxStale),
    );
  }

  /// The freshness window a stored [envelope] was written with.
  ///
  /// Both windows are measured from the last success the envelope records, so
  /// their distance from it is exactly the policy that produced it — which is
  /// what a revalidation has to merge onto (design §5).
  static FreshnessWindow _windowOf(CacheEnvelope envelope) => FreshnessWindow(
    fresh: envelope.freshUntil.difference(envelope.fetchedAt),
    maxStale: envelope.staleUntil.difference(envelope.fetchedAt),
  );

  /// The `Cache-Control` directives of [values], lowercase names and unquoted
  /// values, so a server's spelling never changes the interpretation.
  static Map<String, String> _directivesOf(List<String>? values) {
    final directives = <String, String>{};
    if (values == null) return directives;
    for (final value in values) {
      for (final part in value.split(',')) {
        final trimmed = part.trim();
        if (trimmed.isEmpty) continue;
        final separator = trimmed.indexOf('=');
        final name = (separator < 0 ? trimmed : trimmed.substring(0, separator))
            .trim()
            .toLowerCase();
        if (name.isEmpty) continue;
        final raw = separator < 0
            ? ''
            : trimmed.substring(separator + 1).trim();
        directives[name] = raw.replaceAll('"', '');
      }
    }
    return directives;
  }

  /// The fresh window the response states, with the time it already spent in a
  /// cache (`Age`) taken off it. Null when it states none that is usable.
  static Duration? _maxAgeOf(
    HttpHeaders headers,
    Map<String, String> directives,
  ) {
    final stated = int.tryParse(directives['max-age'] ?? '');
    if (stated == null || stated < 0) return null;
    final age = int.tryParse(headers.value(HttpHeaders.ageHeader) ?? '') ?? 0;
    final remaining = stated - (age < 0 ? 0 : age);
    return Duration(seconds: remaining < 0 ? 0 : remaining);
  }

  /// Whether the response says its body varies on something no key can separate.
  static bool _variesOnEverything(HttpClientResponse response) {
    final vary = response.headers[HttpHeaders.varyHeader];
    if (vary == null) return false;
    for (final value in vary) {
      if (value.trim() == '*') return true;
    }
    return false;
  }

  /// Sheds artwork until the disk budget is back under its target (design §10).
  ///
  /// Called after a write, not from the startup path, and only when the index
  /// already reports being over budget.
  Future<void> _enforceArtworkBudget() async {
    final stats = await store.stats();
    if (stats.artworkBytes <= CacheBudget.artworkDiskBytes) return;
    final orphans = await store.enforceBudget(
      pinnedArtworkKeys: _recentKeys.toSet(),
    );
    await files.deleteAll(orphans);
  }

  /// Records that a cover was shown, coalesced rather than written per frame
  /// (design §10). It never changes freshness.
  ///
  /// The row is looked up again when the write is due rather than reusing the
  /// copy the caller holds. A revalidation or a `no-store` response may have
  /// rewritten or revoked it in the meantime, and an access record must neither
  /// undo that nor write a whole row back into being (design §5, §9).
  void _touchAccess(String assetKey, CacheScope scope) {
    final now = _now();
    final previous = _lastAccessWrite[assetKey];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 5)) {
      return;
    }
    _lastAccessWrite[assetKey] = now;
    // A touch is best-effort bookkeeping, so losing one costs nothing; writing
    // one back into a cache that moved on costs a row. Hence the row is looked
    // up when the write is due rather than reusing the copy the caller holds,
    // and the generations are checked on either side of that lookup: a
    // revalidation or a `no-store` response may have revoked the row, and a
    // clear may have dropped it (design §5, §9, §10).
    final ticket = _FetchTicket(
      storeGeneration: store.cacheGeneration,
      clearGeneration: _clearGeneration,
    );
    unawaited(() async {
      if (!_isTicketCurrent(ticket)) return;
      final entry = await store.readArtworkIndex(scope, assetKey);
      if (entry == null || !_isTicketCurrent(ticket)) return;
      await store.putArtworkIndex(
        entry.withEnvelope(entry.envelope.accessedAt(now)),
      );
    }());
  }

  void _refreshBehind(ArtworkRequest request, String key) {
    if (!backgroundRefresh) return;
    unawaited(() async {
      try {
        final entry = await store.readArtworkIndex(request.scope, key);
        await _singleFlight(key, () => _fetch(request, key, entry));
      } catch (_) {
        // The old cover stays; the failure is already a diagnostic.
      }
    }());
  }

  void _remember(String key) {
    _recentKeys.remove(key);
    _recentKeys.add(key);
    if (_recentKeys.length > _recentKeyLimit) {
      _recentKeys.removeRange(0, _recentKeys.length - _recentKeyLimit);
    }
  }

  /// Merges concurrent loads of one asset (design §9).
  ///
  /// The merge key carries the cache generation the load belongs to, so a read
  /// that follows a clear neither joins nor inherits a task the clear
  /// invalidated.
  Future<ArtworkData?> _singleFlight(
    String key,
    Future<ArtworkData?> Function() body,
  ) {
    final flight = _flightKey(key);
    final existing = _inFlight[flight];
    if (existing != null) return existing;
    late final Future<ArtworkData?> future;
    future = body().whenComplete(() {
      // Only while it is still the task on record: one that outlived a clear
      // must not evict the task that replaced it.
      if (identical(_inFlight[flight], future)) _inFlight.remove(flight);
    });
    _inFlight[flight] = future;
    return future;
  }

  /// The in-flight key for a loaded asset: the asset plus the cache generation
  /// it is being fetched for (design §9).
  String _flightKey(String assetKey) =>
      '$assetKey@${store.cacheGeneration}#$_clearGeneration';

  Future<void> _acquire() async {
    while (_active >= concurrency) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    _active++;
  }

  void _release() {
    if (_active > 0) _active--;
  }

  void _diagnose(String code) => onDiagnostic?.call(code);

  String _relativePath(ArtworkRequest request, String key, String extension) {
    final partition = request.scope.isPublic
        ? 'public'
        : 'account-${_safeSegment(request.scope.accountId!)}';
    return '$partition/$key.$extension';
  }

  /// Upgrades public HTTP artwork URIs to HTTPS to avoid plaintext CDN blocks,
  /// while keeping local loopback addresses (test fixtures, local provider) intact.
  ///
  /// For verified NCM image CDN hosts (*.music.126.net), if no `param` query
  /// parameter is present, appends `param={pixels}y{pixels}` matching the
  /// requested [bucket] (design §8).
  static Uri resolveFetchUri(Uri uri, [ArtworkSizeBucket? bucket]) {
    var resolved = uri;
    if (resolved.isScheme('http')) {
      final host = resolved.host.toLowerCase();
      final isLocal =
          host == '127.0.0.1' ||
          host == 'localhost' ||
          host.startsWith('192.168.') ||
          host.startsWith('10.') ||
          host.endsWith('.local');
      if (!isLocal) {
        resolved = resolved.replace(scheme: 'https');
      }
    }
    if (_isNcmImageHost(resolved.host)) {
      final query = Map<String, String>.of(resolved.queryParameters);
      // Clean up any NCM NosImage pipeline parameters that conflict with
      // requested thumbnail dimensions or cause HTTP 400 InvalidArgument on CDN.
      query.removeWhere(_isNcmImageProcessingParam);

      if (bucket != null) {
        if (!query.containsKey('param')) {
          final dimension = '${bucket.pixels}y${bucket.pixels}';
          query['param'] = dimension;
        }
      }
      resolved = resolved.replace(
        query: query.isEmpty ? '' : null,
        queryParameters: query.isEmpty ? null : query,
      );
    }
    return resolved;
  }

  static const _ncmImageProcessingKeys = <String>{
    'imageview',
    'thumbnail',
    'enlarge',
    'watermark',
    'image',
    'dx',
    'dy',
    'type',
  };

  static bool _isNcmImageProcessingParam(String key, String value) {
    final lowerKey = key.toLowerCase();
    if (_ncmImageProcessingKeys.contains(lowerKey)) return true;
    if (key.contains('|') || key.contains('%7C')) return true;
    if (value.contains('|') || value.contains('%7C')) return true;
    return false;
  }

  static bool _isNcmImageHost(String host) {
    final lower = host.toLowerCase();
    return lower == 'music.126.net' ||
        lower.endsWith('.music.126.net') ||
        lower == '126.net' ||
        lower.endsWith('.126.net');
  }

  static String _safeSegment(String value) {
    final builder = StringBuffer();
    for (final unit in value.codeUnits) {
      final isSafe =
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x61 && unit <= 0x7a) ||
          (unit >= 0x41 && unit <= 0x5a) ||
          unit == 0x2d ||
          unit == 0x5f;
      builder.write(isSafe ? String.fromCharCode(unit) : '_');
    }
    final safe = builder.toString();
    return safe.isEmpty ? 'unknown' : safe;
  }

  /// The optional `Last-Modified` validator the headers carry, or null when
  /// there is none or it cannot be read.
  ///
  /// A validator is optional cache metadata: a CDN that writes a timezone name
  /// (such as `Asia/Shanghai`) or numeric offset where RFC 1123 wants `GMT`
  /// delivers a perfectly good cover. We parse standard HTTP dates first, then
  /// fall back to timezone-aware RFC 1123 variants, ISO-8601, and unix timestamps.
  /// An unreadable one is dropped and reported under its own code, so that
  /// `artwork.transport` keeps meaning "the transfer failed" rather than "a date
  /// did not parse" (design §5, §9).
  DateTime? _httpDate(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final trimmed = value.trim();

    // 1. Standard RFC 1123 / RFC 850 / asctime
    try {
      return HttpDate.parse(trimmed);
    } on HttpException {
      // Fall through to flexible parsing.
    } on FormatException {
      // Fall through to flexible parsing.
    }

    // 2. RFC 1123 variants with timezone names or numeric offsets
    final variant = _parseVariantHttpDate(trimmed);
    if (variant != null) return variant;

    // 3. Unix timestamps (seconds or milliseconds)
    final epoch = _tryParseEpoch(trimmed);
    if (epoch != null) return epoch;

    // 4. ISO 8601 timestamps
    final iso = DateTime.tryParse(trimmed);
    if (iso != null) return iso.toUtc();

    _diagnose('artwork.validator.invalid: $value');
    return null;
  }

  static final _rfc1123VariantRegex = RegExp(
    r'^(?:[A-Za-z]{3},\s+)?(\d{1,2})[-\s+]([A-Za-z]{3})[-\s+](\d{2,4})\s+(\d{2}):(\d{2}):(\d{2})(?:\s+([A-Za-z0-9_\/+-:]+))?$',
    caseSensitive: false,
  );

  static const _monthNames = <String, int>{
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static Duration _parseZoneOffset(String? zone) {
    if (zone == null || zone.trim().isEmpty) return Duration.zero;
    final z = zone.trim().toLowerCase();
    if (z == 'gmt' || z == 'utc' || z == 'z') return Duration.zero;

    if (z == 'asia/shanghai' ||
        z == 'asia/chongqing' ||
        z == 'asia/harbin' ||
        z == 'asia/hong_kong' ||
        z == 'asia/taipei' ||
        z == 'prc' ||
        z == 'cst') {
      return const Duration(hours: 8);
    }
    if (z == 'asia/tokyo' || z == 'jst' || z == 'asia/seoul' || z == 'kst') {
      return const Duration(hours: 9);
    }

    final match = RegExp(r'^([+-])(\d{1,2})(?::?(\d{2}))?$').firstMatch(z);
    if (match != null) {
      final sign = match.group(1) == '-' ? -1 : 1;
      final hours = int.parse(match.group(2)!);
      final minutes = match.group(3) != null ? int.parse(match.group(3)!) : 0;
      return Duration(minutes: sign * (hours * 60 + minutes));
    }

    return Duration.zero;
  }

  static DateTime? _parseVariantHttpDate(String value) {
    final match = _rfc1123VariantRegex.firstMatch(value);
    if (match == null) return null;

    final day = int.tryParse(match.group(1)!);
    final month = _monthNames[match.group(2)!.toLowerCase()];
    var year = int.tryParse(match.group(3)!);
    final hour = int.tryParse(match.group(4)!);
    final minute = int.tryParse(match.group(5)!);
    final second = int.tryParse(match.group(6)!);
    final zone = match.group(7);

    if (day == null ||
        month == null ||
        year == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }

    if (year < 100) {
      year += year >= 70 ? 1900 : 2000;
    }

    try {
      final offset = _parseZoneOffset(zone);
      return DateTime.utc(
        year,
        month,
        day,
        hour,
        minute,
        second,
      ).subtract(offset);
    } catch (_) {
      return null;
    }
  }

  static DateTime? _tryParseEpoch(String value) {
    final digits = int.tryParse(value);
    if (digits == null) return null;
    if (digits >= 1000000000 && digits <= 9999999999) {
      return DateTime.fromMillisecondsSinceEpoch(digits * 1000, isUtc: true);
    }
    if (digits >= 1000000000000 && digits <= 9999999999999) {
      return DateTime.fromMillisecondsSinceEpoch(digits, isUtc: true);
    }
    return null;
  }

  /// A stable digest of [value], for an index key.
  ///
  /// Two independent 32-bit mixes, so a collision needs both to collide. A cache
  /// key is not a security boundary: the worst a collision can do is show one
  /// cover where another belongs, and the index is rebuilt from the network
  /// whenever it is cleared.
  static String _digest(String value) {
    var first = 0x811c9dc5;
    var second = 0x9e3779b9;
    for (final byte in utf8.encode(value)) {
      first = ((first ^ byte) * 16777619) & 0xFFFFFFFF;
      second = ((second * 31) ^ byte) & 0xFFFFFFFF;
    }
    return '${first.toRadixString(16).padLeft(8, '0')}'
        '${second.toRadixString(16).padLeft(8, '0')}';
  }

  /// What the bytes are, when they can be trusted (design §8).
  ///
  /// The check is deliberately offline: a header and a size are enough to refuse
  /// a non-image, a body that is not what it claims, and an image too large to
  /// decode. Actually decoding happens in the engine, and a file that fails
  /// there is dropped through [discard].
  static _Inspected? _inspect(Uint8List bytes) {
    if (bytes.length >= 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      final width = _be32(bytes, 16);
      final height = _be32(bytes, 20);
      return _Inspected('image/png', 'png', width, height);
    }
    if (bytes.length >= 10 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      final width = bytes[6] | (bytes[7] << 8);
      final height = bytes[8] | (bytes[9] << 8);
      return _Inspected('image/gif', 'gif', width, height);
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      final size = _jpegSize(bytes);
      // A JPEG whose frame header could not be read is still a JPEG; the size is
      // simply unknown, and the pixel cap is left to the engine's own limits.
      return _Inspected('image/jpeg', 'jpg', size?.$1 ?? 0, size?.$2 ?? 0);
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return const _Inspected('image/webp', 'webp', 0, 0);
    }
    return null;
  }

  static int _be32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  /// The pixel size of a JPEG, from the first start-of-frame segment.
  static (int, int)? _jpegSize(Uint8List bytes) {
    var index = 2;
    while (index + 9 < bytes.length) {
      if (bytes[index] != 0xff) {
        index++;
        continue;
      }
      final marker = bytes[index + 1];
      // A start-of-frame marker carries the dimensions; the other segments are
      // skipped by their own declared length.
      final isFrame =
          marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc;
      final length = (bytes[index + 2] << 8) | bytes[index + 3];
      if (isFrame) {
        final height = (bytes[index + 5] << 8) | bytes[index + 6];
        final width = (bytes[index + 7] << 8) | bytes[index + 8];
        return (width, height);
      }
      if (length < 2) return null;
      index += 2 + length;
    }
    return null;
  }
}

final class _Inspected {
  const _Inspected(this.mimeType, this.extension, this.width, this.height);

  final String mimeType;
  final String extension;
  final int width;
  final int height;

  /// Zero means "not determined", which skips the pixel check rather than
  /// failing it: an unknown size is not the same as a too-large one.
  int get pixels => width * height;
}

/// A body the app refused to keep, distinct from a transport failure.
final class _ArtworkRefused implements Exception {
  const _ArtworkRefused();
}

/// The two cache generations a download was started under (design §9).
///
/// [storeGeneration] moves on a cache-wide clear and on an account switch;
/// [clearGeneration] moves when this service's artwork alone is dropped. A task
/// whose ticket no longer matches may not write a file, an index row or a
/// result.
final class _FetchTicket {
  const _FetchTicket({
    required this.storeGeneration,
    required this.clearGeneration,
  });

  final int storeGeneration;
  final int clearGeneration;
}

/// What a response's headers say about keeping and reusing its body.
final class _ResponseCachePolicy {
  const _ResponseCachePolicy({required this.storable, required this.window});

  /// Whether the bytes may be written to disk and indexed at all.
  final bool storable;

  /// How long the bytes may be reused before the server has to be asked again.
  final FreshnessWindow window;
}
