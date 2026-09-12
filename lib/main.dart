import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/market_alert.dart';
import 'models/market_event.dart';
import 'models/temp_outcome_bucket.dart';
import 'pages/forecast_accuracy_page.dart';
import 'pages/positions_page.dart';
import 'services/city_timezones.dart';
import 'services/hko_data_collector.dart';
import 'services/hko_temperature_api.dart';
import 'services/open_url.dart';
import 'services/polymarket_api.dart';
import 'services/temperature_series.dart';
import 'ui/eod_badge_color.dart';
import 'widgets/daily_temperature_chart.dart';
import 'widgets/settlement_bucket_hud.dart';

void main() {
  CityTimezones.ensureInitialized();
  runApp(const LowTempApp());
}

class LowTempApp extends StatelessWidget {
  const LowTempApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HKO Temperature Markets',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B6E4F),
          brightness: Brightness.light,
          surface: Colors.white,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        cardTheme: CardThemeData(
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0.5,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  HkoDataCollector? _collector;
  List<MarketEvent> _marketsCache = const [];
  String? _pendingExpandEventId;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _collector = HkoDataCollector()..start();
    }
  }

  @override
  void dispose() {
    _collector?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (tabContext) {
          return Scaffold(
            appBar: AppBar(
              toolbarHeight: 0,
              elevation: 0,
              scrolledUnderElevation: 0,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              bottom: TabBar(
                labelColor: scheme.primary,
                unselectedLabelColor: scheme.onSurfaceVariant,
                indicatorColor: scheme.primary,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                tabs: const [
                  Tab(text: 'Forecast'),
                  Tab(text: 'Markets'),
                  Tab(text: 'Portfolio'),
                ],
              ),
            ),
            body: SafeArea(
              top: false,
              child: TabBarView(
                children: [
                  ForecastAccuracyPage(collector: _collector),
                  MarketListPage(
                    collector: _collector,
                    onEventsChanged: (events) {
                      setState(() => _marketsCache = events);
                    },
                    pendingExpandEventId: _pendingExpandEventId,
                    onPendingExpandConsumed: () {
                      if (_pendingExpandEventId == null) return;
                      setState(() => _pendingExpandEventId = null);
                    },
                  ),
                  PositionsPage(
                    markets: _marketsCache,
                    onOpenMarket: (eventId) {
                      setState(() => _pendingExpandEventId = eventId);
                      DefaultTabController.of(tabContext).animateTo(1);
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class MarketListPage extends StatefulWidget {
  const MarketListPage({
    super.key,
    this.collector,
    this.onEventsChanged,
    this.pendingExpandEventId,
    this.onPendingExpandConsumed,
  });

  final HkoDataCollector? collector;
  final ValueChanged<List<MarketEvent>>? onEventsChanged;
  final String? pendingExpandEventId;
  final VoidCallback? onPendingExpandConsumed;

  @override
  State<MarketListPage> createState() => _MarketListPageState();
}

class _MarketListPageState extends State<MarketListPage> {
  final PolymarketApi _api = PolymarketApi(preferStaticSnapshot: kIsWeb);
  final NumberFormat _volumeFormat = NumberFormat.compactCurrency(
    symbol: '\$',
    decimalDigits: 0,
  );
  final DateFormat _dayFormat = DateFormat('MMM d');

  List<MarketEvent> _events = [];
  bool _loading = true;
  bool _refreshing = false;
  int _refreshGeneration = 0;
  String? _error;
  DateTime? _lastRefreshedAt;
  Timer? _autoRefreshTimer;
  Timer? _countdownTimer;
  String? _expandedEventId;
  /// Hide Odds on by default. Hide Table hides the whole temp points table.
  bool _hideThinOutcomes = true;
  bool _hideTempTable = true;

  final List<MarketAlert> _alertLog = [];
  final Map<String, double> _prevObsExtremumByEventId = {};
  Set<String> _prevLockedIds = {};
  final Map<String, DateTime> _alertDedupeAt = {};

  @override
  void initState() {
    super.initState();
    _countdownTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _load();
    _autoRefreshTimer = Timer.periodic(
      const Duration(minutes: 3),
      (_) {
        if (!mounted) return;
        _load(silent: true);
      },
    );
  }

  @override
  void didUpdateWidget(covariant MarketListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = widget.pendingExpandEventId;
    if (pending != null && pending != oldWidget.pendingExpandEventId) {
      setState(() => _expandedEventId = pending);
      widget.onPendingExpandConsumed?.call();
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _countdownTimer?.cancel();
    _api.close();
    super.dispose();
  }

  void _pushAlert(MarketAlert alert) {
    final key = '${alert.eventId}|${alert.kind.name}';
    final last = _alertDedupeAt[key];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 60)) {
      return;
    }
    _alertDedupeAt[key] = now;
    setState(() {
      _alertLog.insert(0, alert);
      if (_alertLog.length > 20) {
        _alertLog.removeRange(20, _alertLog.length);
      }
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(alert.message, style: const TextStyle(fontSize: 12)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _onObservedExtremum(MarketEvent event, double? extremum) {
    if (extremum == null) return;
    final prev = _prevObsExtremumByEventId[event.id];
    _prevObsExtremumByEventId[event.id] = extremum;
    if (prev == null) return;
    final unit = event.temperatureUnit ?? 'C';
    final high = event.tempKind == TempMarketKind.high;
    final changed = high
        ? extremum > prev + 1e-9
        : extremum < prev - 1e-9;
    if (!changed) return;
    _pushAlert(
      MarketAlert(
        at: DateTime.now(),
        kind: MarketAlertKind.obsMinDrop,
        eventId: event.id,
        title: event.title,
        message: high
            ? '${event.cityName}: obs max ${formatTempOneDecimal(prev)} → '
                '${formatTempOneDecimal(extremum)}°$unit'
            : '${event.cityName}: obs min ${formatTempOneDecimal(prev)} → '
                '${formatTempOneDecimal(extremum)}°$unit',
      ),
    );
  }

  void _detectNewLockAlerts(List<MarketEvent> events) {
    final locked = <String>{};
    for (final e in events) {
      if (e.matchesLockedMarketWithNos) locked.add(e.id);
    }
    final isInitial = _prevLockedIds.isEmpty && _events.isEmpty;
    if (!isInitial) {
      for (final id in locked) {
        if (_prevLockedIds.contains(id)) continue;
        MarketEvent? event;
        for (final e in events) {
          if (e.id == id) {
            event = e;
            break;
          }
        }
        if (event == null) continue;
        _pushAlert(
          MarketAlert(
            at: DateTime.now(),
            kind: MarketAlertKind.lockWithNos,
            eventId: event.id,
            title: event.title,
            message: '${event.title}: lock ≥90% with No opportunity',
          ),
        );
      }
    }
    _prevLockedIds = locked;
  }

  /// Reloads all markets/odds from Polymarket. Preserves search and
  /// list filters. [silent] avoids blanking the list while refreshing.
  Future<void> _load({bool silent = false}) async {
    final hasData = _events.isNotEmpty;
    setState(() {
      if (!silent || !hasData) {
        _loading = true;
      } else {
        _refreshing = true;
      }
      _error = null;
    });

    try {
      final events = await _api.fetchTemperatureEvents();
      if (!mounted) return;

      _detectNewLockAlerts(events);
      setState(() {
        _events = events;
        _loading = false;
        _refreshing = false;
        _refreshGeneration++;
        _lastRefreshedAt = DateTime.now();
      });
      widget.onEventsChanged?.call(events);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _refreshing = false;
      });
    }
  }

  /// All Hong Kong low + high markets still before local EOD.
  List<MarketEvent> get _filtered {
    final list = _events.where((event) {
      final remaining = event.timeToLocalEndOfDay;
      if (remaining == null || remaining.isNegative) return false;
      return true;
    }).toList();

    list.sort(_compareTimeToEod);
    return list;
  }

  /// Soonest remaining EOD first; already-passed EOD last.
  int _compareTimeToEod(MarketEvent a, MarketEvent b) {
    final aDur = a.timeToLocalEndOfDay;
    final bDur = b.timeToLocalEndOfDay;
    if (aDur == null && bDur == null) {
      return a.cityName.toLowerCase().compareTo(b.cityName.toLowerCase());
    }
    if (aDur == null) return 1;
    if (bDur == null) return -1;
    final aPassed = aDur.isNegative;
    final bPassed = bDur.isNegative;
    if (aPassed != bPassed) return aPassed ? 1 : -1;
    if (aPassed && bPassed) {
      final byPassed = bDur.compareTo(aDur);
      if (byPassed != 0) return byPassed;
    } else {
      final byRemaining = aDur.compareTo(bDur);
      if (byRemaining != 0) return byRemaining;
    }
    return a.cityName.toLowerCase().compareTo(b.cityName.toLowerCase());
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  Future<void> _openUrlInFirefox(String url) async {
    final ok = await openUrlInFirefox(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Firefox')),
      );
    }
  }

  Future<void> _copyToClipboard(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 4),
          child: Column(
            children: [
              Row(
                children: [
                  if (!kIsWeb && widget.collector != null)
                    StreamBuilder(
                      stream: widget.collector!.statusStream,
                      initialData: widget.collector!.lastStatus,
                      builder: (context, snap) {
                        final st = snap.data;
                        final caption = formatHkoForecastRetrievedCaption(
                          modelTime: st?.lastModelTime,
                        );
                        final label = caption ??
                            (st?.lastModelTime == null
                                ? 'HKO archive'
                                : 'HKO ${st!.lastModelTime}');
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 10,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        );
                      },
                    ),
                  Checkbox(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    value: _hideThinOutcomes,
                    onChanged: (value) {
                      setState(() => _hideThinOutcomes = value ?? true);
                    },
                  ),
                  const Flexible(
                    child: Text(
                      'Hide Odds',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Checkbox(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    value: _hideTempTable,
                    onChanged: (value) {
                      setState(() => _hideTempTable = value ?? true);
                    },
                  ),
                  const Flexible(
                    child: Text(
                      'Hide Table',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_refreshing || (_loading && _events.isNotEmpty))
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (_lastRefreshedAt != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        DateFormat.Hm().format(_lastRefreshedAt!),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Text(
                    _loading
                        ? '…'
                        : '${filtered.length}/${_events.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                  if (kIsWeb)
                    IconButton(
                      tooltip: 'Trigger data refresh on GitHub Actions',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _openUrl(
                        'https://github.com/DrOwlDev/app18_hko/actions/workflows/refresh-data.yml',
                      ),
                      icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                    ),
                  IconButton(
                    tooltip: 'Open Polymarket',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openUrl(
                      'https://polymarket.com/weather',
                    ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    visualDensity: VisualDensity.compact,
                    onPressed:
                        (_loading || _refreshing) ? null : () => _load(),
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_alertLog.isNotEmpty) _buildAlertStrip(),
        Expanded(child: _buildBody(filtered)),
      ],
    );
  }

  Widget _buildAlertStrip() {
    final latest = _alertLog.take(3).toList();
    return Material(
      color: const Color(0xFFFFF7ED),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.notifications_active, size: 16, color: Color(0xFFB45309)),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final a in latest)
                    InkWell(
                      onTap: () => setState(() => _expandedEventId = a.eventId),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          a.message,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF9A3412),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _alertLog.clear()),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Clear', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(List<MarketEvent> filtered) {
    if (_loading && _events.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _events.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 40,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          _events.isEmpty ? 'No markets found.' : 'No markets match filters.',
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 12),
        itemCount: filtered.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          final event = filtered[index];
          return _MarketEventTile(
            key: ValueKey(event.id),
            event: event,
            api: _api,
            refreshGeneration: _refreshGeneration,
            volumeFormat: _volumeFormat,
            dayFormat: _dayFormat,
            expanded: _expandedEventId == event.id,
            hideThinOutcomes: _hideThinOutcomes,
            hideTempTable: _hideTempTable,
            onExpansionChanged: (expanded) {
              setState(() {
                _expandedEventId = expanded ? event.id : null;
              });
            },
            onObservedExtremum: (v) => _onObservedExtremum(event, v),
            onOpen: () => _openUrl(event.polymarketUrl),
            onOpenResolution: () {
              final url = event.resolutionSourceOpenUrl;
              if (url != null) _openUrl(url);
            },
            onOpenHkoPortal: () => _openUrl(HkoTemperatureApi.regionalPortalUrl),
            onOpenInFirefox: isWindowsDesktop
                ? () => _openUrlInFirefox(event.polymarketUrl)
                : null,
            onCopyPolymarketUrl: () => _copyToClipboard(
                  event.polymarketUrl,
                  'Polymarket URL',
                ),
          );
        },
      ),
    );
  }
}

/// Distinct badge colors so consecutive calendar days don't share a hue.
/// Avoids red / green / yellow / blue (reserved for EOD & convergence cues).
const List<Color> _dateBadgePalette = [
  Color(0xFF7C3AED), // purple
  Color(0xFFDB2777), // pink
  Color(0xFFC026D3), // magenta
  Color(0xFFEA580C), // orange
  Color(0xFF9333EA), // violet
  Color(0xFF9A3412), // brown
  Color(0xFF6D28D9), // indigo-violet
];

Color _dateBadgeColor(DateTime day) {
  final days = DateTime.utc(day.year, day.month, day.day)
      .difference(DateTime.utc(1970, 1, 1))
      .inDays;
  return _dateBadgePalette[days.abs() % _dateBadgePalette.length];
}

Color _eodBadgeColor(Duration? remaining) => eodBadgeColor(remaining);

/// Row fill from highest outcome chance: ≥95% green, ≥90% yellow, else white.
Color _marketConvergenceFill(double? maxChance) {
  if (maxChance != null && maxChance >= 0.95) {
    return const Color(0xFFE6F6EF);
  }
  if (maxChance != null && maxChance >= 0.90) {
    return const Color(0xFFFFF8E1);
  }
  return Colors.white;
}

Color _marketConvergenceAccent(double? maxChance) {
  if (maxChance != null && maxChance >= 0.95) {
    return const Color(0xFF0B6E4F);
  }
  if (maxChance != null && maxChance >= 0.90) {
    return const Color(0xFFCA8A04);
  }
  return const Color(0xFF94A3B8);
}

/// Top-outcome chip fill: ≥95% green, ≥90% yellow, ≥80% cyan, else white.
Color _topOutcomeChipFill(double? chance) {
  if (chance != null && chance >= 0.95) return const Color(0xFFBBF7D0);
  if (chance != null && chance >= 0.90) return const Color(0xFFFEF08A);
  if (chance != null && chance >= 0.80) return const Color(0xFFA5F3FC);
  return Colors.white;
}

Color _topOutcomeChipAccent(double? chance) {
  if (chance != null && chance >= 0.95) return const Color(0xFF15803D);
  if (chance != null && chance >= 0.90) return const Color(0xFFA16207);
  if (chance != null && chance >= 0.80) return const Color(0xFF0E7490);
  return const Color(0xFF64748B);
}

class _MarketEventTile extends StatefulWidget {
  const _MarketEventTile({
    super.key,
    required this.event,
    required this.api,
    required this.refreshGeneration,
    required this.volumeFormat,
    required this.dayFormat,
    required this.expanded,
    required this.hideThinOutcomes,
    required this.hideTempTable,
    required this.onExpansionChanged,
    required this.onObservedExtremum,
    required this.onOpen,
    required this.onOpenResolution,
    this.onOpenHkoPortal,
    this.onOpenInFirefox,
    required this.onCopyPolymarketUrl,
  });

  final MarketEvent event;
  final PolymarketApi api;
  final int refreshGeneration;
  final NumberFormat volumeFormat;
  final DateFormat dayFormat;
  final bool expanded;
  final bool hideThinOutcomes;
  final bool hideTempTable;
  final ValueChanged<bool> onExpansionChanged;
  final ValueChanged<double?> onObservedExtremum;
  final VoidCallback onOpen;
  final VoidCallback onOpenResolution;
  final VoidCallback? onOpenHkoPortal;
  final VoidCallback? onOpenInFirefox;
  final VoidCallback onCopyPolymarketUrl;

  @override
  State<_MarketEventTile> createState() => _MarketEventTileState();
}

class _MarketEventTileState extends State<_MarketEventTile> {
  late List<OutcomeMarket> _markets;
  bool _loadingPrices = false;
  bool _pricesLoaded = false;

  final HkoTemperatureApi _hkoTempApi = HkoTemperatureApi();
  bool _loadingTemp = false;
  bool _tempLoaded = false;
  DailyTemperatureSeries? _tempSeries;
  String? _tempError;

  bool get _showTemperatureChart =>
      isChartableTemperatureSource(widget.event);

  @override
  void initState() {
    super.initState();
    _markets = widget.event.markets;
    if (widget.expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _loadBuyPrices();
          _loadTemperatureSeries();
        }
      });
    }
  }

  @override
  void dispose() {
    _hkoTempApi.close();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MarketEventTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final eventChanged = oldWidget.event.id != widget.event.id;
    final refreshed =
        oldWidget.refreshGeneration != widget.refreshGeneration;

    if (eventChanged) {
      _markets = widget.event.markets;
      _pricesLoaded = false;
      _loadingPrices = false;
      _resetTemperatureState();
      if (widget.expanded) {
        _loadBuyPrices(force: true);
        _loadTemperatureSeries(force: true);
      }
      return;
    }

    if (refreshed) {
      _markets = widget.event.markets;
      _pricesLoaded = false;
      _tempLoaded = false;
      if (widget.expanded) {
        _loadBuyPrices(force: true);
        _loadTemperatureSeries(force: true);
      }
    }

    if (!oldWidget.expanded && widget.expanded) {
      _loadBuyPrices();
      _loadTemperatureSeries();
    }
  }

  void _resetTemperatureState() {
    _loadingTemp = false;
    _tempLoaded = false;
    _tempSeries = null;
    _tempError = null;
  }

  Future<void> _loadBuyPrices({bool force = false}) async {
    if (_loadingPrices) return;
    if (_pricesLoaded && !force) return;
    setState(() => _loadingPrices = true);
    try {
      final enriched = await widget.api.enrichBuyPrices(widget.event.markets);
      if (!mounted) return;
      setState(() {
        _markets = enriched;
        _pricesLoaded = true;
        _loadingPrices = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _markets = widget.event.markets;
        _loadingPrices = false;
      });
    }
  }

  Future<void> _loadTemperatureSeries({bool force = false}) async {
    if (!_showTemperatureChart) return;
    if (_loadingTemp) return;
    if (_tempLoaded && !force) return;

    final day = widget.event.observationDayInCity;
    if (day == null) {
      setState(() {
        _tempError = 'No observation day';
        _tempLoaded = true;
      });
      return;
    }

    // GitHub Pages cannot call HKO / weather.gov (CORS); use snapshot.
    if (kIsWeb) {
      final preloaded = widget.event.temperatureSeries;
      setState(() {
        _tempSeries = preloaded;
        _tempError =
            preloaded == null ? 'Temperature chart unavailable' : null;
        _tempLoaded = true;
        _loadingTemp = false;
      });
      widget.onObservedExtremum(
        preloaded == null
            ? null
            : seriesObservedExtremum(preloaded, widget.event.tempKind),
      );
      return;
    }

    setState(() {
      _loadingTemp = true;
      _tempError = null;
    });
    try {
      final observedSource = widget.event.resolutionSourceUrl ??
          widget.event.resolutionSourceOpenUrl;
      final series = await _hkoTempApi.fetchDailySeries(
        year: day.year,
        month: day.month,
        day: day.day,
        unit: widget.event.temperatureUnit ?? 'C',
        observedDataSource: observedSource,
      );
      if (!mounted) return;
      setState(() {
        _tempSeries = series;
        _tempLoaded = true;
        _loadingTemp = false;
      });
      widget.onObservedExtremum(
        seriesObservedExtremum(series, widget.event.tempKind),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tempError = 'Temperature chart unavailable';
        _tempLoaded = true;
        _loadingTemp = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = widget.event;
    final top = event.topMarkets(count: 2);
    final day = event.observationDay;
    final leadingYes = event.leadingYesPrice;
    final accent = _marketConvergenceAccent(leadingYes);
    final fill = _marketConvergenceFill(leadingYes);
    final remaining = event.timeToLocalEndOfDay;
    final eodLabel = formatTimeToEndOfDay(remaining);
    final cityNow = CityTimezones.nowInCity(event.cityName);
    final cityLocalTimeLabel =
        cityNow == null ? null : DateFormat.Hm().format(cityNow);
    final visible = widget.hideThinOutcomes
        ? _markets.where((m) => !m.isThinOutcomeRow).toList()
        : _markets;
    final resolutionOpenUrl = event.resolutionSourceOpenUrl;
    final observedExtremum = _tempSeries == null
        ? null
        : seriesObservedExtremum(_tempSeries!, event.tempKind);

    return Card(
      color: fill,
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: accent),
            Expanded(
              child: ExpansionTile(
                key: ValueKey('${event.id}-${widget.expanded}'),
                initiallyExpanded: widget.expanded,
                dense: true,
                visualDensity: VisualDensity.compact,
                tilePadding: const EdgeInsets.only(left: 8, right: 0),
                childrenPadding: EdgeInsets.zero,
                onExpansionChanged: (expanded) {
                  widget.onExpansionChanged(expanded);
                  if (expanded) {
                    _loadBuyPrices();
                    _loadTemperatureSeries();
                  }
                },
                title: Text(
                  event.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    height: 1.2,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _MetaPill(
                        icon: event.tempKind == TempMarketKind.high
                            ? Icons.thermostat
                            : Icons.ac_unit,
                        label: event.tempKind == TempMarketKind.high
                            ? 'High'
                            : 'Low',
                        color: event.tempKind == TempMarketKind.high
                            ? const Color(0xFFC2410C)
                            : const Color(0xFF0369A1),
                      ),
                      if (day != null)
                        _MetaPill(
                          icon: Icons.event,
                          label: widget.dayFormat.format(day.toLocal()),
                          color: _dateBadgeColor(day.toLocal()),
                        ),
                      if (cityLocalTimeLabel != null)
                        _MetaPill(
                          icon: Icons.access_time,
                          label: cityLocalTimeLabel,
                          color: const Color(0xFF475569),
                        ),
                      _MetaPill(
                        icon: Icons.schedule,
                        label: eodLabel,
                        color: _eodBadgeColor(remaining),
                      ),
                      const UniqueSourceBadge(),
                      ...top.map((m) {
                        final price = m.displayChance;
                        final label = m.displayLabel.replaceAll('°', '');
                        final pct = formatChancePercent(price);
                        return Chip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: _topOutcomeChipFill(price),
                          side: BorderSide(color: _topOutcomeChipAccent(price)),
                          label: Text(
                            '$pct @ $label',
                            style: TextStyle(
                              color: _topOutcomeChipAccent(price),
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            ),
                          ),
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          padding: EdgeInsets.zero,
                        );
                      }),
                    ],
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onOpenHkoPortal != null)
                      IconButton(
                        tooltip: 'Open HKO regional portal',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onOpenHkoPortal,
                        icon: Icon(
                          Icons.map_outlined,
                          size: 18,
                          color: accent,
                        ),
                      ),
                    if (resolutionOpenUrl != null)
                      IconButton(
                        tooltip: 'Open resolution source',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onOpenResolution,
                        icon: Icon(
                          Icons.cloud_outlined,
                          size: 18,
                          color: accent,
                        ),
                      ),
                    IconButton(
                      tooltip: 'Copy Polymarket URL',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onCopyPolymarketUrl,
                      icon: Icon(Icons.link, size: 18, color: accent),
                    ),
                    if (widget.onOpenInFirefox != null)
                      IconButton(
                        tooltip: 'Open in Firefox',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onOpenInFirefox,
                        icon: Icon(
                          Icons.open_in_browser,
                          size: 18,
                          color: accent,
                        ),
                      ),
                    IconButton(
                      tooltip: 'Open on Polymarket',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onOpen,
                      icon: Icon(Icons.open_in_new, size: 16, color: accent),
                    ),
                  ],
                ),
                children: [
                  if (_loadingPrices)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (visible.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('No outcomes', style: TextStyle(fontSize: 12)),
                    )
                  else
                    ...visible.map((market) => _OutcomeBuyRow(
                          market: market,
                          volumeFormat: widget.volumeFormat,
                          tempKind: event.tempKind,
                          isDead: observedExtremum != null &&
                              outcomeMarketIsPhysicsDead(
                                market,
                                observedExtremum,
                                kind: event.tempKind,
                              ),
                        )),
                  if (_tempSeries != null)
                    SettlementBucketHud(
                      series: _tempSeries!,
                      markets: _markets,
                      tempKind: event.tempKind,
                    ),
                  if (_showTemperatureChart) ...[
                    const Divider(height: 1),
                    ColoredBox(
                      color: Colors.white,
                      child: _loadingTemp
                          ? const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 12,
                              ),
                              child: LinearProgressIndicator(minHeight: 2),
                            )
                          : _tempError != null
                              ? Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    _tempError!,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                )
                              : _tempSeries != null
                                  ? DailyTemperatureChart(
                                      series: _tempSeries!,
                                      height: 270,
                                      overlayForecast: true,
                                      hideNonExtremeTempRows: false,
                                      showPointsTable: !widget.hideTempTable,
                                    )
                                  : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutcomeBuyRow extends StatelessWidget {
  const _OutcomeBuyRow({
    required this.market,
    required this.volumeFormat,
    required this.tempKind,
    this.isDead = false,
  });

  final OutcomeMarket market;
  final NumberFormat volumeFormat;
  final TempMarketKind tempKind;
  final bool isDead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chance = market.displayChance;
    final pct = formatChancePercent(chance);
    final rowAccent = isDead
        ? const Color(0xFF94A3B8)
        : _topOutcomeChipAccent(chance);
    final buyYes = formatBuyCents(market.buyYesPrice);
    final buyNo = formatBuyCents(market.buyNoPrice);
    final fill = isDead
        ? const Color(0xFFF1F5F9)
        : _topOutcomeChipFill(chance);
    final eliminatedTooltip = tempKind == TempMarketKind.high
        ? 'Eliminated: the observed maximum already exceeds this colder '
            'outcome, so it can no longer win settlement.'
        : 'Eliminated: the observed minimum is already colder than this '
            'warmer outcome, so it can no longer win settlement.';

    return Container(
      color: fill,
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 3,
            height: 28,
            decoration: BoxDecoration(
              color: rowAccent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        market.displayLabel,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          height: 1.1,
                          color: rowAccent,
                          decoration:
                              isDead ? TextDecoration.lineThrough : null,
                          decorationColor: rowAccent,
                        ),
                      ),
                    ),
                    if (isDead) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: eliminatedTooltip,
                        waitDuration: const Duration(milliseconds: 400),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE2E8F0),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Eliminated',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  '${volumeFormat.format(market.volume)} Vol.',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              pct,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: rowAccent,
              ),
            ),
          ),
          const SizedBox(width: 6),
          _BuyPriceButton(
            label: 'Yes',
            value: buyYes,
            background: const Color(0xFFDCFCE7),
            foreground: const Color(0xFF15803D),
            border: const Color(0xFF86EFAC),
          ),
          const SizedBox(width: 4),
          _BuyPriceButton(
            label: 'No',
            value: buyNo,
            background: const Color(0xFFFCE7F3),
            foreground: const Color(0xFFBE185D),
            border: const Color(0xFFF9A8D4),
          ),
        ],
      ),
    );
  }
}

class _BuyPriceButton extends StatelessWidget {
  const _BuyPriceButton({
    required this.label,
    required this.value,
    required this.background,
    required this.foreground,
    required this.border,
  });

  final String label;
  final String value;
  final Color background;
  final Color foreground;
  final Color border;

  @override
  Widget build(BuildContext context) {
    final inactive = value == '--' || value == '0¢';
    return Container(
      constraints: const BoxConstraints(minWidth: 52),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: inactive ? const Color(0xFFF8FAFC) : background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: inactive ? const Color(0xFFCBD5E1) : border,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              height: 1.1,
              color: inactive ? const Color(0xFF94A3B8) : foreground,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              height: 1.1,
              color: inactive ? const Color(0xFF94A3B8) : foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class UniqueSourceBadge extends StatelessWidget {
  const UniqueSourceBadge({super.key});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFDC2626);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: const Text(
        'Unique Resolution Source',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}
