import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import '../models/market_event.dart';
import '../services/city_timezones.dart';
import '../services/forecast_accuracy.dart';
import '../services/hko_csv_archive.dart';
import '../services/hko_data_collector.dart';
import '../services/hko_temperature_api.dart';
import '../services/open_url.dart';
import '../services/polymarket_api.dart';
import '../services/temperature_series.dart';
import '../widgets/daily_temperature_chart.dart';
import '../widgets/settlement_bucket_hud.dart';

class ForecastAccuracyPage extends StatefulWidget {
  const ForecastAccuracyPage({super.key, this.collector});

  final HkoDataCollector? collector;

  @override
  State<ForecastAccuracyPage> createState() => _ForecastAccuracyPageState();
}

class _ForecastAccuracyPageState extends State<ForecastAccuracyPage> {
  final _api = PolymarketApi(preferStaticSnapshot: kIsWeb);
  final _hkoTempApi = HkoTemperatureApi();
  List<DateTime> _days = [];
  List<String> _snapshots = [];
  List<MarketEvent> _events = [];
  DateTime? _selectedDay;
  String? _selectedSnapshot;
  String _observedCsv = '';
  List<DayAccuracyRow> _rows = [];
  DailyTemperatureSeries? _chartSeries;
  MarketEvent? _lowEvent;
  MarketEvent? _highEvent;
  bool _loading = true;
  String? _error;
  bool _hideTempTable = true;
  bool _hideBucketTable = true;
  bool _refreshing = false;
  int _webcamCacheBust = DateTime.now().millisecondsSinceEpoch;

