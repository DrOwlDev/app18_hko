/// Minimal dart:io stubs so archive code can compile for web (unused at runtime).

class File {
  File(this.path);
  final String path;

  Future<bool> exists() async => false;
  Future<String> readAsString() async =>
      throw UnsupportedError('File I/O unavailable on web');
  Future<List<String>> readAsLines() async =>
      throw UnsupportedError('File I/O unavailable on web');
  Future<File> writeAsString(String contents, {FileMode? mode}) async =>
      throw UnsupportedError('File I/O unavailable on web');
}

class Directory {
  Directory(this.path);
  final String path;

  Future<bool> exists() async => false;
  Future<Directory> create({bool recursive = false}) async =>
      throw UnsupportedError('File I/O unavailable on web');
  Stream<FileSystemEntity> list({bool recursive = false}) =>
      throw UnsupportedError('File I/O unavailable on web');
}

abstract class FileSystemEntity {
  String get path;
}

class FileMode {
  static const append = FileMode._();
  const FileMode._();
}

class Platform {
  static Map<String, String> get environment => const {};
  static String get pathSeparator => '/';
}
