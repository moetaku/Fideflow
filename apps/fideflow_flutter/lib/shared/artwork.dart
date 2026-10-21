import 'dart:async';
import 'dart:ui' as ui;

import 'package:fideflow_design_system/design_system.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/http_overrides.dart';
import 'artwork_service.dart';

/// Shared cache key for both visible artwork and queue predecoding.
ImageProvider artworkProvider(
  ArtworkService service,
  Uri uri,
  ArtworkSizeBucket bucket,
) => ResizeImage(
  ArtworkImage(service, service.publicRequest(uri, bucket)),
  width: bucket.pixels,
  height: bucket.pixels,
  allowUpscaling: false,
);

/// Makes the app's artwork cache visible to the artwork widgets below it.
///
/// An inherited widget rather than a parameter: the queue panel, the player and
/// the browse pages all draw the same cover and must not each thread a service
/// through their constructors. A tree without one falls back to the network
/// image it used before, which is what keeps the widget usable in a test that
/// only cares about layout.
final class ArtworkScope extends InheritedWidget {
  const ArtworkScope({required this.service, required super.child, super.key});

  final ArtworkService service;

  static ArtworkService? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArtworkScope>()?.service;

  @override
  bool updateShouldNotify(ArtworkScope oldWidget) =>
      oldWidget.service != service;
}

/// An [ImageProvider] that reads through the app's artwork cache (design §8).
///
/// Going through a provider — rather than loading bytes and handing them to the
/// widget — is what makes Flutter's decode cache and `cacheWidth`/`cacheHeight`
/// do their job: one URL fetched once, decoded once per display size, and a row
/// rebuilt for any other reason costs nothing.
///
/// [toString] deliberately names the scope and the bucket only: a provider
/// artwork URL can carry a signature and must never reach a log.
final class ArtworkImage extends ImageProvider<ArtworkImage> {
  const ArtworkImage(this.service, this.request);

  final ArtworkService service;
  final ArtworkRequest request;

  @override
  Future<ArtworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<ArtworkImage>(this);

  @override
  ImageStreamCompleter loadImage(
    ArtworkImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(key, decode),
    scale: 1,
    debugLabel: key.toString(),
  );

  Future<ui.Codec> _load(ArtworkImage key, ImageDecoderCallback decode) async {
    final data = await key.service.load(key.request);
    if (data == null) {
      // A miss is what the widget's placeholder is for; the decoder is never
      // asked about bytes that are not there.
      throw StateError('no artwork available');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      Uint8List.fromList(data.bytes),
    );
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtworkImage &&
          other.service == service &&
          other.request == request;

  @override
  int get hashCode => Object.hash(service, request);

  @override
  String toString() => 'ArtworkImage(${request.scope}, ${request.sizeBucket})';
}

/// Cover art: the app's cache when it is in the tree, a network image otherwise.
///
/// Loading, missing and failed covers share a quiet neutral surface. A player
/// can retain its decoded frame until the next image arrives.
final class Artwork extends StatefulWidget {
  const Artwork({
    required this.index,
    required this.size,
    required this.radius,
    this.showIcon = false,
    this.artworkUri,
    this.retainWhileLoading = false,
    super.key,
  });

  final int index;
  final double size;
  final double radius;
  final bool showIcon;
  final Uri? artworkUri;

  /// Player artwork keeps its decoded frame until the next cover arrives.
  final bool retainWhileLoading;

  @override
  State<Artwork> createState() => _ArtworkState();
}

final class _ArtworkState extends State<Artwork> {
  ImageProvider? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _image;
  Uri? _uri;
  ArtworkService? _service;
  bool _loading = false;
  ImageStream? _fallbackStream;
  ImageStreamListener? _fallbackListener;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(Artwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final uri = widget.artworkUri;
    final service = ArtworkScope.maybeOf(context);
    final bucket = ArtworkSizeBucket.forDisplay(
      widget.size,
      MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1,
    );
    final ImageProvider? provider = uri == null || uri.toString().trim().isEmpty
        ? null
        : service == null
        ? NetworkImage(
            ArtworkService.resolveFetchUri(uri, bucket).toString(),
            headers: defaultImageHeaders,
          )
        : artworkProvider(service, uri, bucket);
    if (provider == _provider) return;
    final sameArtwork = uri == _uri && service == _service;
    _uri = uri;
    _service = service;
    _provider = provider;
    final generation = ++_generation;
    _detach();
    _loading = provider != null;
    if ((!widget.retainWhileLoading && !sameArtwork) || provider == null) {
      _replace(null);
    }
    if (provider == null) return;
    if (_image == null) {
      _reuseDecodedSize(service, uri!, bucket, generation);
    }
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted || generation != _generation) {
          info.dispose();
          return;
        }
        _detachFallback();
        setState(() {
          _loading = false;
          _replace(info);
        });
      },
      onError: (Object error, StackTrace? stack) {
        if (!mounted || generation != _generation) return;
        final keepDecodedCover = sameArtwork || _fallbackStream != null;
        _detachFallback();
        setState(() {
          _loading = false;
          if (!keepDecodedCover) _replace(null);
        });
        if (service != null && uri != null) {
          unawaited(service.discard(service.publicRequest(uri, bucket)));
        }
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  /// Reuse an already decoded thumbnail while a new display size loads. Checking
  /// the cache before resolving avoids fetching every size of the same cover.
  void _reuseDecodedSize(
    ArtworkService? service,
    Uri uri,
    ArtworkSizeBucket requested,
    int generation,
  ) {
    for (final bucket in ArtworkSizeBucket.values.reversed) {
      if (bucket == requested) continue;
      final ImageProvider provider = service == null
          ? NetworkImage(
              ArtworkService.resolveFetchUri(uri, bucket).toString(),
              headers: defaultImageHeaders,
            )
          : artworkProvider(service, uri, bucket);
      // .then preserves SynchronousFuture delivery: a cached card thumbnail
      // must be available in the detail page's first paint, without an await.
      unawaited(
        provider.obtainKey(ImageConfiguration.empty).then<void>((key) {
          if (!mounted ||
              generation != _generation ||
              !_loading ||
              _image != null) {
            return;
          }
          final status = PaintingBinding.instance.imageCache.statusForKey(key);
          if (status.pending || (!status.keepAlive && !status.live)) return;
          final stream = provider.resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener((info, _) {
            if (!mounted ||
                generation != _generation ||
                !_loading ||
                _image != null) {
              info.dispose();
              return;
            }
            setState(() => _replace(info));
          }, onError: (_, _) {});
          _fallbackStream = stream;
          _fallbackListener = listener;
          stream.addListener(listener);
        }, onError: (_, _) {}),
      );
    }
  }

  void _detachFallback() {
    final stream = _fallbackStream;
    final listener = _fallbackListener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _fallbackStream = null;
    _fallbackListener = null;
  }

  void _replace(ImageInfo? next) {
    final previous = _image;
    _image = next;
    // The previous frame can still belong to this frame's RawImage render
    // object. Release our handle only after its replacement has been painted.
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  void _detach() {
    _detachFallback();
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _generation++;
    _detach();
    _replace(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return Container(
        key: ValueKey(_loading ? 'artwork-loading' : 'artwork-placeholder'),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: AppColors.of(context).text.withValues(alpha: 0.047059),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: RawImage(
        image: image.image,
        scale: image.scale,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
      ),
    );
  }
}
