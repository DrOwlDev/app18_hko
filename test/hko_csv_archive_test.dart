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

  test('readLastModelTime returns null when missing', () async {
    final dir = await Directory.systemTemp.createTemp('hko_archive_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final archive = HkoCsvArchive(rootDir: dir);
    expect(await archive.readLastModelTime(), isNull);
    await archive.writeLastModelTime('2026090900');
    expect(await archive.readLastModelTime(), '2026090900');
    archive.close();
  });
}
