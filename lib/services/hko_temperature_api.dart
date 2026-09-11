import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

import 'city_timezones.dart';
import 'hko_weather_icons.dart';
import 'temperature_series.dart';

/// Fetches HKO observed (hkoc.csv) + OCF forecast for Hong Kong markets.
class HkoTemperatureApi {
  HkoTemperatureApi({http.Client? client})
      : _client = client ?? http.Client();

  static const stationId = 'HKO';
  static const observedStationName = 'HK Observatory';
  static const regionalPortalUrl =
      'https://www.hko.gov.hk/en/wxinfo/awsgis/regional_portal.html?loc=hko';
  static const hkocCsvUrl =
      'https://www.hko.gov.hk/wxinfo/awsgis/hkoc.csv';
  static const ocfForecastUrl =
      'https://maps.weather.gov.hk/ocf/dat/$stationId.xml';
  static const latestTempCsvUrl =
      'https://data.weather.gov.hk/weatherAPI/hko_data/'
      'regional-weather/latest_1min_temperature.csv';
  /// Same HK Observatory air temp as the regional text readings page.
  static const textReadingsUrl =
      'https://www.weather.gov.hk/textonly/v2/forecast/text_readings_v2_e.htm';
  static const hkocCsvReferer =
      'https://www.hko.gov.hk/en/wxinfo/awsgis/regional_portal.html';
  static const defaultObservedDataSource = 'https://www.weather.gov.hk';
  static const forecastDataSource = 'maps.weather.gov.hk/ocf';
  static const _userAgent =
      'app18_hko (https://github.com/DrOwlDev/app18_hko)';

  final http.Client _client;

  Map<String, String> get _hkocHeaders => {
        'Referer': hkocCsvReferer,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      };

  Map<String, String> get _jsonHeaders => {
        'User-Agent': _userAgent,
        'Accept': 'application/json,text/plain,*/*',
      };

