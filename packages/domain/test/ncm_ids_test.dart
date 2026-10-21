import 'package:fideflow_domain/domain.dart';
import 'package:test/test.dart';

/// The one spelling of a netease id, read by both ends of it.
///
/// These are the cases the provider's parsing, the cache's canonicalisation and
/// the app's routing all stand on, so a change here is a change to every one of
/// them at once — which is the point of the shape living in one place.
void main() {
  group('digitsOf', () {
    test('reads the kind’s own prefix', () {
      expect(NcmKind.track.digitsOf('ncm-3340137263'), '3340137263');
      expect(NcmKind.playlist.digitsOf('ncm-playlist-24381616'), '24381616');
      expect(NcmKind.album.digitsOf('ncm-album-32311'), '32311');
      expect(NcmKind.artist.digitsOf('ncm-artist-11127'), '11127');
      expect(NcmKind.user.digitsOf('ncm-user-998877'), '998877');
    });

    test('reads the generic prefix as every kind', () {
      // An id is routed by this prefix before its kind is known, so a caller
      // that has not resolved the kind yet must still be readable here.
      expect(NcmKind.track.digitsOf('ncm-3340137263'), '3340137263');
      expect(NcmKind.playlist.digitsOf('ncm-24381616'), '24381616');
      expect(NcmKind.album.digitsOf('ncm-32311'), '32311');
      expect(NcmKind.artist.digitsOf('ncm-11127'), '11127');
      expect(NcmKind.user.digitsOf('ncm-998877'), '998877');
    });

    test('reads a bare numeric id', () {
      expect(NcmKind.track.digitsOf('3340137263'), '3340137263');
      expect(NcmKind.playlist.digitsOf('24381616'), '24381616');
    });

    test('refuses one kind’s word for another', () {
      // The generic prefix is readable by every kind on purpose — an id is
      // routed before its kind is known — but a kind word is not: the failure
      // this prevents is silent, because a track asked for as a playlist would
      // resolve whichever entity the service serves under that number.
      for (final kind in NcmKind.values) {
        for (final other in NcmKind.values) {
          if (other == kind || other.prefix == ncmIdPrefix) continue;
          final value = other.id('123456');
          expect(
            kind.digitsOf(value),
            isNull,
            reason: '$value is not a $kind id',
          );
        }
      }
    });

    test('refuses a tail that is not a number, and a bare word', () {
      expect(NcmKind.track.digitsOf('ncm-track-1'), isNull);
      expect(NcmKind.playlist.digitsOf('ncm-playlist-acoustic'), isNull);
      expect(NcmKind.artist.digitsOf('ncm-artist-unknown'), isNull);
      expect(NcmKind.playlist.digitsOf('playlist-local'), isNull);
      expect(NcmKind.track.digitsOf('local-9f2c1a'), isNull);
      expect(NcmKind.track.digitsOf('/Users/me/track.flac'), isNull);
      expect(NcmKind.track.digitsOf(''), isNull);
      expect(NcmKind.track.digitsOf('ncm-'), isNull);
    });

    test('judging an unmarked number is the service’s shape', () {
      // Nothing else marks an unmarked number as an id — a link's path segment
      // or a search box can hold any number — so its shape is the only claim it
      // has, and `isBareNumericId` is where that claim is read.
      expect(NcmKind.isBareNumericId('3340137263'), isTrue);
      expect(NcmKind.isBareNumericId('1234'), isTrue);
      expect(NcmKind.isBareNumericId('12345678901234567890'), isTrue);
      expect(NcmKind.isBareNumericId('123'), isFalse);
      expect(NcmKind.isBareNumericId('123456789012345678901'), isFalse);
      expect(NcmKind.isBareNumericId('ncm-1234'), isFalse);
    });

    test('length is not what makes a number an id', () {
      // The provider mints an id from whatever number the service sent back, so
      // an id it mints has to be one it reads back — and two spellings of one
      // number stay one entity however short it is.
      expect(NcmKind.track.digitsOf('ncm-123'), '123');
      expect(NcmKind.album.digitsOf('ncm-album-123'), '123');
      expect(NcmKind.track.digitsOf('1'), '1');
      expect(NcmKind.playlist.digitsOf('123'), '123');
    });
  });

  group('id', () {
    test('mints what the kind reads back', () {
      for (final kind in NcmKind.values) {
        const numeric = '3340137263';
        expect(kind.digitsOf(kind.id(numeric)), numeric);
      }
    });

    test('keeps a word the service sent, which no kind reads back', () {
      // An id to display is not an id to ask about: the shape is the provider's
      // spelling, and formatting does not invent a number for a word.
      final unknown = NcmKind.artist.id('unknown');
      expect(unknown, 'ncm-artist-unknown');
      expect(NcmKind.artist.digitsOf(unknown), isNull);
    });
  });

  group('canonical', () {
    test('one entity, whichever spelling the caller used', () {
      for (final value in ['1234', 'ncm-1234', 'ncm-playlist-1234']) {
        expect(
          NcmKind.playlist.canonical(value),
          'ncm-playlist-1234',
          reason: '$value names that playlist',
        );
      }
      expect(NcmKind.track.canonical('1234'), 'ncm-1234');
      expect(NcmKind.track.canonical('ncm-1234'), 'ncm-1234');
      expect(NcmKind.track.canonical('1'), 'ncm-1');
      expect(NcmKind.playlist.canonical('1'), 'ncm-playlist-1');
      expect(NcmKind.album.canonical('32311'), 'ncm-album-32311');
      expect(NcmKind.artist.canonical('ncm-artist-11127'), 'ncm-artist-11127');
      expect(NcmKind.user.canonical('ncm-user-998877'), 'ncm-user-998877');
    });

    test('leaves an id of another shape exactly as it was spelled', () {
      // Rewriting it would invent a provider id out of something that is not
      // one — the local library's ids and an id-import box's junk both land
      // here, and the cache has to keep them apart from the provider's.
      for (final value in [
        'playlist-local',
        'local-9f2c1a',
        '/Users/me/Music/track.flac',
        't-1',
        'ncm-track-1',
        'ncm-playlist-acoustic',
        '',
      ]) {
        for (final kind in NcmKind.values) {
          expect(
            kind.canonical(value),
            value,
            reason: '$value has no canonical $kind form',
          );
        }
      }
    });
  });
}
