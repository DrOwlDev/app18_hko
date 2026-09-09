import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:app18_hko/services/city_timezones.dart';
import 'package:app18_hko/services/hko_csv_archive.dart';

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    CityTimezones.ensureInitialized();
  });

  test('parseObservedArchiveCsv reads minute samples', () {
    const csv = '''
observed_at_hkt,temperature_c,rh_pct,source
2026-09-09T14:30:00+08:00,26.5,80,hkoc.csv
2026-09-09T14:31:00+08:00,26.6,79,hkoc.csv
''';
    final samples = parseObservedArchiveCsv(csv);
    expect(samples, hasLength(2));
    expect(samples.first.tempC, 26.5);
  });

  test('parseForecastArchiveCsv reads hourly and daily rows', () {
    const csv = '''
record_type,model_time,forecast_time_hkt,temperature_c,weather_icon,daily_min_c,daily_max_c,last_modified,source
hourly,2026090900,2026-09-10T00:00:00+08:00,28.0,50,,,20260909234127,HKO.xml
daily,2026090900,2026-09-10T00:00:00+08:00,,50,26.0,32.0,20260909234127,HKO.xml
''';
    final snap = parseForecastArchiveCsv(csv);
    expect(snap?.modelTime, '2026090900');
    expect(snap?.hourly, hasLength(1));
    expect(snap?.daily, hasLength(1));
    expect(snap?.daily.first.minC, 26.0);
  });

  test('parseForecastArchiveCsv snapshotId selects chart forecast hours', () {
    const csv = '''
record_type,model_time,forecast_time_hkt,temperature_c,weather_icon,daily_min_c,daily_max_c,last_modified,source
hourly,2026090900,2026-09-10T00:00:00+08:00,28.0,50,,,20260910071145,HKO.xml
hourly,2026090900,2026-09-10T12:00:00+08:00,32.0,50,,,20260910071145,HKO.xml
''';
    final snap = parseForecastArchiveCsv(
      csv,
      snapshotId: '2026090900_20260910071145',
    );
    expect(snap?.id, '2026090900_20260910071145');
    expect(snap?.modelTime, '2026090900');
    expect(snap?.lastModified, '20260910071145');
    // Matching by modelTime alone would collide with older snapshots.
    expect(snap?.modelTime == '2026090900_20260910071145', isFalse);
  });
}