  Future<DailyTemperatureSeries> fetchDailySeries({
    required int year,
    required int month,
    required int day,
    required String unit,
    String? observedDataSource,
    DateTime? nowUtc,
  }) async {
    final location =
        CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final dayStart = tz.TZDateTime(location, year, month, day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final nowLocal = tz.TZDateTime.from(
      (nowUtc ?? DateTime.now()).toUtc(),
      location,
    );
    final unitNorm = unit == 'F' ? 'F' : 'C';

    final obsFuture = _fetchHkocObservationsC(
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
    );
    final forecastFuture = _fetchOcfForecastC(
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
    );
    final latestFuture = _fetchLatestObservation(
      location: location,
      unit: unitNorm,
    );

    final observedC = await obsFuture;
    final forecast = await forecastFuture;
    final latestObservation = await latestFuture;
    final retrievedAt = forecast.modelTime == null || forecast.modelTime!.isEmpty
        ? null
        : DateTime.now().toUtc();

    final obsSource =
        (observedDataSource != null && observedDataSource.trim().isNotEmpty)
            ? observedDataSource.trim()
            : defaultObservedDataSource;

    final points = mergeHourlySeries(
      dayStart: dayStart,
      dayEnd: dayEnd,
      nowLocal: nowLocal,
      observedC: observedC,
      forecastC: forecast.tempsC,
      forecastWeatherCodes: forecast.weatherIconCodes,
      unit: unitNorm,
      observedDataSource: obsSource,
      forecastDataSource: forecastDataSource,
    );

    return DailyTemperatureSeries(
      siteId: stationId,
      unit: unitNorm,
      dayStart: dayStart,
      dayEnd: dayEnd,
      nowLocal: nowLocal,
      points: points,
      latestObservation: latestObservation,
      forecastModelTime: forecast.modelTime,
      forecastRetrievedAtUtc: retrievedAt,
    );
  }

  Future<Map<int, double>> _fetchHkocObservationsC({
    required tz.Location location,
    required tz.TZDateTime dayStart,
    required tz.TZDateTime dayEnd,
  }) async {
    try {
      final response = await _client.get(
        Uri.parse(hkocCsvUrl),
        headers: _hkocHeaders,
      );
      if (response.statusCode != 200) return {};
      final samples = parseHkocCsvSamples(response.body);
      return indexMetarObservations(
        location: location,
        dayStart: dayStart,
        dayEnd: dayEnd,
        samples: samples,
      );
    } catch (_) {
      return {};
    }
  }

  Future<({
    Map<int, double> tempsC,
    Map<int, int> weatherIconCodes,
    String? modelTime,
  })> _fetchOcfForecastC({
    required tz.Location location,
    required tz.TZDateTime dayStart,
    required tz.TZDateTime dayEnd,
  }) async {
    try {
      final response = await _client.get(
        Uri.parse(ocfForecastUrl),
        headers: _jsonHeaders,
      );
      if (response.statusCode != 200) {
        return (
          tempsC: <int, double>{},
          weatherIconCodes: <int, int>{},
          modelTime: null,
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        return (
          tempsC: <int, double>{},
          weatherIconCodes: <int, int>{},
          modelTime: null,
        );
      }
      final json = Map<String, dynamic>.from(decoded);
      final indexed = indexOcfHourlyForecast(
        json: json,
        location: location,
        dayStart: dayStart,
        dayEnd: dayEnd,
      );
      final modelTime = json['ModelTime']?.toString();
      return (
        tempsC: indexed.tempsC,
        weatherIconCodes: indexed.weatherIconCodes,
        modelTime: (modelTime != null && modelTime.isNotEmpty) ? modelTime : null,
      );
    } catch (_) {
      return (
        tempsC: <int, double>{},
        weatherIconCodes: <int, int>{},
        modelTime: null,
      );
    }
  }

  Future<LatestStationObservation?> _fetchLatestObservation({
    required tz.Location location,
    required String unit,
  }) async {
    return fetchLatestHkObservatoryObservation(
      location: location,
      unit: unit,
    );
  }

  /// Latest HK Observatory air temperature (text readings page, CSV fallback).
  Future<LatestStationObservation?> fetchLatestHkObservatoryObservation({
    tz.Location? location,
    String unit = 'C',
  }) async {
    final loc =
        location ?? CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final unitNorm = unit == 'F' ? 'F' : 'C';
    try {
      final textResponse = await _client.get(
        Uri.parse(textReadingsUrl),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'text/html,text/plain,*/*',
        },
      );
      if (textResponse.statusCode == 200) {
        final parsed = parseHkoTextReadingsAirTemp(textResponse.body);
        if (parsed != null) {
          return _latestFromWallTemp(
            location: loc,
            unit: unitNorm,
            wall: parsed.wall,
            tempC: parsed.tempC,
          );
        }
      }
    } catch (_) {}

    try {
      final response = await _client.get(
        Uri.parse(latestTempCsvUrl),
        headers: _jsonHeaders,
      );
      if (response.statusCode != 200) return null;
      final parsed = parseHkoLatestTemperatureCsv(response.body);
      if (parsed == null) return null;
      return _latestFromWallTemp(
        location: loc,
        unit: unitNorm,
        wall: parsed.wall,
        tempC: parsed.tempC,
      );
    } catch (_) {
      return null;
    }
  }

  LatestStationObservation _latestFromWallTemp({
    required tz.Location location,
    required String unit,
    required DateTime wall,
    required double tempC,
  }) {
    final local = tz.TZDateTime(
      location,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    return LatestStationObservation(
      temperature: convertTempC(tempC, unit),
      observedAtLocal: local,
    );
  }

  void close() => _client.close();
}

/// Parse hkoc.csv into UTC samples (wall times interpreted as HKT).
List<({DateTime utc, double tempC})> parseHkocCsvSamples(String csvBody) {
  final location = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
  final samples = <({DateTime utc, double tempC})>[];
  final lines = csvBody.split('\n');
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split(',');
    if (parts.length < 2) continue;
    final wall = parseHkoCompactDateTime(parts[0].trim());
    final temp = _parseHkoNumber(parts[1].trim());
    if (wall == null || temp == null) continue;
    final local = tz.TZDateTime(
      location,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    samples.add((utc: local.toUtc(), tempC: temp));
  }
  return samples;
}

/// Index OCF hourly forecast temperatures (°C) and weather icon codes.
({Map<int, double> tempsC, Map<int, int> weatherIconCodes})
    indexOcfHourlyForecast({
  required Map<String, dynamic> json,
  required tz.Location location,
  required tz.TZDateTime dayStart,
  required tz.TZDateTime dayEnd,
}) {
  final hourly = json['HourlyWeatherForecast'];
  if (hourly is! List) {
    return (tempsC: <int, double>{}, weatherIconCodes: <int, int>{});
  }
  final tempsC = <int, double>{};
  final weatherIconCodes = <int, int>{};
  for (final item in hourly) {
    if (item is! Map) continue;
    final hourRaw = item['ForecastHour']?.toString() ?? '';
    final temp = _toDouble(item['ForecastTemperature']);
    if (temp == null) continue;
    final wall = parseHkoCompactDateTime(hourRaw);
    if (wall == null) continue;
    final hourStart = tz.TZDateTime(
      location,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
    );
    if (hourStart.isBefore(dayStart) || hourStart.isAfter(dayEnd)) continue;
    final key = hourStart.millisecondsSinceEpoch;
    tempsC[key] = temp;
    final iconRaw = item['ForecastWeather'];
    int? rawCode;
    if (iconRaw is num) {
      rawCode = iconRaw.toInt();
    } else if (iconRaw != null) {
      rawCode = int.tryParse(iconRaw.toString());
    }
    final icon = normalizeHkoWeatherIconCode(rawCode);
    if (icon != null) weatherIconCodes[key] = icon;
  }
  return (
    tempsC: tempsC,
    weatherIconCodes: expandOcfWeatherIconCodes(
      hourKeys: tempsC.keys,
      sparseCodes: weatherIconCodes,
    ),
  );
}

/// OCF emits [ForecastWeather] about every 3 hours; expand so every forecast
/// hour gets an icon (forward-fill, then back-fill before the first code).
Map<int, int> expandOcfWeatherIconCodes({
  required Iterable<int> hourKeys,
  required Map<int, int> sparseCodes,
}) {
  if (sparseCodes.isEmpty) return {};
  final hours = hourKeys.toList()..sort();
  if (hours.isEmpty) return Map<int, int>.from(sparseCodes);

  final out = <int, int>{};
  int? last;
  for (final h in hours) {
    final explicit = sparseCodes[h];
    if (explicit != null) last = explicit;
    if (last != null) out[h] = last;
  }

  int? next;
  for (var i = hours.length - 1; i >= 0; i--) {
    final h = hours[i];
    final explicit = sparseCodes[h];
    if (explicit != null) next = explicit;
    if (!out.containsKey(h) && next != null) out[h] = next;
  }
  return out;
}

/// Index OCF hourly forecast temperatures (°C) for the local day window.
Map<int, double> indexOcfHourlyForecastC({
  required Map<String, dynamic> json,
  required tz.Location location,
  required tz.TZDateTime dayStart,
  required tz.TZDateTime dayEnd,
}) {
  return indexOcfHourlyForecast(
    json: json,
    location: location,
    dayStart: dayStart,
    dayEnd: dayEnd,
  ).tempsC;
}

/// Parse `latest_1min_temperature.csv` row for HK Observatory.
({DateTime wall, double tempC})? parseHkoLatestTemperatureCsv(String csvBody) {
  final lines = csvBody.split('\n');
  for (final line in lines) {
    final parts = _splitCsvLine(line);
    if (parts.length < 3) continue;
    if (parts[1].trim() != HkoTemperatureApi.observedStationName) continue;
    final wall = parseHkoCompactDateTime(parts[0].trim());
    final temp = _parseHkoNumber(parts[2].trim());
    if (wall == null || temp == null) continue;
    return (wall: wall, tempC: temp);
  }
  return null;
}

/// Parse HK Observatory air temp from the regional text-readings HTML page.
({DateTime wall, double tempC})? parseHkoTextReadingsAirTemp(String body) {
  final timeMatch = RegExp(
    r'Latest readings recorded at\s+(\d{1,2}):(\d{2})\s+Hong Kong Time\s+'
    r'(\d{1,2})\s+(\w+)\s+(\d{4})',
    caseSensitive: false,
  ).firstMatch(body);
  final tempMatch = RegExp(
    r'HK Observatory\s+(\d+(?:\.\d+)?)',
    caseSensitive: false,
  ).firstMatch(body);
  if (timeMatch == null || tempMatch == null) return null;

  final hour = int.tryParse(timeMatch.group(1)!);
  final minute = int.tryParse(timeMatch.group(2)!);
  final day = int.tryParse(timeMatch.group(3)!);
  final month = _englishMonthNumber(timeMatch.group(4)!);
  final year = int.tryParse(timeMatch.group(5)!);
  final temp = double.tryParse(tempMatch.group(1)!);
  if ([hour, minute, day, month, year, temp].contains(null)) return null;

  return (
    wall: DateTime(year!, month!, day!, hour!, minute!),
    tempC: temp!,
  );
}

int? _englishMonthNumber(String raw) {
  const months = {
    'january': 1,
    'february': 2,
    'march': 3,
    'april': 4,
    'may': 5,
    'june': 6,
    'july': 7,
    'august': 8,
    'september': 9,
    'october': 10,
    'november': 11,
    'december': 12,
  };
  return months[raw.trim().toLowerCase()];
}

/// Parse HKO compact timestamps: `YYYYMMDDHH`, `YYYYMMDDHHMM`, or `YYYY/MM/DD HH:MM`.
DateTime? parseHkoCompactDateTime(String raw) {
  if (RegExp(r'^\d+$').hasMatch(raw)) {
    if (raw.length == 10) {
      final year = int.tryParse(raw.substring(0, 4));
      final month = int.tryParse(raw.substring(4, 6));
      final day = int.tryParse(raw.substring(6, 8));
      final hour = int.tryParse(raw.substring(8, 10));
      if ([year, month, day, hour].contains(null)) return null;
      return DateTime(year!, month!, day!, hour!);
    }
    if (raw.length >= 12) {
      final year = int.tryParse(raw.substring(0, 4));
      final month = int.tryParse(raw.substring(4, 6));
      final day = int.tryParse(raw.substring(6, 8));
      final hour = int.tryParse(raw.substring(8, 10));
      final minute = int.tryParse(raw.substring(10, 12));
      if ([year, month, day, hour, minute].contains(null)) return null;
      return DateTime(year!, month!, day!, hour!, minute!);
    }
    return null;
  }

  final match =
      RegExp(r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2})$').firstMatch(raw);
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
  );
}

