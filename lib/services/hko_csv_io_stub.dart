/// Minimal dart:io stubs so archive code can compile for web (unused at runtime).

abstract class FileSystemEntity {
  String get path;
}

class File extends FileSystemEntity {
  File(this.path);
  @override
  final String path;

  Future<bool> exists() async => false;
  Future<String> readAsString() async =>
      throw UnsupportedError('File I/O unavailable on web');
  Future<List<String>> readAsLines() async =>
      throw UnsupportedError('File I/O unavailable on web');
  Future<File> writeAsString(String contents, {FileMode? mode}) async =>
      throw UnsupportedError('File I/O unavailable on web');
}

class Directory extends FileSystemEntity {
  Directory(this.path);
  @override
  final String path;

  Future<bool> exists() async => false;
  Future<Directory> create({bool recursive = false}) async =>
      throw UnsupportedError('File I/O unavailable on web');
  Stream<FileSystemEntity> list({bool recursive = false}) =>
      throw UnsupportedError('File I/O unavailable on web');
}

class FileMode {
  static const append = FileMode._();
  const FileMode._();
}

class Platform {
  static Map<String, String> get environment => const {};
  static String get pathSeparator => '/';
}
