import 'dart:convert';
import 'dart:io' if (dart.library.html) 'hko_csv_io_stub.dart';

import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

import 'city_timezones.dart';
import 'hko_temperature_api.dart';
import 'temperature_series.dart';

/// Result of one archive collection pass.
class HkoArchiveCollectResult {
  const HkoArchiveCollectResult({
    required this.obsRowsAdded,
    required this.forecastWritten,
    this.modelTime,
    this.lastObservedAtHkt,
  });

  final int obsRowsAdded;
  final bool forecastWritten;
  final String? modelTime;
  final String? lastObservedAtHkt;
}

/// Status snapshot for UI.
class HkoArchiveStatus {
  const HkoArchiveStatus({
    this.lastObservedAtHkt,
    this.lastModelTime,
    this.obsRowsToday = 0,
  });

  final String? lastObservedAtHkt;
  final String? lastModelTime;
  final int obsRowsToday;
}

/// Reads/writes HKO observed + forecast CSV archives.
class HkoCsvArchive {
  HkoCsvArchive({
    required this.rootDir,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Directory rootDir;
  final http.Client _client;

  static const webDataPrefix = 'data/hko';

  static Directory defaultLocalRoot() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return Directory(
      '$home${Platform.pathSeparator}Documents${Platform.pathSeparator}'
      'app18_hko${Platform.pathSeparator}data${Platform.pathSeparator}hko',
    );
  }

  Directory get observedDir => Directory('${rootDir.path}/observed');
  Directory get forecastDir => Directory('${rootDir.path}/forecast');
  Directory get metaDir => Directory('${rootDir.path}/meta');

  Future<String?> readLastModelTime() async {
    final f = File('${metaDir.path}/last_model_time.txt');
    if (!await f.exists()) return null;
    final text = (await f.readAsString()).trim();
    return text.isEmpty ? null : text;
  }

  Future<void> writeLastModelTime(String modelTime) async {
    await metaDir.create(recursive: true);
    await File('${metaDir.path}/last_model_time.txt')
        .writeAsString('$modelTime\n');
  }

  /// Appends new minute observations for the current HKT day.
  Future<int> appendObservations() async {
    final location = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final nowLocal = tz.TZDateTime.from(DateTime.now().toUtc(), location);
    final dayStart = tz.TZDateTime(
      location,
      nowLocal.year,
      nowLocal.month,
      nowLocal.day,
    );
    final dayEnd = dayStart.add(const Duration(days: 1));
    final dayFile = _observedFileName(dayStart);

    final response = await _client.get(
      Uri.parse(HkoTemperatureApi.hkocCsvUrl),
      headers: {
        'Referer': HkoTemperatureApi.hkocCsvReferer,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      },
    );
    if (response.statusCode != 200) return 0;

    final samples = parseHkocCsvSamples(response.body);
    final indexed = indexMetarObservations(
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
      samples: samples,
    );

    await observedDir.create(recursive: true);
    final file = File('${observedDir.path}/$dayFile');
    final existing = await _readObservedKeys(file);

    final rows = <String>[];
    if (!await file.exists()) {
      rows.add('observed_at_hkt,temperature_c,rh_pct,source');
    }

    final rhByKey = _indexRhFromHkoc(response.body, location, dayStart, dayEnd);
    var added = 0;
    for (final entry in indexed.entries) {
      final key = entry.key;
      if (existing.contains(key)) continue;
      final t = tz.TZDateTime.fromMillisecondsSinceEpoch(location, key);
      final rh = rhByKey[key];
      rows.add(
        '${_formatHktIso(t)},${entry.value},'
        '${rh ?? ''},hkoc.csv',
      );
      added++;
    }

    if (added > 0) {
      await file.writeAsString('${rows.join('\n')}\n', mode: FileMode.append);
    }
    return added;
  }

  /// Writes a forecast snapshot when [ModelTime] changes.
  Future<bool> appendForecastIfNew() async {
    final response = await _client.get(
      Uri.parse(HkoTemperatureApi.ocfForecastUrl),
      headers: {
        'User-Agent': 'app18_hko (https://github.com/DrOwlDev/app18_hko)',
        'Accept': 'application/json,text/plain,*/*',
      },
    );
    if (response.statusCode != 200) return false;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return false;
    final json = Map<String, dynamic>.from(decoded);
    final modelTime = json['ModelTime']?.toString() ?? '';
    if (modelTime.isEmpty) return false;

    final last = await readLastModelTime();
    if (last == modelTime) return false;

    final location = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final lastModified = json['LastModified']?.toString() ?? '';

    await forecastDir.create(recursive: true);
    final file = File('${forecastDir.path}/$modelTime.csv');
    final buffer = StringBuffer()
      ..writeln('record_type,model_time,forecast_time_hkt,temperature_c,'
          'weather_icon,daily_min_c,daily_max_c,last_modified,source');

    final hourly = json['HourlyWeatherForecast'];
    if (hourly is List) {
      for (final item in hourly) {
        if (item is! Map) continue;
        final hourRaw = item['ForecastHour']?.toString() ?? '';
        final temp = _toDouble(item['ForecastTemperature']);
        if (temp == null) continue;
        final wall = parseHkoCompactDateTime(hourRaw);
        if (wall == null) continue;
        final local = tz.TZDateTime(
          location,
          wall.year,
          wall.month,
          wall.day,
          wall.hour,
        );
        final icon = item['ForecastWeather']?.toString() ?? '';
        buffer.writeln(
          'hourly,$modelTime,${_formatHktIso(local)},$temp,$icon,,,$lastModified,HKO.xml',
        );
      }
    }

    final daily = json['DailyForecast'];
    if (daily is List) {
      for (final item in daily) {
        if (item is! Map) continue;
        final dateRaw = item['ForecastDate']?.toString() ?? '';
        if (dateRaw.length != 8) continue;
        final y = int.tryParse(dateRaw.substring(0, 4));
        final m = int.tryParse(dateRaw.substring(4, 6));
        final d = int.tryParse(dateRaw.substring(6, 8));
        if (y == null || m == null || d == null) continue;
        final local = tz.TZDateTime(location, y, m, d);
        final minT = _toDouble(item['ForecastMinimumTemperature']);
        final maxT = _toDouble(item['ForecastMaximumTemperature']);
        final icon = item['ForecastDailyWeather']?.toString() ?? '';
        buffer.writeln(
          'daily,$modelTime,${_formatHktIso(local)},,$icon,$minT,$maxT,$lastModified,HKO.xml',
        );
      }
    }

    await file.writeAsString(buffer.toString());
    await writeLastModelTime(modelTime);
    await _updateForecastIndex(modelTime);
    return true;
  }

  Future<void> _updateForecastIndex(String modelTime) async {
    await metaDir.create(recursive: true);
    final indexFile = File('${metaDir.path}/forecast_index.txt');
    final existing = <String>{};
    if (await indexFile.exists()) {
      for (final line in await indexFile.readAsLines()) {
        final t = line.trim();
        if (t.isNotEmpty) existing.add(t);
      }
    }
    existing.add(modelTime);
    final sorted = existing.toList()..sort((a, b) => b.compareTo(a));
    await indexFile.writeAsString('${sorted.join('\n')}\n');
  }

  Future<HkoArchiveCollectResult> collect() async {
    final obsAdded = await appendObservations();
    final fcWritten = await appendForecastIfNew();
    final status = await readStatus();
    return HkoArchiveCollectResult(
      obsRowsAdded: obsAdded,
      forecastWritten: fcWritten,
      modelTime: status.lastModelTime,
      lastObservedAtHkt: status.lastObservedAtHkt,
    );
  }

  Future<HkoArchiveStatus> readStatus() async {
    final location = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final nowLocal = tz.TZDateTime.from(DateTime.now().toUtc(), location);
    final dayFile = _observedFileName(
      tz.TZDateTime(location, nowLocal.year, nowLocal.month, nowLocal.day),
    );
    final file = File('${observedDir.path}/$dayFile');
    var rowsToday = 0;
    String? lastObs;
    if (await file.exists()) {
      final lines = await file.readAsLines();
      for (var i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        rowsToday++;
        final parts = _splitCsvLine(line);
        if (parts.isNotEmpty) lastObs = parts[0];
      }
    }
    return HkoArchiveStatus(
      lastObservedAtHkt: lastObs,
      lastModelTime: await readLastModelTime(),
      obsRowsToday: rowsToday,
    );
  }

  /// Lists HKT calendar days with observed CSV files.
  Future<List<DateTime>> listObservedDays() async {
    if (!await observedDir.exists()) return [];
    final days = <DateTime>[];
    await for (final entity in observedDir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})\.csv$').firstMatch(name);
      if (match == null) continue;
      days.add(DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      ));
    }
    days.sort((a, b) => b.compareTo(a));
    return days;
  }

  /// Lists forecast snapshot ModelTime ids (newest first).
  Future<List<String>> listForecastSnapshots() async {
    if (!await forecastDir.exists()) return [];
    final ids = <String>[];
    await for (final entity in forecastDir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.csv')) continue;
      ids.add(name.replaceAll('.csv', ''));
    }
    ids.sort((a, b) => b.compareTo(a));
    return ids;
  }

  Future<String> readObservedCsvForDay(DateTime day) async {
    final file = File('${observedDir.path}/${_observedFileNameFromDate(day)}');
    if (!await file.exists()) return '';
    return file.readAsString();
  }

  Future<String> readForecastCsv(String modelTime) async {
    final file = File('${forecastDir.path}/$modelTime.csv');
    if (!await file.exists()) return '';
    return file.readAsString();
  }

  void close() => _client.close();

  String _observedFileName(tz.TZDateTime dayStart) =>
      _observedFileNameFromDate(
        DateTime(dayStart.year, dayStart.month, dayStart.day),
      );

  static String _observedFileNameFromDate(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}.csv';

  Future<Set<int>> _readObservedKeys(File file) async {
    if (!await file.exists()) return {};
    final keys = <int>{};
    final location = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final lines = await file.readAsLines();
    for (var i = 1; i < lines.length; i++) {
      final parts = _splitCsvLine(lines[i]);
      if (parts.isEmpty) continue;
      final parsed = DateTime.tryParse(parts[0]);
      if (parsed == null) continue;
      final local = tz.TZDateTime.from(parsed.toUtc(), location);
      keys.add(local.millisecondsSinceEpoch);
    }
    return keys;
  }

  Map<int, double> _indexRhFromHkoc(
    String csvBody,
    tz.Location location,
    tz.TZDateTime dayStart,
    tz.TZDateTime dayEnd,
  ) {
    final out = <int, double>{};
    final lines = csvBody.split('\n');
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length < 3) continue;
      final wall = parseHkoCompactDateTime(parts[0].trim());
      final rh = double.tryParse(parts[2].trim());
      if (wall == null || rh == null) continue;
      final local = tz.TZDateTime(
        location,
        wall.year,
        wall.month,
        wall.day,
        wall.hour,
        wall.minute,
      );
      if (local.isBefore(dayStart) || local.isAfter(dayEnd)) continue;
      out[local.millisecondsSinceEpoch] = rh;
    }
    return out;
  }

  static String _formatHktIso(tz.TZDateTime t) {
    final offset = t.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final mins = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-'
        '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}T'
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}$sign$hours:$mins';
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static List<String> _splitCsvLine(String line) {
    final out = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
        continue;
      }
      if (c == ',' && !inQuotes) {
        out.add(buf.toString());
        buf.clear();
        continue;
      }
      buf.write(c);
    }
    out.add(buf.toString());
    return out;
  }
}

