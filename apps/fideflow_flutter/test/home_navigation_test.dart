import 'package:fideflow/presentation/navigation/home_navigation.dart';
import 'package:fideflow/presentation/navigation/routes.dart';
import 'package:flutter_test/flutter_test.dart';

NavSnapshot entry(
  String id, {
  String? route,
  String? source,
  bool private = false,
}) => NavSnapshot(
  entryId: id,
  sourceEntryId: source,
  destinationId: NavigationIds.playlistSquare,
  detailRouteId: route,
  access: private ? RouteAccess.account : RouteAccess.public,
);

void main() {
  test('tabs replace the root; detail routes pop one level at a time', () {
    final nav = HomeNavigation()..push(entry('root'));
    nav.push(
      const NavSnapshot(
        entryId: 'library',
        destinationId: NavigationIds.library,
        access: RouteAccess.public,
      ),
    );
    expect(nav.stack.map((e) => e.entryId), ['library']);
    expect(nav.canPop, isFalse);
    nav.push(entry('album', route: 'detail.album:1', source: 'library'));
    nav.push(entry('artist', route: 'detail.artist:2', source: 'album'));
    expect(nav.pop()?.entryId, 'album');
    expect(nav.pop()?.entryId, 'library');
    expect(nav.pop(), isNull);
    expect(nav.history.current?.entryId, 'library');
  });

  test('search reuses its page and restores query after visiting details', () {
    final nav = HomeNavigation()..push(entry('root'));
    nav.search('a', 'search');
    nav.search('album', 'unused');
    expect(nav.stack.length, 2);
    expect(nav.stack.last.entryId, 'search');
    expect(nav.history.entries.length, 2);
    nav.push(entry('detail', route: 'detail.album:1', source: 'search'));
    expect(nav.pop()?.committedQuery, 'album');
    expect(nav.detail, DetailRouteIds.search);
    expect(nav.draftQuery, 'album');
    nav.search('', 'unused');
    expect(nav.stack.single.entryId, 'root');
    expect(nav.draftQuery, isEmpty);
  });

  test(
    'late native removal cannot pop a different page or a reset account',
    () {
      final nav = HomeNavigation()..push(entry('root'));
      nav.push(entry('a', route: 'detail.album:1'));
      nav.push(entry('b', route: 'detail.artist:2'));
      expect(nav.didRemove('a'), isNull);
      expect(nav.stack.length, 3);
      nav.detail = null;
      nav.resetAccountRoutes('new-root');
      expect(nav.didRemove('b'), isNull);
      expect(nav.stack.single.entryId, 'new-root');
    },
  );

  test('duplicate destination does not create duplicate detail pages', () {
    final nav = HomeNavigation()..push(entry('root'));
    nav.push(entry('a', route: 'detail.album:1'));
    nav.push(entry('b', route: 'detail.album:1'));
    expect(nav.stack.length, 2);
  });

  test('deletion removes active and underlying occurrences', () {
    final nav = HomeNavigation()..push(entry('root'));
    nav.push(entry('a', route: 'detail.playlist:1'));
    nav.push(entry('b', route: 'detail.album:2'));
    nav.push(entry('c', route: 'detail.playlist:1'));
    nav.removePlaylist('detail.playlist:1');
    expect(nav.stack.map((e) => e.entryId), ['root', 'b']);
    expect(nav.detail, 'detail.album:2');
  });

  test('desktop history restore reconstructs the source chain', () {
    final nav = HomeNavigation()..push(entry('root'));
    final album = entry('album', route: 'detail.album:1', source: 'root');
    nav.push(album);
    nav.push(entry('artist', route: 'detail.artist:2', source: 'album'));
    nav.restore(album);
    expect(nav.stack.map((e) => e.entryId), ['root', 'album']);
    nav.restore(nav.history.entries.last);
    expect(nav.stack.map((e) => e.entryId), ['root', 'album', 'artist']);
  });
}
