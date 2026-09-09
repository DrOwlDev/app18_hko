import 'package:app18_hko/models/temp_outcome_bucket.dart';
import 'package:timezone/timezone.dart' as tz;

import 'city_timezones.dart';
import 'hko_csv_archive.dart';
import 'temperature_series.dart';

/// HKT calendar days from [pastDays] ago through [nextDays] ahead (inclusive).
List<DateTime> hktDayWindow({
  int pastDays = 3,
  int nextDays = 3,
  DateTime? nowUtc,
}) {
  final loc = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
  final now = tz.TZDateTime.from((nowUtc ?? DateTime.now()).toUtc(), loc);
  final today = tz.TZDateTime(loc, now.year, now.month, now.day);
  return [
    for (var i = -pastDays; i <= nextDays; i++)
      () {
        final d = today.add(Duration(days: i));
        return DateTime(d.year, d.month, d.day);
      }(),
  ];
}

/// Today in HKT plus the next [nextDays] calendar days (forecast horizon).
List<DateTime> hktTodayAndNextDays({
  int nextDays = 3,
  DateTime? nowUtc,
}) =>
    hktDayWindow(pastDays: 0, nextDays: nextDays, nowUtc: nowUtc);

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Observed archive days plus HKT window from [pastDays] ago to [nextDays] ahead.
List<DateTime> mergeAccuracyDays({
  required List<DateTime> observedDays,
  int pastDays = 3,
  int nextDays = 3,
  DateTime? nowUtc,
}) {
  final byKey = <String, DateTime>{};
  for (final d in observedDays) {
    final n = _dateOnly(d);
    byKey[_dayKey(n)] = n;
  }
  for (final d in hktDayWindow(
    pastDays: pastDays,
    nextDays: nextDays,
    nowUtc: nowUtc,
  )) {
    byKey[_dayKey(d)] = d;
  }
  final days = byKey.values.toList()..sort((a, b) => a.compareTo(b));
  return days;
}

bool bucketContainsTemp(TempOutcomeBucket bucket, double tempC) {
  final b = settlementBucket(tempC);
  switch (bucket.kind) {
    case TempBucketKind.exact:
      return bucket.exact != null && settlementBucket(bucket.exact!) == b;
    case TempBucketKind.orBelow:
      return bucket.exact != null && b <= settlementBucket(bucket.exact!);
    case TempBucketKind.orAbove:
      return bucket.exact != null && b >= settlementBucket(bucket.exact!);
    case TempBucketKind.range:
      if (bucket.lo == null || bucket.hi == null) return false;
      return b >= settlementBucket(bucket.lo!) &&
          b <= settlementBucket(bucket.hi!);
  }
}

class DayAccuracyRow {
  const DayAccuracyRow({
    required this.modelTime,
    required this.forecastMinC,
    required this.forecastMaxC,
    required this.predLowBucket,
    required this.predHighBucket,
    required this.actualLowC,
    required this.actualHighC,
    required this.actualLowBucket,
    required this.actualHighBucket,
    required this.lowHit,
    required this.highHit,
  });

  final String modelTime;
  final double? forecastMinC;
  final double? forecastMaxC;
  final int? predLowBucket;
  final int? predHighBucket;
  final double? actualLowC;
  final double? actualHighC;
  final int? actualLowBucket;
  final int? actualHighBucket;
  final bool lowHit;
  final bool highHit;
}

double? minTempC(Iterable<double> temps) {
  double? min;
  for (final t in temps) {
    if (min == null || t < min) min = t;
  }
  return min;
}

double? maxTempC(Iterable<double> temps) {
  double? max;
  for (final t in temps) {
    if (max == null || t > max) max = t;
  }
  return max;
}

bool _sameHktDay(DateTime a, DateTime targetDay) =>
    a.year == targetDay.year &&
    a.month == targetDay.month &&
    a.day == targetDay.day;

/// Hourly forecast min/max for [targetDay] (local HKT calendar day).
({double? minC, double? maxC}) forecastHourlyExtremaForDay(
  ForecastArchiveSnapshot snapshot,
  DateTime targetDay,
) {
  final temps = snapshot.hourly
      .where((h) => _sameHktDay(h.hourHkt, targetDay))
      .map((h) => h.tempC);
  return (minC: minTempC(temps), maxC: maxTempC(temps));
}

/// Observed min/max from archive CSV for a calendar day.
({double? minC, double? maxC}) observedExtremaForDay(String observedCsv) {
  final samples = parseObservedArchiveCsv(observedCsv);
  if (samples.isEmpty) return (minC: null, maxC: null);
  final temps = samples.map((s) => s.tempC);
  return (minC: minTempC(temps), maxC: maxTempC(temps));
}

