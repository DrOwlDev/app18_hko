import 'package:timezone/timezone.dart' as tz;

enum TempPointKind { observed, forecast }

class HourlyTempPoint {
  const HourlyTempPoint({
    required this.localHourStart,
    required this.temperature,
    required this.kind,
    this.dataSource = '',
    this.isDailyMinimum = false,
    this.isDailyMaximum = false,
    this.weatherIconCode,
  });

  final tz.TZDateTime localHourStart;
  final double temperature;
  final TempPointKind kind;
  final String dataSource;
  final bool isDailyMinimum;
  final bool isDailyMaximum;
  final int? weatherIconCode;

  HourlyTempPoint copyWith({
    String? dataSource,
    bool? isDailyMinimum,
    bool? isDailyMaximum,
    int? weatherIconCode,
  }) {
    return HourlyTempPoint(
      localHourStart: localHourStart,
      temperature: temperature,
      kind: kind,
      dataSource: dataSource ?? this.dataSource,
      isDailyMinimum: isDailyMinimum ?? this.isDailyMinimum,
      isDailyMaximum: isDailyMaximum ?? this.isDailyMaximum,
      weatherIconCode: weatherIconCode ?? this.weatherIconCode,
    );
  }

  Map<String, dynamic> toJson() => {
        't': localHourStart.toUtc().toIso8601String(),
        'temp': temperature,
        'kind': kind == TempPointKind.observed ? 'observed' : 'forecast',
        if (dataSource.isNotEmpty) 'dataSource': dataSource,
        if (isDailyMinimum) 'isDailyMinimum': true,
        if (isDailyMaximum) 'isDailyMaximum': true,
        if (weatherIconCode != null) 'weatherIconCode': weatherIconCode,
      };

  factory HourlyTempPoint.fromJson(
    Map<String, dynamic> json, {
    required tz.Location location,
  }) {
    final kindRaw = json['kind']?.toString() ?? 'forecast';
    final iconRaw = json['weatherIconCode'];
    int? iconCode;
    if (iconRaw is num) {
      iconCode = iconRaw.toInt();
    } else if (iconRaw != null) {
      iconCode = int.tryParse(iconRaw.toString());
    }
    return HourlyTempPoint(
      localHourStart: _tzFromUtcIso(json['t']?.toString(), location),
      temperature: (json['temp'] as num?)?.toDouble() ?? 0,
      kind: kindRaw == 'observed'
          ? TempPointKind.observed
          : TempPointKind.forecast,
      dataSource: json['dataSource']?.toString() ?? '',
      isDailyMinimum: json['isDailyMinimum'] == true,
      isDailyMaximum: json['isDailyMaximum'] == true,
      weatherIconCode: iconCode,
    );
  }
}

class DailyTemperatureSeries {
  const DailyTemperatureSeries({
    required this.siteId,
    required this.unit,
    required this.dayStart,
    required this.dayEnd,
    required this.nowLocal,
    required this.points,
    this.latestObservation,
    this.forecastModelTime,
    this.forecastRetrievedAtUtc,
  });

  final String siteId;
  final String unit;
  final tz.TZDateTime dayStart;
  final tz.TZDateTime dayEnd;
  final tz.TZDateTime nowLocal;
  final List<HourlyTempPoint> points;
  final LatestStationObservation? latestObservation;

  /// HKO OCF `ModelTime` (e.g. `2026091000`) for the forecast used in this series.
  final String? forecastModelTime;

  /// When this app last successfully fetched the OCF forecast from HKO (UTC).
  final DateTime? forecastRetrievedAtUtc;

  Map<String, dynamic> toJson() => {
        'siteId': siteId,
        'unit': unit,
        'timeZone': dayStart.location.name,
        'dayStart': dayStart.toUtc().toIso8601String(),
        'dayEnd': dayEnd.toUtc().toIso8601String(),
        'nowLocal': nowLocal.toUtc().toIso8601String(),
        'points': points.map((p) => p.toJson()).toList(),
        if (latestObservation != null)
          'latestObservation': latestObservation!.toJson(),
        if (forecastModelTime != null && forecastModelTime!.isNotEmpty)
          'forecastModelTime': forecastModelTime,
        if (forecastRetrievedAtUtc != null)
          'forecastRetrievedAtUtc':
              forecastRetrievedAtUtc!.toUtc().toIso8601String(),
      };

