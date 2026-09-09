import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'hko_csv_archive.dart';

/// Background HKO CSV collector for Windows desktop.
class HkoDataCollector {
  HkoDataCollector({HkoCsvArchive? archive})
      : _archive = archive ?? HkoCsvArchive(rootDir: HkoCsvArchive.defaultLocalRoot());

  final HkoCsvArchive _archive;
  Timer? _obsTimer;
  Timer? _forecastTimer;
  final _statusController = StreamController<HkoArchiveStatus>.broadcast();

  Stream<HkoArchiveStatus> get statusStream => _statusController.stream;

  HkoArchiveStatus _lastStatus = const HkoArchiveStatus();

  HkoArchiveStatus get lastStatus => _lastStatus;

  void start() {
    if (kIsWeb) return;
    _obsTimer?.cancel();
    _forecastTimer?.cancel();
    unawaited(_runCollect());
    _obsTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_runCollect());
    });
    _forecastTimer = Timer.periodic(const Duration(hours: 1), (_) {
      unawaited(_runCollect());
    });
  }

  void stop() {
    _obsTimer?.cancel();
    _forecastTimer?.cancel();
    _obsTimer = null;
    _forecastTimer = null;
  }

  Future<HkoArchiveCollectResult> collectNow() => _runCollect();

  Future<HkoArchiveCollectResult> _runCollect() async {
    try {
      final result = await _archive.collect();
      _lastStatus = await _archive.readStatus();
      if (!_statusController.isClosed) {
        _statusController.add(_lastStatus);
      }
      return result;
    } catch (_) {
      return const HkoArchiveCollectResult(
        obsRowsAdded: 0,
        forecastWritten: false,
      );
    }
  }

  HkoCsvArchive get archive => _archive;

  void dispose() {
    stop();
    _statusController.close();
    _archive.close();
  }
}
