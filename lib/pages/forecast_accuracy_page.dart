import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/market_event.dart';
import '../services/city_timezones.dart';
import '../services/forecast_accuracy.dart';
import '../services/hko_csv_archive.dart';
import '../services/hko_data_collector.dart';
import '../services/hko_temperature_api.dart';
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

    final snapshotCaption = _selectedSnapshot == null
        ? null
        : _snapshotLabel(_selectedSnapshot!);

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
                  decoration: const InputDecoration(
                    labelText: 'Forecast snapshot (ModelTime)',
                    isDense: true,
                    border: OutlineInputBorder(),
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
            ],
          ),
          if (snapshotCaption != null) ...[
            const SizedBox(height: 6),
            Text(
              snapshotCaption,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF334155),
              ),
            ),
          ],
          if (_chartSeries != null) ...[
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
          ],
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
      ),
    );
  }

  String _fmt(double? v) => v == null ? '—' : v.toStringAsFixed(1);

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _dayLabel(DateTime day) {
    final wd = _weekdays[day.weekday - 1];
    final stamp =
        '$wd ${day.day.toString().padLeft(2, '0')}-${_months[day.month - 1]}';
    final nowHkt = CityTimezones.nowInCity('Hong Kong');
    if (nowHkt == null) return stamp;
    final today = DateTime(nowHkt.year, nowHkt.month, nowHkt.day);
    if (day.isAfter(today)) return '$stamp (F)';
    return stamp;
  }

  /// e.g. `Model Fri 11-Sep 00:00 (Refreshed Sat 12-Sep 00:11)`
  String _snapshotLabel(String snapshotId) {
    final modelPart =
        snapshotId.contains('_') ? snapshotId.split('_').first : snapshotId;
    final modifiedPart =
        snapshotId.contains('_') ? snapshotId.split('_').last : null;
    final model = _compactHktStamp(modelPart);
    final refreshed = _compactHktStamp(modifiedPart);
    if (model == null) return snapshotId;
    if (refreshed == null) return 'Model $model';
    return 'Model $model (Refreshed $refreshed)';
  }

  /// `YYYYMMDDHH[MM[SS]]` → `ddd dd-MMM HH:mm`
  String? _compactHktStamp(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final wall = parseHkoCompactDateTime(
      raw.length >= 12 ? raw.substring(0, 12) : raw,
    );
    if (wall == null) return null;
    final wd = _weekdays[wall.weekday - 1];
    final dd = wall.day.toString().padLeft(2, '0');
    final mon = _months[wall.month - 1];
    final hh = wall.hour.toString().padLeft(2, '0');
    final mm = wall.minute.toString().padLeft(2, '0');
    return '$wd $dd-$mon $hh:$mm';
  }
}
