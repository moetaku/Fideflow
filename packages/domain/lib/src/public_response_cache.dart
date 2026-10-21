/// Persistent public responses. Implementations treat unavailable storage as a miss.
abstract interface class PublicResponseCacheStore {
  Future<PublicResponseCacheEntry?> read(String key);
  Future<void> write(String key, PublicResponseCacheEntry entry);
}

final class PublicResponseCacheEntry {
  const PublicResponseCacheEntry({required this.fetchedAt, required this.body});
  final DateTime fetchedAt;
  final Map<String, Object?> body;
}