/// Human-readable HKT label for an OCF [ModelTime] (e.g. `2026091000`).
String? formatHkoModelTimeHkt(String? modelTime) {
  if (modelTime == null || modelTime.isEmpty) return null;
  // Snapshot ids may be `ModelTime_LastModified`.
  final modelPart = modelTime.contains('_')
      ? modelTime.split('_').first
      : modelTime;
  final wall = parseHkoCompactDateTime(modelPart);
  if (wall == null) return modelTime;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final mon = months[wall.month - 1];
  final hh = wall.hour.toString().padLeft(2, '0');
  final mm = wall.minute.toString().padLeft(2, '0');
  return '$mon ${wall.day}, ${wall.year} $hh:$mm HKT';
}

/// Parses `LastModified` / trailing part of snapshot id (`YYYYMMDDHHmmss`).
String? formatHkoLastModifiedHkt(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  var stamp = raw;
  if (stamp.contains('_')) {
    final parts = stamp.split('_');
    stamp = parts.last;
  }
  if (!RegExp(r'^\d{12,14}$').hasMatch(stamp)) return null;
  final wall = parseHkoCompactDateTime(stamp.substring(0, 12));
  if (wall == null) return null;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final mon = months[wall.month - 1];
  final hh = wall.hour.toString().padLeft(2, '0');
  final mm = wall.minute.toString().padLeft(2, '0');
  return '$mon ${wall.day}, ${wall.year} $hh:$mm HKT';
}

