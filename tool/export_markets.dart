import 'dart:convert';
import 'dart:io';

import 'package:app18_hko/models/market_event.dart';
import 'package:app18_hko/services/city_timezones.dart';
import 'package:app18_hko/services/hko_temperature_api.dart';
import 'package:app18_hko/services/polymarket_api.dart';

/// Fetches live Hong Kong Polymarket markets (+ CLOB asks) and writes
/// `web/data/markets.json` for GitHub Pages.
///
/// Preloads HKO temperature series so expand charts work without CORS.
Future<void> main(List<String> args) async {
  CityTimezones.ensureInitialized();

  final outPath = args.isNotEmpty ? args.first : 'web/data/markets.json';
  final api = PolymarketApi(preferStaticSnapshot: false);
  final hkoApi = HkoTemperatureApi();

  stdout.writeln('Fetching Hong Kong low + high temperature events…');
  var events = await api.fetchTemperatureEvents();
  stdout.writeln('Enriching CLOB Buy Yes/No for ${events.length} events…');
  events = await api.enrichEventsBuyPrices(events);
  api.close();

  stdout.writeln('Preloading HKO temperature series…');
  events = await _attachHkoSeries(events, hkoApi);
  hkoApi.close();

  final withSeries =
      events.where((e) => e.temperatureSeries != null).length;
  final payload = {
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'eventCount': events.length,
    'temperatureSeriesCount': withSeries,
    'events': events.map((e) => e.toSnapshotJson()).toList(),
  };

  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
  stdout.writeln(
    'Wrote ${events.length} events ($withSeries with temp charts) to $outPath '
    '(${file.lengthSync()} bytes)',
  );
}

Future<List<MarketEvent>> _attachHkoSeries(
  List<MarketEvent> events,
  HkoTemperatureApi hkoApi,
) async {
  final cache = <String, Future<dynamic>>{};
  const concurrency = 4;
  var next = 0;
  final results = List<MarketEvent>.from(events);

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= events.length) return;
      final event = events[i];
      final day = event.observationDayInCity;
      if (day == null || !isChartableTemperatureSource(event)) continue;

      final unit = event.temperatureUnit ?? 'C';
      final observedSource =
          event.resolutionSourceUrl ?? event.resolutionSourceOpenUrl;
      final key = 'HKO|${day.year}-${day.month}-${day.day}|$unit';

      final seriesFuture = cache.putIfAbsent(key, () async {
        try {
          final series = await hkoApi.fetchDailySeries(
            year: day.year,
            month: day.month,
            day: day.day,
            unit: unit,
            observedDataSource: observedSource,
          );
          stdout.writeln(
            '  ✓ $key (${series.points.length} points)',
          );
          return series;
        } catch (e) {
          stdout.writeln('  ✗ $key: $e');
          return null;
        }
      });

      final series = await seriesFuture;
      if (series != null) {
        results[i] = event.copyWith(temperatureSeries: series);
      }
    }
  }

  await Future.wait([
    for (var w = 0; w < concurrency; w++) worker(),
  ]);
  return results;
}