  factory DailyTemperatureSeries.fromJson(Map<String, dynamic> json) {
    final tzName = json['timeZone']?.toString() ?? 'UTC';
    late final tz.Location location;
    try {
      location = tz.getLocation(tzName);
    } catch (_) {
      location = tz.UTC;
    }
    final pointsRaw = json['points'];
    final points = <HourlyTempPoint>[];
    if (pointsRaw is List) {
      for (final item in pointsRaw) {
        if (item is Map<String, dynamic>) {
          points.add(HourlyTempPoint.fromJson(item, location: location));
        } else if (item is Map) {
          points.add(
            HourlyTempPoint.fromJson(
              Map<String, dynamic>.from(item),
              location: location,
            ),
          );
        }
      }
    }
    LatestStationObservation? latest;
    final latestRaw = json['latestObservation'];
    if (latestRaw is Map<String, dynamic>) {
      latest = LatestStationObservation.fromJson(latestRaw, location: location);
    } else if (latestRaw is Map) {
      latest = LatestStationObservation.fromJson(
        Map<String, dynamic>.from(latestRaw),
        location: location,
      );
    }
    final retrievedRaw = json['forecastRetrievedAtUtc']?.toString();
    final retrievedAt = retrievedRaw == null || retrievedRaw.isEmpty
        ? null
        : DateTime.tryParse(retrievedRaw)?.toUtc();
    return DailyTemperatureSeries(
      siteId: json['siteId']?.toString() ?? '',
      unit: json['unit']?.toString() == 'F' ? 'F' : 'C',
      dayStart: _tzFromUtcIso(json['dayStart']?.toString(), location),
      dayEnd: _tzFromUtcIso(json['dayEnd']?.toString(), location),
      nowLocal: _tzFromUtcIso(json['nowLocal']?.toString(), location),
      points: points,
      latestObservation: latest,
      forecastModelTime: json['forecastModelTime']?.toString(),
      forecastRetrievedAtUtc: retrievedAt,
    );
  }
}

class LatestStationObservation {
  const LatestStationObservation({
    required this.temperature,
    required this.observedAtLocal,
  });

  final double temperature;
  final tz.TZDateTime observedAtLocal;

  Map<String, dynamic> toJson() => {
        'temp': temperature,
        't': observedAtLocal.toUtc().toIso8601String(),
      };

  factory LatestStationObservation.fromJson(
    Map<String, dynamic> json, {
    required tz.Location location,
  }) {
    return LatestStationObservation(
      temperature: (json['temp'] as num?)?.toDouble() ?? 0,
      observedAtLocal: _tzFromUtcIso(json['t']?.toString(), location),
    );
  }
}

tz.TZDateTime _tzFromUtcIso(String? iso, tz.Location location) {
  final parsed = DateTime.tryParse(iso ?? '');
  if (parsed == null) {
    return tz.TZDateTime.fromMillisecondsSinceEpoch(location, 0);
  }
  return tz.TZDateTime.from(parsed.toUtc(), location);
}

