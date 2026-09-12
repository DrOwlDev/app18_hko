/// Web stub — Admin file management is desktop-only.
class AdminDataFile {
  const AdminDataFile({
    required this.path,
    required this.relativePath,
    required this.category,
    required this.bytes,
    required this.modified,
  });

  final String path;
  final String relativePath;
  final String category;
  final int bytes;
  final DateTime modified;
}

bool get adminDataFilesSupported => false;

String adminDataRootPath() => '';

Future<List<AdminDataFile>> listAdminDataFiles() async => const [];

Future<void> deleteAdminDataFiles(Iterable<String> paths) async {
  throw UnsupportedError('Admin file delete is unavailable on this platform');
}