List<DayAccuracyRow> buildAccuracyRows({
  required DateTime targetDay,
  required String observedCsv,
  required List<ForecastArchiveSnapshot> snapshots,
}) {
  final obs = observedExtremaForDay(observedCsv);
  final actualLowBucket =
      obs.minC == null ? null : settlementBucket(obs.minC!);
  final actualHighBucket =
      obs.maxC == null ? null : settlementBucket(obs.maxC!);

  return [
    for (final snap in snapshots)
      _rowForSnapshot(
        snap,
        targetDay,
        obs.minC,
        obs.maxC,
        actualLowBucket,
        actualHighBucket,
      ),
  ];
}

DayAccuracyRow _rowForSnapshot(
  ForecastArchiveSnapshot snap,
  DateTime targetDay,
  double? actualLowC,
  double? actualHighC,
  int? actualLowBucket,
  int? actualHighBucket,
) {
  final fc = forecastHourlyExtremaForDay(snap, targetDay);
  var predMin = fc.minC;
  var predMax = fc.maxC;

  // Prefer OCF daily min/max when present for the target day.
  for (final d in snap.daily) {
    if (_sameHktDay(d.dateHkt, targetDay)) {
      predMin ??= d.minC;
      predMax ??= d.maxC;
    }
  }

  final predLowBucket = predMin == null ? null : settlementBucket(predMin);
  final predHighBucket = predMax == null ? null : settlementBucket(predMax);

  return DayAccuracyRow(
    modelTime: snap.modelTime,
    forecastMinC: predMin,
    forecastMaxC: predMax,
    predLowBucket: predLowBucket,
    predHighBucket: predHighBucket,
    actualLowC: actualLowC,
    actualHighC: actualHighC,
    actualLowBucket: actualLowBucket,
    actualHighBucket: actualHighBucket,
    lowHit: actualLowBucket != null &&
        predLowBucket != null &&
        actualLowBucket == predLowBucket,
    highHit: actualHighBucket != null &&
        predHighBucket != null &&
        actualHighBucket == predHighBucket,
  );
}

/// Build a chart series from archived observed + one forecast snapshot.
DailyTemperatureSeries? buildArchiveChartSeries({
  required DateTime targetDay,
  required String observedCsv,
  required ForecastArchiveSnapshot? forecast,
  tz.Location? location,
}) {
  final loc = location ?? tz.getLocation('Asia/Hong_Kong');
  final dayStart = tz.TZDateTime(loc, targetDay.year, targetDay.month, targetDay.day);
  final dayEnd = dayStart.add(const Duration(days: 1));
  final nowLocal = tz.TZDateTime.from(DateTime.now().toUtc(), loc);

  final observedC = <int, double>{};
  for (final s in parseObservedArchiveCsv(observedCsv)) {
    final local = tz.TZDateTime(
      loc,
      s.local.year,
      s.local.month,
      s.local.day,
      s.local.hour,
      s.local.minute,
    );
    if (local.isBefore(dayStart) || local.isAfter(dayEnd)) continue;
    observedC[local.millisecondsSinceEpoch] = s.tempC;
  }

  final forecastC = <int, double>{};
  final weatherCodes = <int, int>{};
  if (forecast != null) {
    for (final h in forecast.hourly) {
      if (h.hourHkt.year != targetDay.year ||
          h.hourHkt.month != targetDay.month ||
          h.hourHkt.day != targetDay.day) {
        continue;
      }
      final hourStart = tz.TZDateTime(
        loc,
        h.hourHkt.year,
        h.hourHkt.month,
        h.hourHkt.day,
        h.hourHkt.hour,
      );
      forecastC[hourStart.millisecondsSinceEpoch] = h.tempC;
      if (h.weatherIcon != null) {
        weatherCodes[hourStart.millisecondsSinceEpoch] = h.weatherIcon!;
      }
    }
  }

  if (observedC.isEmpty && forecastC.isEmpty) return null;

  final points = mergeObservedForecastOverlay(
    dayStart: dayStart,
    dayEnd: dayEnd,
    observedC: observedC,
    forecastC: forecastC,
    unit: 'C',
    forecastWeatherCodes: weatherCodes.isEmpty ? null : weatherCodes,
  );

  return DailyTemperatureSeries(
    siteId: 'HKO',
    unit: 'C',
    dayStart: dayStart,
    dayEnd: dayEnd,
    nowLocal: nowLocal.isBefore(dayEnd) ? nowLocal : dayEnd,
    points: points,
    forecastModelTime: forecast?.modelTime,
  );
}
