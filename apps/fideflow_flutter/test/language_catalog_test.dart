import 'package:fideflow/app/language.dart';
import 'package:fideflow/features/discovery/playlist_square_page.dart';
import 'package:fideflow/l10n/app_localizations.dart';
import 'package:fideflow_application/application.dart';
import 'package:fideflow_domain/domain.dart';
import 'package:fideflow_ncm_gateway/ncm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingCatalog implements PlaylistSquareRepository {
  final catalog = FakeCatalogRepository(latency: Duration.zero);
  final categories = <String>[];
  @override
  Future<PlaylistCategoryTree> getCategoryTree({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => catalog.getCategoryTree(policy: policy);
  @override
  Future<List<PlaylistTag>> getHotTags({
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) => catalog.getHotTags(policy: policy);
  @override
  Future<HighQualityPlaylist?> getHighQualityPlaylist(
    String cat, {
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async => null;
  @override
  Future<SearchResult<PlaylistSummary>> getSquarePlaylists({
    required String cat,
    PlaylistOrder order = PlaylistOrder.hot,
    int limit = 30,
    int offset = 0,
    RefreshPolicy policy = RefreshPolicy.cacheFirst,
  }) async {
    categories.add(cat);
    return const SearchResult(items: [], hasMore: false);
  }
}

void main() {
  for (final locale in [const Locale('en'), simplifiedChineseLocale]) {
    testWidgets(
      'category labels and request parameters remain original in $locale',
      (tester) async {
        final catalog = RecordingCatalog();
        final controller = PlaylistSquareController(repository: catalog);
        addTearDown(controller.dispose);
        await tester.runAsync(controller.loadInitial);
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: PlaylistSquarePage(
                controller: controller,
                onOpenPlaylist: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('全部'), findsOneWidget);
        expect(find.text('官方'), findsOneWidget);
        expect(find.text('华语'), findsOneWidget);
        expect(find.text('流行'), findsOneWidget);
        expect(find.text('All'), findsNothing);
        await tester.tap(find.text('华语'));
        await tester.pumpAndSettle();
        expect(controller.state.selectedCategory, '华语');
        expect(catalog.categories.first, '全部');
        expect(catalog.categories.last, '华语');
      },
    );
  }
}
