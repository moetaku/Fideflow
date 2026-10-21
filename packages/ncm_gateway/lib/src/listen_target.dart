import 'package:fideflow_domain/domain.dart';

/// Converts provider hints into one validated, mutually exclusive destination.
ListenTarget parseListenTarget(String type, String resourceId, String? url) {
  NcmKind? kind = switch (type.toUpperCase()) {
    'PLAYLIST' || 'LIST' => NcmKind.playlist,
    'ALBUM' => NcmKind.album,
    _ => null,
  };
  NcmKind? routeKind;
  String? routeId;
  try {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri != null) {
      final route = uri.fragment.startsWith('/')
          ? Uri.tryParse(uri.fragment)
          : uri;
      final segments = <String>[
        if (uri.scheme == 'orpheus') uri.host,
        ...?route?.pathSegments,
      ];
      if (segments.isNotEmpty) {
        routeKind = switch (segments.first.toLowerCase()) {
          'playlist' => NcmKind.playlist,
          'album' => NcmKind.album,
          _ => null,
        };
        routeId =
            route?.queryParameters['id'] ??
            (segments.length == 2 ? segments.last : null);
      }
    }
  } on FormatException {
    // An invalid link cannot invent a destination.
  }
  kind ??= routeKind;
  if (kind == null) return const UnknownListenTarget();
  bool valid(String? id) =>
      id != null && (BigInt.tryParse(id) ?? BigInt.zero) > BigInt.zero;
  var digits = kind.digitsOf(resourceId);
  if (!valid(digits) && routeKind == kind) {
    digits = kind.digitsOf(routeId ?? '');
  }
  if (!valid(digits)) return const UnknownListenTarget();
  return switch (kind) {
    NcmKind.playlist => PlaylistListenTarget(PlaylistId(kind.id(digits!))),
    NcmKind.album => AlbumListenTarget(AlbumId(kind.id(digits!))),
    _ => const UnknownListenTarget(),
  };
}
