/// Stub for platforms without `dart:io` (web).
bool get isWindowsDesktop => false;

Future<bool> openUrlInFirefox(String url) async => false;