/// Clear UI caption for when the HKO forecast was issued / last refreshed.
String? formatHkoForecastRetrievedCaption({
  String? modelTime,
  DateTime? retrievedAtUtc,
  String? lastModified,
}) {
  final modelId = modelTime == null
      ? null
      : (modelTime.contains('_') ? modelTime.split('_').first : modelTime);
  final modifiedId = lastModified ??
      (modelTime != null && modelTime.contains('_')
          ? modelTime.split('_').last
          : null);
  final issued = formatHkoModelTimeHkt(modelId);
  final refreshed = formatHkoLastModifiedHkt(modifiedId);
  if (issued == null && refreshed == null && retrievedAtUtc == null) {
    return null;
  }
  final buf = StringBuffer('HKO OCF/ARWF forecast');
  if (issued != null) {
    buf.write(' ModelTime $issued');
    if (modelId != null) buf.write(' ($modelId)');
  }
  if (refreshed != null) {
    buf.write(' · refreshed $refreshed');
  }
  if (retrievedAtUtc != null) {
    final local = retrievedAtUtc.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    buf.write(' · app fetched $hh:$mm local');
  }
  return buf.toString();
}

double? _parseHkoNumber(String raw) {
  if (raw.isEmpty || raw == '----' || raw == '9999') return null;
  final cleaned = raw.endsWith('*') ? raw.substring(0, raw.length - 1) : raw;
  return double.tryParse(cleaned);
}

double? _toDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

List<String> _splitCsvLine(String line) {
  // Simple split is enough for HKO regional CSVs (no embedded commas in fields).
  return line.split(',');
}