  HkoCsvArchive? _localArchive;
  HkoCsvArchiveReader? _webReader;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _localArchive = widget.collector?.archive ??
          HkoCsvArchive(rootDir: HkoCsvArchive.defaultLocalRoot());
    } else {
      _webReader = HkoCsvArchiveReader();
    }
    _loadInitial();
  }

  @override
  void dispose() {
    _webReader?.close();
    _api.close();
    _hkoTempApi.close();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      List<DateTime> observedDays;
      if (kIsWeb) {
        observedDays = await _webReader!.listObservedDays();
        _snapshots = await _webReader!.listForecastSnapshots();
      } else {
        observedDays = await _localArchive!.listObservedDays();
        _snapshots = await _localArchive!.listForecastSnapshots();
      }
      try {
        _events = await _api.fetchTemperatureEvents();
      } catch (_) {
        _events = [];
      }
      _days = mergeAccuracyDays(observedDays: observedDays);
      final today = hktDayWindow(pastDays: 0, nextDays: 0).first;
      _selectedDay = _days.contains(today)
          ? today
          : (_days.isNotEmpty ? _days.first : null);
      _selectedSnapshot = _snapshots.isNotEmpty ? _snapshots.first : null;
      await _loadDayData();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadDayData() async {
    final day = _selectedDay;
    if (day == null) {
      setState(() {
        _observedCsv = '';
        _rows = [];
        _chartSeries = null;
        _lowEvent = null;
        _highEvent = null;
      });
      return;
    }

    final dayName =
        '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}.csv';

    if (kIsWeb) {
      _observedCsv =
          await _webReader!.fetchText('observed/$dayName') ?? '';
    } else {
      _observedCsv = await _localArchive!.readObservedCsvForDay(day);
    }

    final snapshots = <ForecastArchiveSnapshot>[];
    for (final id in _snapshots) {
      String csv;
      if (kIsWeb) {
        csv = await _webReader!.fetchText('forecast/$id.csv') ?? '';
      } else {
        csv = await _localArchive!.readForecastCsv(id);
      }
      final snap = parseForecastArchiveCsv(csv, snapshotId: id);
      if (snap != null) snapshots.add(snap);
    }

    _rows = buildAccuracyRows(
      targetDay: day,
      observedCsv: _observedCsv,
      snapshots: snapshots,
    );

    ForecastArchiveSnapshot? selected;
    if (_selectedSnapshot != null) {
      for (final s in snapshots) {
        if (s.id == _selectedSnapshot) {
          selected = s;
          break;
        }
      }
    }
    // Fallback: load the selected file directly (id may not match modelTime).
    if (selected == null && _selectedSnapshot != null) {
      final id = _selectedSnapshot!;
      final csv = kIsWeb
          ? (await _webReader!.fetchText('forecast/$id.csv') ?? '')
          : await _localArchive!.readForecastCsv(id);
      selected = parseForecastArchiveCsv(csv, snapshotId: id);
    }
    _chartSeries = buildArchiveChartSeries(
      targetDay: day,
      observedCsv: _observedCsv,
      forecast: selected,
      relatedSnapshots: snapshots,
      latestObservation: await _loadLatestHkObservatoryReading(day),
    );

    _lowEvent = null;
    _highEvent = null;
    for (final e in _events) {
      if (!isHongKongTemperatureMarket(e)) continue;
      final d = e.observationDayInCity;
      if (d == null) continue;
      if (d.year != day.year || d.month != day.month || d.day != day.day) {
        continue;
      }
      if (e.tempKind == TempMarketKind.low) {
        _lowEvent = e;
      } else {
        _highEvent = e;
      }
    }

    if (mounted) setState(() {});
  }

  /// Live text-readings/CSV on Windows; archived JSON on GitHub Pages.
  Future<LatestStationObservation?> _loadLatestHkObservatoryReading(
    DateTime day,
  ) async {
    final nowHkt = CityTimezones.nowInCity('Hong Kong');
    if (nowHkt == null) return null;
    final today = DateTime(nowHkt.year, nowHkt.month, nowHkt.day);
    if (day.year != today.year ||
        day.month != today.month ||
        day.day != today.day) {
      return null;
    }
    if (!kIsWeb) {
      final live = await _hkoTempApi.fetchLatestHkObservatoryObservation();
      if (live != null) return live;
      return _localArchive?.readLatestHkObservatoryReading();
    }
    return _webReader?.readLatestHkObservatoryReading();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_days.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            kIsWeb
                ? 'No archived HKO data on Pages yet.\n'
                    'Wait for GitHub Actions to collect data.'
                : 'No local HKO archive yet.\n'
                    'The collector runs every minute on Windows.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadInitial,
      child: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'HKT day',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<DateTime>(
                      isExpanded: true,
                      value: _selectedDay,
                      items: [
                        for (final d in _days)
                          DropdownMenuItem(
                            value: d,
                            child: Text(_dayLabel(d)),
                          ),
                      ],
                      onChanged: (v) async {
                        if (v == null) return;
                        setState(() => _selectedDay = v);
                        await _loadDayData();
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 7,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Forecast Model',
                    isDense: true,
                    border: const OutlineInputBorder(),
                    filled: _isSelectedModelRefreshStale,
                    fillColor: _isSelectedModelRefreshStale
                        ? const Color(0xFFFB923C)
                        : null,
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedSnapshot,
                      items: [
                        for (final id in _snapshots)
                          DropdownMenuItem(
                            value: id,
                            child: Text(
                              _snapshotLabel(id),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) async {
                        setState(() => _selectedSnapshot = v);
                        await _loadDayData();
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_chartSeries != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _compactActionButton(
                    onPressed: _refreshing ? null : _refreshData,
                    icon: _refreshing
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 14),
                    label: kIsWeb
                        ? 'Refresh Data (GitHub Actions)'
                        : 'Refresh Data',
                  ),
                  _compactActionButton(
                    onPressed: () => _openExternalUrl(
                      HkoTemperatureApi.rainForecastUrl,
                    ),
                    icon: const Icon(Icons.water_drop_outlined, size: 14),
                    label: 'Rain Forecast',
                  ),
                  _compactActionButton(
                    onPressed: () => _openExternalUrl(
                      HkoTemperatureApi.textReadingsUrl,
                    ),
                    icon: const Icon(Icons.thermostat_outlined, size: 14),
                    label: 'Check Temp',
                  ),
                  _compactActionButton(
                    onPressed: () => _openExternalUrl(
                      HkoTemperatureApi.regionalPortalTempChartUrl,
                    ),
                    icon: const Icon(Icons.show_chart, size: 14),
                    label: 'Check Forecast',
                  ),
                  _compactActionButton(
                    onPressed: () => _openTodayPolymarket(TempMarketKind.low),
                    icon: const Icon(Icons.arrow_downward, size: 14),
                    label: 'Open Low',
                  ),
                  _compactActionButton(
                    onPressed: () => _openTodayPolymarket(TempMarketKind.high),
                    icon: const Icon(Icons.arrow_upward, size: 14),
                    label: 'Open High',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: DailyTemperatureChart(
                  series: _chartSeries!,
                  height: 512,
                  hideNonExtremeTempRows: true,
                  overlayForecast: true,
                  showPointsTable: !_hideTempTable,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _HkoLiveWebcamRow(cacheBust: _webcamCacheBust),
            if (_lowEvent != null) ...[
              const SizedBox(height: 8),
              SettlementBucketHud(
                series: _chartSeries!,
                markets: _lowEvent!.markets,
                tempKind: TempMarketKind.low,
                title: 'Settlement · Lowest',
              ),
            ],
            if (_highEvent != null) ...[
              const SizedBox(height: 4),
              SettlementBucketHud(
                series: _chartSeries!,
                markets: _highEvent!.markets,
                tempKind: TempMarketKind.high,
                title: 'Settlement · Highest',
              ),
            ],
            Row(
              children: [
                Checkbox(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  value: _hideTempTable,
                  onChanged: (v) {
                    setState(() => _hideTempTable = v ?? true);
                  },
                ),
                const Text(
                  'Hide Table',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 12),
                Checkbox(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  value: _hideBucketTable,
                  onChanged: (v) {
                    setState(() => _hideBucketTable = v ?? true);
                  },
                ),
                const Text(
                  'Hide Bucket',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
          if (!_hideBucketTable) ...[
            const SizedBox(height: 8),
            Text(
              'Bucket accuracy (truncate toward zero: 27.9°C → 27)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 32,
                dataRowMinHeight: 28,
                columns: const [
                  DataColumn(label: Text('ModelTime')),
                  DataColumn(label: Text('FcMin')),
                  DataColumn(label: Text('FcMax')),
                  DataColumn(label: Text('PredLow')),
                  DataColumn(label: Text('PredHigh')),
                  DataColumn(label: Text('ActLow')),
                  DataColumn(label: Text('ActHigh')),
                  DataColumn(label: Text('Low✓')),
                  DataColumn(label: Text('High✓')),
                ],
                rows: [
                  for (final r in _rows)
                    DataRow(
                      cells: [
                        DataCell(Text(r.modelTime)),
                        DataCell(Text(_fmt(r.forecastMinC))),
                        DataCell(Text(_fmt(r.forecastMaxC))),
                        DataCell(Text(r.predLowBucket?.toString() ?? '—')),
                        DataCell(Text(r.predHighBucket?.toString() ?? '—')),
                        DataCell(Text(_fmt(r.actualLowC))),
                        DataCell(Text(_fmt(r.actualHighC))),
                        DataCell(Text(r.lowHit ? '✓' : '✗')),
                        DataCell(Text(r.highHit ? '✓' : '✗')),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _refreshData() async {
    if (_refreshing) return;
    if (kIsWeb) {
      final uri = Uri.parse(
        'https://github.com/DrOwlDev/app18_hko/actions',
      );
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }

    setState(() => _refreshing = true);
    try {
      final collector = widget.collector;
      if (collector != null) {
        await collector.collectNow();
      } else {
        final archive = _localArchive ??
            HkoCsvArchive(rootDir: HkoCsvArchive.defaultLocalRoot());
        await archive.collect();
        if (_localArchive == null) archive.close();
      }
      await _loadInitial();
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _webcamCacheBust = DateTime.now().millisecondsSinceEpoch;
        });
      }
    }
  }

  String _fmt(double? v) => v == null ? '—' : v.toStringAsFixed(1);

  static const _monthSlugs = [
    'january',
    'february',
    'march',
    'april',
    'may',
    'june',
    'july',
    'august',
    'september',
    'october',
    'november',
    'december',
  ];

  Widget _compactActionButton({
    required VoidCallback? onPressed,
    required Widget icon,
    required String label,
  }) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 28),
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      icon: icon,
      label: Text(label),
    );
  }

  Future<void> _openExternalUrl(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _openTodayPolymarket(TempMarketKind kind) async {
    final url = _todayPolymarketUrl(kind);
    if (!kIsWeb) {
      final ok = await openUrlInFirefox(url);
      if (ok) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Firefox')),
        );
      }
    }
    await _openExternalUrl(url);
  }

  String _todayPolymarketUrl(TempMarketKind kind) {
    final nowHkt = CityTimezones.nowInCity('Hong Kong');
    final today = nowHkt != null
        ? DateTime(nowHkt.year, nowHkt.month, nowHkt.day)
        : DateTime(
            DateTime.now().year,
            DateTime.now().month,
            DateTime.now().day,
          );

    for (final e in _events) {
      if (!isHongKongTemperatureMarket(e)) continue;
      if (e.tempKind != kind) continue;
      final d = e.observationDayInCity;
      if (d == null) continue;
      if (d.year != today.year || d.month != today.month || d.day != today.day) {
        continue;
      }
      if (e.slug.isNotEmpty) return e.polymarketUrl;
    }

    final prefix =
        kind == TempMarketKind.low ? 'lowest' : 'highest';
    final month = _monthSlugs[today.month - 1];
    return 'https://polymarket.com/event/'
        '$prefix-temperature-in-hong-kong-on-$month-${today.day}-${today.year}';
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// True when selected snapshot's LastModified (refresh) is >2h before now HKT.
  bool get _isSelectedModelRefreshStale {
    final id = _selectedSnapshot;
    if (id == null) return false;
    final refreshed = _snapshotRefreshHkt(id);
    if (refreshed == null) return false;
    final nowHkt = CityTimezones.nowInCity('Hong Kong');
    if (nowHkt == null) return false;
    return nowHkt.difference(refreshed) > const Duration(hours: 2);
  }

  /// LastModified as HKT from snapshot id `ModelTime_LastModified`.
  tz.TZDateTime? _snapshotRefreshHkt(String snapshotId) {
    if (!snapshotId.contains('_')) return null;
    final wall = _parseCompactWall(snapshotId.split('_').last);
    if (wall == null) return null;
    final loc = CityTimezones.locationForCity('Hong Kong');
    if (loc == null) return null;
    return tz.TZDateTime(
      loc,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
  }

  String _dayLabel(DateTime day) {
    final stamp = '${_weekdays[day.weekday - 1]} ${day.day}/${day.month}';
    final nowHkt = CityTimezones.nowInCity('Hong Kong');
    if (nowHkt == null) return stamp;
    final today = DateTime(nowHkt.year, nowHkt.month, nowHkt.day);
    if (day.isAfter(today)) return '$stamp (F)';
    return stamp;
  }

  /// e.g. `Sat 12/9 03:12 (Fri 11/9 0am)` — refresh first, model second.
  String _snapshotLabel(String snapshotId) {
    final modelPart =
        snapshotId.contains('_') ? snapshotId.split('_').first : snapshotId;
    final modifiedPart =
        snapshotId.contains('_') ? snapshotId.split('_').last : null;
    final model = _compactModelStamp(modelPart);
    final refreshed = _compactRefreshedStamp(modifiedPart);
    if (refreshed != null && model != null) return '$refreshed ($model)';
    if (refreshed != null) return refreshed;
    if (model != null) return model;
    return snapshotId;
  }

  /// `YYYYMMDDHH…` → `ddd D/M Ham` (e.g. `Fri 11/9 0am`)
  String? _compactModelStamp(String? raw) {
    final wall = _parseCompactWall(raw);
    if (wall == null) return null;
    final wd = _weekdays[wall.weekday - 1];
    return '$wd ${wall.day}/${wall.month} ${_hourAmPm(wall.hour)}';
  }

  /// `YYYYMMDDHHMM…` → `ddd D/M HH:mm` (e.g. `Sat 12/9 03:12`)
  String? _compactRefreshedStamp(String? raw) {
    final wall = _parseCompactWall(raw);
    if (wall == null) return null;
    final wd = _weekdays[wall.weekday - 1];
    final hh = wall.hour.toString().padLeft(2, '0');
    final mm = wall.minute.toString().padLeft(2, '0');
    return '$wd ${wall.day}/${wall.month} $hh:$mm';
  }

  DateTime? _parseCompactWall(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return parseHkoCompactDateTime(
      raw.length >= 12 ? raw.substring(0, 12) : raw,
    );
  }

  static String _hourAmPm(int hour) {
    if (hour == 0) return '0am';
    if (hour < 12) return '${hour}am';
    if (hour == 12) return '12pm';
    return '${hour - 12}pm';
  }
}

/// Side-by-side latest HKO HQ webcam stills (west + east).
class _HkoLiveWebcamRow extends StatelessWidget {
  const _HkoLiveWebcamRow({required this.cacheBust});

  final int cacheBust;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _HkoLiveWebcamTile(
            title: 'HKO looking west',
            imageUrl: HkoTemperatureApi.webcamHk2WestUrl,
            pageUrl: HkoTemperatureApi.webcamHk2WestPageUrl,
            cacheBust: cacheBust,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _HkoLiveWebcamTile(
            title: 'HKO looking east',
            imageUrl: HkoTemperatureApi.webcamHkoEastUrl,
            pageUrl: HkoTemperatureApi.webcamHkoEastPageUrl,
            cacheBust: cacheBust,
          ),
        ),
      ],
    );
  }
}

class _HkoLiveWebcamTile extends StatelessWidget {
  const _HkoLiveWebcamTile({
    required this.title,
    required this.imageUrl,
    required this.pageUrl,
    required this.cacheBust,
  });

  final String title;
  final String imageUrl;
  final String pageUrl;
  final int cacheBust;

  @override
  Widget build(BuildContext context) {
    final src = Uri.parse(imageUrl).replace(
      queryParameters: {'v': '$cacheBust'},
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF334155),
          ),
        ),
        const SizedBox(height: 4),
        Material(
          color: const Color(0xFFF8FAFC),
          child: InkWell(
            onTap: () => launchUrl(
              Uri.parse(pageUrl),
              mode: LaunchMode.externalApplication,
            ),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.network(
                src.toString(),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                },
                errorBuilder: (context, error, stack) => const Center(
                  child: Text(
                    'Webcam unavailable',
                    style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
