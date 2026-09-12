import 'dart:io';

import 'hko_csv_archive.dart';

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

bool get adminDataFilesSupported => true;

String adminDataRootPath() => HkoCsvArchive.defaultLocalRoot().path;

Future<List<AdminDataFile>> listAdminDataFiles() async {
  final root = HkoCsvArchive.defaultLocalRoot();
  if (!await root.exists()) return const [];

  final out = <AdminDataFile>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = entity.path
        .substring(root.path.length)
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^/+'), '');
    if (relative.isEmpty) continue;
    final slash = relative.indexOf('/');
    final category = slash < 0 ? 'root' : relative.substring(0, slash);
    final stat = await entity.stat();
    out.add(
      AdminDataFile(
        path: entity.path,
        relativePath: relative,
        category: category,
        bytes: stat.size,
        modified: stat.modified.toLocal(),
      ),
    );
  }

  out.sort((a, b) {
    final c = a.category.compareTo(b.category);
    if (c != 0) return c;
    return b.modified.compareTo(a.modified);
  });
  return out;
}

Future<void> deleteAdminDataFiles(Iterable<String> paths) async {
  for (final path in paths) {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