/// Web-safe archive reader (fetch same-origin CSVs).
class HkoCsvArchiveReader {
  HkoCsvArchiveReader({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String _prefix = HkoCsvArchive.webDataPrefix;

  Future<String?> fetchText(String relativePath) async {
    final uri = Uri.parse('$_prefix/$relativePath?t=${DateTime.now().millisecondsSinceEpoch}');
    final response = await _client.get(uri);
    if (response.statusCode != 200) return null;
    return response.body;
  }

  Future<List<DateTime>> listObservedDays() async {
    // Web cannot list directory — try index or scan recent days.
    final days = <DateTime>[];
    final location = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final today = tz.TZDateTime.from(DateTime.now().toUtc(), location);
    for (var i = 0; i < 14; i++) {
      final d = today.subtract(Duration(days: i));
      final name =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.csv';
      final body = await fetchText('observed/$name');
      if (body != null && body.trim().isNotEmpty) {
        days.add(DateTime(d.year, d.month, d.day));
      }
    }
    return days;
  }

  Future<List<String>> listForecastSnapshots() async {
    final indexBody = await fetchText('meta/forecast_index.txt');
    if (indexBody == null || indexBody.trim().isEmpty) return [];
    return indexBody
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList()
      ..sort((a, b) => b.compareTo(a));
  }

  void close() => _client.close();
}

/// Parses observed archive CSV into minute samples (°C, HKT wall time).
List<({DateTime local, double tempC})> parseObservedArchiveCsv(String csv) {
  final location = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
  final samples = <({DateTime local, double tempC})>[];
  final lines = csv.split('\n');
  for (var i = 1; i < lines.length; i++) {
    final parts = HkoCsvArchive._splitCsvLine(lines[i].trim());
    if (parts.length < 2) continue;
    final parsed = DateTime.tryParse(parts[0]);
    final temp = double.tryParse(parts[1]);
    if (parsed == null || temp == null) continue;
    final local = tz.TZDateTime.from(parsed.toUtc(), location);
    samples.add((local: local, tempC: temp));
  }
  return samples;
}

/// Parsed forecast snapshot from archive CSV.
class ForecastArchiveSnapshot {
  const ForecastArchiveSnapshot({
    required this.modelTime,
    required this.hourly,
    required this.daily,
  });

  final String modelTime;
  final List<({DateTime hourHkt, double tempC, int? weatherIcon})> hourly;
  final List<({
    DateTime dateHkt,
    double? minC,
    double? maxC,
    int? weatherIcon,
  })> daily;
}

ForecastArchiveSnapshot? parseForecastArchiveCsv(String csv) {
  if (csv.trim().isEmpty) return null;
  final location = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
  final lines = csv.split('\n');
  if (lines.isEmpty) return null;
  String? modelTime;
  final hourly = <({DateTime hourHkt, double tempC, int? weatherIcon})>[];
  final daily = <
      ({
        DateTime dateHkt,
        double? minC,
        double? maxC,
        int? weatherIcon,
      })>[];

  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = HkoCsvArchive._splitCsvLine(line);
    if (parts.length < 4) continue;
    final kind = parts[0];
    modelTime ??= parts[1];
    final timeRaw = parts[2];
    if (kind == 'hourly') {
      final parsed = DateTime.tryParse(timeRaw);
      final temp = double.tryParse(parts[3]);
      if (parsed == null || temp == null) continue;
      final t = tz.TZDateTime.from(parsed.toUtc(), location);
      final icon = int.tryParse(parts[4]);
      hourly.add((hourHkt: t, tempC: temp, weatherIcon: icon));
    } else if (kind == 'daily') {
      final parsed = DateTime.tryParse(timeRaw);
      if (parsed == null) continue;
      final t = tz.TZDateTime.from(parsed.toUtc(), location);
      final minC = double.tryParse(parts[5]);
      final maxC = double.tryParse(parts[6]);
      final icon = int.tryParse(parts[4]);
      daily.add((dateHkt: t, minC: minC, maxC: maxC, weatherIcon: icon));
    }
  }

  final mt = modelTime;
  if (mt == null) return null;
  return ForecastArchiveSnapshot(
    modelTime: mt,
    hourly: hourly,
    daily: daily,
  );
}
