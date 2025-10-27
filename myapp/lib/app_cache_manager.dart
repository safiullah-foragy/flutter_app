import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// A global image/file cache manager with longer retention to reduce reloads
/// when the app goes to background and resumes.
class AppCacheManager {
  static const key = 'myapp_image_cache_v1';

  static final BaseCacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 7), // consider cached valid for 7 days
      maxNrOfCacheObjects: 400, // tune as needed
      repo: JsonCacheInfoRepository(databaseName: key),
      fileService: HttpFileService(),
    ),
  );
}
