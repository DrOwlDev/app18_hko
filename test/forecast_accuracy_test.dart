import 'package:flutter_test/flutter_test.dart';

import 'package:app18_hko/services/city_timezones.dart';
import 'package:app18_hko/services/forecast_accuracy.dart';
import 'package:app18_hko/services/hko_csv_archive.dart';
import 'package:app18_hko/services/temperature_series.dart';

void main() {
  setUpAll(CityTimezones.ensureInitialized);
  test('buildAccuracyRows compares truncated buckets', () {
    const observedCsv = '''
observed_at_hkt,temperature_c,rh_pct,source
2026-09-09T06:00:00+08:00,26.2,80,hkoc.csv
2026-09-09T15:00:00+08:00,27.9,70,hkoc.csv
''';

    const forecastCsv = '''
record_type,model_time,forecast_time_hkt,temperature_c,weather_icon,daily_min_c,daily_max_c,last_modified,source
hourly,2026090900,2026-09-09T06:00:00+08:00,26.0,50,,,20260909234127,HKO.xml
hourly,2026090900,2026-09-09T15:00:00+08:00,28.0,50,,,20260909234127,HKO.xml
daily,2026090900,2026-09-09T00:00:00+08:00,,50,26.0,28.0,20260909234127,HKO.xml
''';

    final snap = parseForecastArchiveCsv(forecastCsv)!;
    final rows = buildAccuracyRows(
      targetDay: DateTime(2026, 9, 9),
      observedCsv: observedCsv,
      snapshots: [snap],
    );

    expect(rows, hasLength(1));
    expect(rows.first.actualLowBucket, 26);
    expect(rows.first.actualHighBucket, 27);
    expect(rows.first.predLowBucket, 26);
    expect(rows.first.predHighBucket, 28);
    expect(rows.first.lowHit, isTrue);
    expect(rows.first.highHit, isFalse);
  });

  test('mergeAccuracyDays covers 3 days ago through 3 days ahead', () {
    final days = mergeAccuracyDays(
      observedDays: [DateTime(2026, 9, 9)],
      nowUtc: DateTime.utc(2026, 9, 9, 16, 0), // 2026-09-10 00:00 HKT
    );
    expect(days, contains(DateTime(2026, 9, 7)));
    expect(days, contains(DateTime(2026, 9, 8)));
    expect(days, contains(DateTime(2026, 9, 9)));
    expect(days, contains(DateTime(2026, 9, 10)));
    expect(days, contains(DateTime(2026, 9, 11)));
    expect(days, contains(DateTime(2026, 9, 12)));
    expect(days, contains(DateTime(2026, 9, 13)));
  });

  test('buildArchiveChartSeries keeps forecast under observed hours', () {
    CityTimezones.ensureInitialized();
    const observedCsv = '''
observed_at_hkt,temperature_c,rh_pct,source
2026-09-10T00:00:00+08:00,28.2,80,hkoc.csv
2026-09-10T01:00:00+08:00,27.8,80,hkoc.csv
''';
    const forecastCsv = '''
record_type,model_time,forecast_time_hkt,temperature_c,weather_icon,daily_min_c,daily_max_c,last_modified,source
hourly,2026090900,2026-09-10T00:00:00+08:00,28.0,50,,,20260909234127,HKO.xml
hourly,2026090900,2026-09-10T01:00:00+08:00,27.5,50,,,20260909234127,HKO.xml
hourly,2026090900,2026-09-10T02:00:00+08:00,27.0,50,,,20260909234127,HKO.xml
''';
    final series = buildArchiveChartSeries(
      targetDay: DateTime(2026, 9, 10),
      observedCsv: observedCsv,
      forecast: parseForecastArchiveCsv(forecastCsv),
    );
    expect(series, isNotNull);
    final forecastHours = series!.points
        .where((p) => p.kind == TempPointKind.forecast)
        .map((p) => p.localHourStart.hour)
        .toSet();
    expect(forecastHours, containsAll([0, 1, 2]));
    expect(
      series.points.where((p) => p.kind == TempPointKind.observed).length,
      2,
    );
  });

  test('buildArchiveChartSeries backfills morning hours and next midnight', () {
    CityTimezones.ensureInitialized();
    const observedCsv = '''
observed_at_hkt,temperature_c,rh_pct,source
2026-09-10T12:00:00+08:00,30.0,70,hkoc.csv
''';
    const olderCsv = '''
record_type,model_time,forecast_time_hkt,temperature_c,weather_icon,daily_min_c,daily_max_c,last_modified,source
hourly,2026090912,2026-09-10T00:00:00+08:00,28.0,,,,20260910121147,HKO.xml
hourly,2026090912,2026-09-10T06:00:00+08:00,27.5,,,,20260910121147,HKO.xml
hourly,2026090912,2026-09-10T11:00:00+08:00,30.0,,,,20260910121147,HKO.xml
''';
    const newerCsv = '''
record_type,model_time,forecast_time_hkt,temperature_c,weather_icon,daily_min_c,daily_max_c,last_modified,source
hourly,2026090912,2026-09-10T11:00:00+08:00,30.1,,,,20260910181154,HKO.xml
hourly,2026090912,2026-09-10T23:00:00+08:00,27.5,,,,20260910181154,HKO.xml
hourly,2026090912,2026-09-11T00:00:00+08:00,27.1,,,,20260910181154,HKO.xml
''';
    final older = parseForecastArchiveCsv(
      olderCsv,
      snapshotId: '2026090912_20260910121147',
    )!;
    final newer = parseForecastArchiveCsv(
      newerCsv,
      snapshotId: '2026090912_20260910181154',
    )!;
    final series = buildArchiveChartSeries(
      targetDay: DateTime(2026, 9, 10),
      observedCsv: observedCsv,
      forecast: newer,
      relatedSnapshots: [older, newer],
    )!;
    final forecastPoints =
        series.points.where((p) => p.kind == TempPointKind.forecast).toList();
    final hours = forecastPoints.map((p) => p.localHourStart.hour).toSet();
    expect(hours, containsAll([0, 6, 11, 23]));
    expect(
      forecastPoints.any(
        (p) =>
            p.localHourStart.day == 11 &&
            p.localHourStart.hour == 0 &&
            (p.temperature - 27.1).abs() < 1e-9,
      ),
      isTrue,
    );
    // Newer refresh wins on overlapping hours.
    expect(
      forecastPoints
          .firstWhere((p) => p.localHourStart.hour == 11)
          .temperature,
      30.1,
    );
  });
}
