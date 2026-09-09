import 'dart:io';

bool get isWindowsDesktop => Platform.isWindows;

/// Opens [url] in Mozilla Firefox on Windows (PATH or common install dirs).
Future<bool> openUrlInFirefox(String url) async {
  if (!Platform.isWindows) return false;
  final candidates = <String>[
    'firefox',
    r'C:\Program Files\Mozilla Firefox\firefox.exe',
    r'C:\Program Files (x86)\Mozilla Firefox\firefox.exe',
  ];
  for (final exe in candidates) {
    try {
      await Process.start(
        exe,
        [url],
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      // Try next candidate.
    }
  }
  return false;
}