Map<int, double> indexMetarObservations({
  required tz.Location location,
  required tz.TZDateTime dayStart,
  required tz.TZDateTime dayEnd,
  required List<({DateTime utc, double tempC})> samples,
}) {
  final sorted = [...samples]
    ..sort((a, b) => a.utc.toUtc().compareTo(b.utc.toUtc()));
  final out = <int, double>{};
  for (final sample in sorted) {
    final local = tz.TZDateTime.from(sample.utc.toUtc(), location);
    final atMinute = tz.TZDateTime(
      location,
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
    if (atMinute.isBefore(dayStart) || atMinute.isAfter(dayEnd)) continue;
    out[atMinute.millisecondsSinceEpoch] = sample.tempC;
  }
  return out;
}

double celsiusToFahrenheit(double c) => c * 9 / 5 + 32;

double convertTempC(double tempC, String unit) =>
    unit == 'F' ? celsiusToFahrenheit(tempC) : tempC;

const defaultObservedDataSource = 'https://www.weather.gov.hk';
const defaultForecastDataSource = 'maps.weather.gov.hk/ocf';

List<HourlyTempPoint> mergeHourlySeries({
  required tz.TZDateTime dayStart,
  required tz.TZDateTime dayEnd,
  required tz.TZDateTime nowLocal,
  required Map<int, double> observedC,
  required Map<int, double> forecastC,
  required String unit,
  String observedDataSource = defaultObservedDataSource,
  String forecastDataSource = defaultForecastDataSource,
  Map<int, int>? forecastWeatherCodes,
}) {
  final location = dayStart.location;
  final points = <HourlyTempPoint>[];

  bool hasObsInHour(tz.TZDateTime hourStart) {
    final hourEnd = hourStart.add(const Duration(hours: 1));
    for (final key in observedC.keys) {
      final t = tz.TZDateTime.fromMillisecondsSinceEpoch(location, key);
      if (!t.isBefore(hourStart) && t.isBefore(hourEnd)) return true;
    }
    return false;
  }

  final obsKeys = observedC.keys.toList()..sort();
  for (final key in obsKeys) {
    final t = tz.TZDateTime.fromMillisecondsSinceEpoch(location, key);
    if (t.isBefore(dayStart) || t.isAfter(dayEnd)) continue;
    if (t.isAfter(nowLocal)) continue;
    points.add(
      HourlyTempPoint(
        localHourStart: t,
        temperature: convertTempC(observedC[key]!, unit),
        kind: TempPointKind.observed,
        dataSource: observedDataSource,
      ),
    );
  }

  var hour = dayStart;
  while (!hour.isAfter(dayEnd)) {
    final key = hour.millisecondsSinceEpoch;
    final fc = forecastC[key];
    final hourEnd = hour.add(const Duration(hours: 1));
    if (fc != null) {
      final containsNow =
          !nowLocal.isBefore(hour) && nowLocal.isBefore(hourEnd);
      final fullyFuture = !hour.isBefore(nowLocal);
      if (fullyFuture || (containsNow && !hasObsInHour(hour))) {
        final alreadyObs = observedC.containsKey(key) &&
            !tz.TZDateTime.fromMillisecondsSinceEpoch(location, key)
                .isAfter(nowLocal);
        if (!alreadyObs) {
          points.add(
            HourlyTempPoint(
              localHourStart: hour,
              temperature: convertTempC(fc, unit),
              kind: TempPointKind.forecast,
              dataSource: forecastDataSource,
              weatherIconCode: forecastWeatherCodes?[key],
            ),
          );
        }
      }
    }
    hour = hourEnd;
  }

  points.sort(
    (a, b) => a.localHourStart.millisecondsSinceEpoch
        .compareTo(b.localHourStart.millisecondsSinceEpoch),
  );
  return markDailyExtremes(points, dayEnd);
}

/// Overlay merge for forecast-accuracy charts: keep **all** forecast hours for
/// the day even where observations exist, so yellow vs black can be compared.
List<HourlyTempPoint> mergeObservedForecastOverlay({
  required tz.TZDateTime dayStart,
  required tz.TZDateTime dayEnd,
  required Map<int, double> observedC,
  required Map<int, double> forecastC,
  required String unit,
  String observedDataSource = defaultObservedDataSource,
  String forecastDataSource = defaultForecastDataSource,
  Map<int, int>? forecastWeatherCodes,
}) {
  final location = dayStart.location;
  final points = <HourlyTempPoint>[];

  final obsKeys = observedC.keys.toList()..sort();
  for (final key in obsKeys) {
    final t = tz.TZDateTime.fromMillisecondsSinceEpoch(location, key);
    if (t.isBefore(dayStart) || t.isAfter(dayEnd)) continue;
    points.add(
      HourlyTempPoint(
        localHourStart: t,
        temperature: convertTempC(observedC[key]!, unit),
        kind: TempPointKind.observed,
        dataSource: observedDataSource,
      ),
    );
  }

  var hour = dayStart;
  while (!hour.isAfter(dayEnd)) {
    final key = hour.millisecondsSinceEpoch;
    final fc = forecastC[key];
    if (fc != null) {
      points.add(
        HourlyTempPoint(
          localHourStart: hour,
          temperature: convertTempC(fc, unit),
          kind: TempPointKind.forecast,
          dataSource: forecastDataSource,
          weatherIconCode: forecastWeatherCodes?[key],
        ),
      );
    }
    hour = hour.add(const Duration(hours: 1));
  }

  points.sort(
    (a, b) => a.localHourStart.millisecondsSinceEpoch
        .compareTo(b.localHourStart.millisecondsSinceEpoch),
  );

  // Extremes from observed when available; otherwise forecast (future-only days).
  final dayPoints =
      points.where((p) => p.localHourStart.isBefore(dayEnd)).toList();
  final obsDay =
      dayPoints.where((p) => p.kind == TempPointKind.observed).toList();
  final basis = obsDay.isNotEmpty ? obsDay : dayPoints;
  return _markSingleDailyExtremes(points, basis);
}

List<HourlyTempPoint> markDailyExtremes(
  List<HourlyTempPoint> points,
  tz.TZDateTime dayEnd,
) {
  final dayPoints =
      points.where((p) => p.localHourStart.isBefore(dayEnd)).toList();
  return _markSingleDailyExtremes(points, dayPoints);
}

/// Marks exactly one daily min and one daily max (first occurrence each).
/// Minute-level series often plateaus; flagging every equal temp would paint
/// a solid blob of star markers on the chart.
List<HourlyTempPoint> _markSingleDailyExtremes(
  List<HourlyTempPoint> points,
  List<HourlyTempPoint> basis,
) {
  if (basis.isEmpty) return points;
  final minTemp =
      basis.map((p) => p.temperature).reduce((a, b) => a < b ? a : b);
  final maxTemp =
      basis.map((p) => p.temperature).reduce((a, b) => a > b ? a : b);
  HourlyTempPoint? minPoint;
  HourlyTempPoint? maxPoint;
  for (final p in basis) {
    if (minPoint == null && (p.temperature - minTemp).abs() < 1e-9) {
      minPoint = p;
    }
    if (maxPoint == null && (p.temperature - maxTemp).abs() < 1e-9) {
      maxPoint = p;
    }
    if (minPoint != null && maxPoint != null) break;
  }
  return [
    for (final p in points)
      p.copyWith(
        isDailyMinimum: identical(p, minPoint),
        isDailyMaximum: identical(p, maxPoint),
      ),
  ];
}
