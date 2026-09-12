import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import '../models/market_event.dart';
import '../models/user_position.dart';
import '../services/city_timezones.dart';
import '../services/open_url.dart';
import '../services/polymarket_positions_api.dart';
import '../ui/eod_badge_color.dart';

/// Shows Polymarket positions for a fixed wallet address.
class PositionsPage extends StatefulWidget {
  const PositionsPage({
    super.key,
    this.markets = const [],
    this.onOpenMarket,
  });

  static const userId = PolymarketPositionsApi.defaultUserId;

  /// Live Low/High Temp markets cache for odds / EOD join.
  final List<MarketEvent> markets;

  /// Switch to Low/High Temp and expand this event id.
  final ValueChanged<String>? onOpenMarket;

  @override
  State<PositionsPage> createState() => _PositionsPageState();
}

class _PositionsPageState extends State<PositionsPage>
    with AutomaticKeepAliveClientMixin {
  final PolymarketPositionsApi _api = PolymarketPositionsApi();
  final NumberFormat _money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
  final NumberFormat _shares = NumberFormat('#,##0.##');
  final NumberFormat _pct = NumberFormat('+0.00%;-0.00%');

  List<UserPosition> _positions = [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  DateTime? _lastRefreshedAt;
  Timer? _autoRefreshTimer;
  /// Hide positions whose market EOD has already passed. On by default.
  bool _hidePast = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
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
  void dispose() {
    _autoRefreshTimer?.cancel();
    _api.close();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    setState(() {
      if (!silent || _positions.isEmpty) {
        _loading = true;
      } else {
        _refreshing = true;
      }
      _error = null;
    });

    try {
      final positions = await _api.fetchPositions();
      if (!mounted) return;
      setState(() {
        _positions = positions;
        _loading = false;
        _refreshing = false;
        _lastRefreshedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _refreshing = false;
      });
    }
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

  Future<void> _openMarketInFirefox(String url) async {
    if (isWindowsDesktop) {
      final ok = await openUrlInFirefox(url);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Firefox')),
        );
      }
      return;
    }
    await _openUrl(url);
  }

  ({MarketEvent event, OutcomeMarket? outcome})? _match(UserPosition p) {
    final slug = p.eventSlug.isNotEmpty ? p.eventSlug : p.slug;
    if (slug.isEmpty) return null;
    MarketEvent? event;
    for (final e in widget.markets) {
      if (e.slug == slug) {
        event = e;
        break;
      }
    }
    if (event == null) return null;
    OutcomeMarket? outcome;
    for (final m in event.markets) {
      if (m.yesTokenId == p.asset || m.noTokenId == p.asset) {
        outcome = m;
        break;
      }
    }
    return (event: event, outcome: outcome);
  }

  double get _totalValue =>
      _visiblePositions.fold(0.0, (sum, p) => sum + p.currentValue);

  double get _totalPnl =>
      _visiblePositions.fold(0.0, (sum, p) => sum + p.cashPnl);

  bool _isEodPassed(UserPosition p) {
    final remaining =
        _match(p)?.event.timeToLocalEndOfDay ?? _positionTimeToEod(p);
    return remaining != null && remaining.isNegative;
  }

  /// Fallback when the market is no longer in the live Markets list (past EOD).
  Duration? _positionTimeToEod(UserPosition p) {
    final day = _positionObservationDay(p);
    if (day == null) return null;
    final eodUtc = CityTimezones.endOfDayUtc(
      cityName: 'Hong Kong',
      year: day.year,
      month: day.month,
      day: day.day,
    );
    if (eodUtc == null) return null;
    return eodUtc.difference(DateTime.now().toUtc());
  }

  ({int year, int month, int day})? _positionObservationDay(UserPosition p) {
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

    final slug = p.eventSlug.isNotEmpty ? p.eventSlug : p.slug;
    final slugMatch = RegExp(
      r'on-([a-z]+)-(\d{1,2})-(\d{4})$',
      caseSensitive: false,
    ).firstMatch(slug);
    if (slugMatch != null) {
      final month = months[slugMatch.group(1)!.toLowerCase()];
      final day = int.tryParse(slugMatch.group(2)!);
      final year = int.tryParse(slugMatch.group(3)!);
      if (month != null && day != null && year != null) {
        return (year: year, month: month, day: day);
      }
    }

    final titleMatch = RegExp(
      r'on\s+([A-Za-z]+)\s+(\d{1,2})\??\s*$',
      caseSensitive: false,
    ).firstMatch(p.title);
    if (titleMatch != null) {
      final month = months[titleMatch.group(1)!.toLowerCase()];
      final day = int.tryParse(titleMatch.group(2)!);
      if (month != null && day != null) {
        var year =
            CityTimezones.nowInCity('Hong Kong')?.year ?? DateTime.now().year;
        final end = DateTime.tryParse(p.endDate ?? '');
        if (end != null) {
          final loc = CityTimezones.locationForCity('Hong Kong');
          year = loc != null
              ? tz.TZDateTime.from(end.toUtc(), loc).year
              : end.toUtc().year;
        }
        return (year: year, month: month, day: day);
      }
    }

    final end = DateTime.tryParse(p.endDate ?? '');
    if (end != null) {
      final loc = CityTimezones.locationForCity('Hong Kong');
      if (loc != null) {
        final local = tz.TZDateTime.from(end.toUtc(), loc);
        return (year: local.year, month: local.month, day: local.day);
      }
      final u = end.toUtc();
      return (year: u.year, month: u.month, day: u.day);
    }
    return null;
  }

  /// EOD passed first, then soonest remaining time-to-EOD, then unknown last.
  List<UserPosition> get _sortedPositions {
    final list = List<UserPosition>.from(_positions);
    list.sort((a, b) {
      final aDur =
          _match(a)?.event.timeToLocalEndOfDay ?? _positionTimeToEod(a);
      final bDur =
          _match(b)?.event.timeToLocalEndOfDay ?? _positionTimeToEod(b);
      if (aDur == null && bDur == null) return 0;
      if (aDur == null) return 1;
      if (bDur == null) return -1;
      final aPassed = aDur.isNegative;
      final bPassed = bDur.isNegative;
      if (aPassed != bPassed) return aPassed ? -1 : 1;
      if (aPassed && bPassed) return bDur.compareTo(aDur);
      return aDur.compareTo(bDur);
    });
    return list;
  }

  List<UserPosition> get _visiblePositions {
    final sorted = _sortedPositions;
    if (!_hidePast) return sorted;
    return [
      for (final p in sorted)
        if (!_isEodPassed(p)) p,
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Wallet ${PositionsPage.userId}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (!_loading && _error == null)
                      Text(
                        '${_visiblePositions.length}'
                        '${_hidePast && _visiblePositions.length != _positions.length ? '/${_positions.length}' : ''}'
                        ' positions · '
                        '${_money.format(_totalValue)} · '
                        'PnL ${_money.format(_totalPnl)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _totalPnl >= 0
                              ? const Color(0xFF15803D)
                              : const Color(0xFFBE185D),
                        ),
                      ),
                  ],
                ),
              ),
              Checkbox(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                value: _hidePast,
                onChanged: (v) {
                  setState(() => _hidePast = v ?? true);
                },
              ),
              const Text(
                'Hide Past',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
              if (_refreshing || (_loading && _positions.isNotEmpty))
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
              IconButton(
                tooltip: 'Open profile on Polymarket',
                visualDensity: VisualDensity.compact,
                onPressed: () => _openUrl(
                  'https://polymarket.com/${PositionsPage.userId}',
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
              ),
              IconButton(
                tooltip: 'Refresh positions',
                visualDensity: VisualDensity.compact,
                onPressed: (_loading || _refreshing) ? null : () => _load(),
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody(scheme)),
      ],
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading && _positions.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _positions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _load(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_positions.isEmpty) {
      return const Center(child: Text('No open positions'));
    }

    final positions = _visiblePositions;
    if (positions.isEmpty) {
      return const Center(child: Text('No open positions (Hide Past on)'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      itemCount: positions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final p = positions[index];
        final matched = _match(p);
        final event = matched?.event;
        final outcome = matched?.outcome;
        final remaining =
            event?.timeToLocalEndOfDay ?? _positionTimeToEod(p);
        final eodLabel = formatTimeToEndOfDay(remaining);
        final chance = outcome?.displayChance ??
            (p.curPrice > 0 && p.curPrice < 1 ? p.curPrice : null);
        final chanceLabel = formatChancePercent(chance);
        final pnlColor = p.cashPnl >= 0
            ? const Color(0xFF15803D)
            : const Color(0xFFBE185D);

        return Card(
          child: InkWell(
            onTap: () {
              if (event != null && widget.onOpenMarket != null) {
                widget.onOpenMarket!(event.id);
              } else {
                _openMarketInFirefox(p.polymarketEventUrl);
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          p.title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Open in Firefox',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        onPressed: () =>
                            _openMarketInFirefox(p.polymarketEventUrl),
                        icon: Icon(
                          Icons.open_in_browser,
                          size: 14,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _chip(
                        p.outcome,
                        p.outcome.toLowerCase() == 'yes'
                            ? const Color(0xFF15803D)
                            : const Color(0xFFBE185D),
                      ),
                      if (outcome != null)
                        _chip(
                          outcome.displayLabel,
                          const Color(0xFF475569),
                        ),
                      _chip(
                        chanceLabel,
                        const Color(0xFF0F766E),
                      ),
                      _chip(
                        eodLabel,
                        eodBadgeColor(remaining),
                      ),
                      if (p.redeemable)
                        _chip('Redeemable', const Color(0xFFB45309)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: _stat(
                          'Shares / Payout',
                          _shares.format(p.size),
                        ),
                      ),
                      Expanded(
                        child: _stat(
                          'Avg',
                          '${(p.avgPrice * 100).toStringAsFixed(1)}¢',
                        ),
                      ),
                      Expanded(
                        child: _stat(
                          'Initial Cost',
                          _money.format(p.initialValue),
                        ),
                      ),
                      Expanded(
                        child: _stat(
                          'Now',
                          '${(p.curPrice * 100).toStringAsFixed(1)}¢',
                        ),
                      ),
                      Expanded(
                        child: _stat(
                          'Value',
                          _money.format(p.currentValue),
                        ),
                      ),
                      Expanded(
                        child: _stat(
                          'PnL',
                          '${_money.format(p.cashPnl)}\n${_pct.format(p.percentPnl / 100)}',
                          color: pnlColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color,
            height: 1.15,
          ),
        ),
      ],
    );
  }
}
