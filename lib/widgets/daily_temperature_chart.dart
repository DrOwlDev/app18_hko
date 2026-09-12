import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/temp_outcome_bucket.dart';
import '../services/hko_temperature_api.dart';
import '../services/hko_weather_icons.dart';
import '../services/temperature_series.dart';

/// Daily hourly temperature chart (observed + forecast) with a "now" line.
class DailyTemperatureChart extends StatefulWidget {
  const DailyTemperatureChart({
    super.key,
    required this.series,
    this.height = 180,
    this.hideNonExtremeTempRows = true,
    this.overlayForecast = false,
    this.showPointsTable = true,
  });

  final DailyTemperatureSeries series;
  final double height;

  /// When true, the points table keeps Min/Max extremes and all forecast rows
  /// (hides non-extreme observed rows only). Chart points are unchanged.
  final bool hideNonExtremeTempRows;

  /// When true, draw the full yellow forecast line independently of observed
  /// (no bridge from last observed). Used for forecast-accuracy comparison.
  final bool overlayForecast;

  /// When false, omit the temperature points table under the chart.
  final bool showPointsTable;

  @override
  State<DailyTemperatureChart> createState() => _DailyTemperatureChartState();
}

class _DailyTemperatureChartState extends State<DailyTemperatureChart> {
  /// Whole-degree Y-axis probe (°C/°F); null = none selected.
  double? _probeTemp;

  @override
  void didUpdateWidget(covariant DailyTemperatureChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.series.dayStart != widget.series.dayStart ||
        oldWidget.series.dayEnd != widget.series.dayEnd) {
      _probeTemp = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final series = widget.series;
    final height = widget.height;
    final hideNonExtremeTempRows = widget.hideNonExtremeTempRows;
    final overlayForecast = widget.overlayForecast;
    final showPointsTable = widget.showPointsTable;

    final points = series.points;
    if (points.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'No hourly temperature data',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
      );
    }

    final unitSuffix = series.unit == 'F' ? '°F' : '°C';
    final dayMs = series.dayStart.millisecondsSinceEpoch.toDouble();
    final dayEndMs = series.dayEnd.millisecondsSinceEpoch.toDouble();
    final nowMs = series.nowLocal.millisecondsSinceEpoch.toDouble().clamp(
          dayMs,
          dayEndMs,
        );

    FlSpot spotFor(HourlyTempPoint p) => FlSpot(
          p.localHourStart.millisecondsSinceEpoch.toDouble(),
          p.temperature,
        );

    final observedPoints = [
      for (final p in points)
        if (p.kind == TempPointKind.observed) p,
    ];
    final forecastPoints = [
      for (final p in points)
        if (p.kind == TempPointKind.forecast) p,
    ];
    final observedSpots = [for (final p in observedPoints) spotFor(p)];
    // Bridge from last observed so the yellow segment connects at "now"
    // (live Markets charts only). Accuracy overlay keeps forecast independent.
    final bridgeObserved = !overlayForecast &&
        observedSpots.isNotEmpty &&
        forecastPoints.isNotEmpty;
    final forecastSpots = <FlSpot>[
      if (bridgeObserved) observedSpots.last,
      for (final p in forecastPoints) spotFor(p),
    ];

    var minY = points.first.temperature;
    var maxY = points.first.temperature;
    for (final p in points) {
      if (p.temperature < minY) minY = p.temperature;
      if (p.temperature > maxY) maxY = p.temperature;
    }
    final pad = ((maxY - minY).abs() * 0.15).clamp(1.0, 8.0);
    minY = (minY - pad).floorToDouble();
    maxY = (maxY + pad).ceilToDouble();
    if (maxY <= minY) maxY = minY + 2;

    final hourFmt = DateFormat('HH:mm');
    final dayFmt = DateFormat('MMM d');
    const lineColor = Color(0xFF111827);
    const forecastLineColor = Color(0xFF16A34A);
    const minColor = Color(0xFF2563EB);
    const minStroke = Color(0xFF1D4ED8);
    const maxColor = Color(0xFFEA580C);
    const maxStroke = Color(0xFFC2410C);
    const fcMinColor = Color(0xFF0E7490);
    const fcMinStroke = Color(0xFF155E75);
    const fcMaxColor = Color(0xFFCA8A04);
    const fcMaxStroke = Color(0xFFA16207);
    const nowColor = Color(0xFFDC2626);
    const probeColor = Color(0xFF7C3AED);
    const leftTitleWidth = 40.0;

    final probeTemp = _probeTemp;
    var probeAbove = 0;
    var probeBelow = 0;
    final probeAboveByBucket = <int, int>{};
    final probeBelowByBucket = <int, int>{};
    String? probeAboveSummary;
    String? probeBelowSummary;
    if (probeTemp != null) {
      // Probe bucket [T, T+0.99]: below = < T; above = ≥ T+1 (excludes clicked bucket).
      final aboveFrom = probeTemp.round() + 1;
      var aboveExcessSum = 0.0;
      var belowDeficitSum = 0.0;
      for (final p in forecastPoints) {
        final t = p.localHourStart.millisecondsSinceEpoch.toDouble();
        if (t < nowMs || t > dayEndMs) continue;
        final bucket = settlementBucket(p.temperature);
        if (p.temperature >= probeTemp + 1) {
          probeAbove++;
          probeAboveByBucket[bucket] = (probeAboveByBucket[bucket] ?? 0) + 1;
          aboveExcessSum += p.temperature - aboveFrom;
        } else if (p.temperature < probeTemp) {
          probeBelow++;
          probeBelowByBucket[bucket] = (probeBelowByBucket[bucket] ?? 0) + 1;
          belowDeficitSum += probeTemp - p.temperature;
        }
      }
      if (probeTemp + 0.99 > maxY) {
        maxY = (probeTemp + 0.99).ceilToDouble();
      }
      final unit = series.unit == 'F' ? 'F' : 'C';
      final probeDeg = probeTemp.round();
      final aboveParts = (probeAboveByBucket.keys.toList()..sort())
          .map((b) => '$b$unit = ${probeAboveByBucket[b]}')
          .join(' ; ');
      final belowParts = (probeBelowByBucket.keys.toList()
            ..sort((a, b) => b.compareTo(a)))
          .map((b) => '$b$unit = ${probeBelowByBucket[b]}')
          .join(' ; ');
      final aboveWv = probeAbove > 0 ? aboveExcessSum / probeAbove : null;
      final belowWv = probeBelow > 0 ? belowDeficitSum / probeBelow : null;
      probeAboveSummary =
          '$probeDeg$unit probe - ABOVE $aboveFrom$unit = $probeAbove'
          '${probeAbove > 0 ? ' [ $aboveParts ]' : ''}'
          '${aboveWv != null ? ' · wv ${aboveWv.toStringAsFixed(2)}' : ''}';
      probeBelowSummary =
          '$probeDeg$unit probe - BELOW $probeDeg$unit = $probeBelow'
          '${probeBelow > 0 ? ' [ $belowParts ]' : ''}'
          '${belowWv != null ? ' · wv ${belowWv.toStringAsFixed(2)}' : ''}';
    }

    double? dailyMinTemp;
    double? dailyMaxTemp;
    double? forecastMinTemp;
    double? forecastMaxTemp;
    if (overlayForecast) {
      for (final p in observedPoints) {
        if (p.localHourStart.isAfter(series.dayEnd)) continue;
        if (dailyMinTemp == null || p.temperature < dailyMinTemp) {
          dailyMinTemp = p.temperature;
        }
        if (dailyMaxTemp == null || p.temperature > dailyMaxTemp) {
          dailyMaxTemp = p.temperature;
        }
      }
      for (final p in forecastPoints) {
        if (p.localHourStart.isAfter(series.dayEnd)) continue;
        if (forecastMinTemp == null || p.temperature < forecastMinTemp) {
          forecastMinTemp = p.temperature;
        }
        if (forecastMaxTemp == null || p.temperature > forecastMaxTemp) {
          forecastMaxTemp = p.temperature;
        }
      }
      // Future-only days: fall back to forecast extremes as primary lines.
      dailyMinTemp ??= forecastMinTemp;
      dailyMaxTemp ??= forecastMaxTemp;
    } else {
      for (final p in points) {
        if (p.isDailyMinimum) dailyMinTemp ??= p.temperature;
        if (p.isDailyMaximum) dailyMaxTemp ??= p.temperature;
      }
    }

    final obsMin = dailyMinTemp;
    final obsMax = dailyMaxTemp;
    final fcMin = forecastMinTemp;
    final fcMax = forecastMaxTemp;
    final showForecastMinLine = overlayForecast &&
        fcMin != null &&
        obsMin != null &&
        observedPoints.isNotEmpty &&
        (fcMin - obsMin).abs() >= 0.05;
    final showForecastMaxLine = overlayForecast &&
        fcMax != null &&
        obsMax != null &&
        observedPoints.isNotEmpty &&
        (fcMax - obsMax).abs() >= 0.05;

    final minLabelPrefix = overlayForecast && observedPoints.isNotEmpty
        ? 'obs min'
        : 'min';
    final maxLabelPrefix = overlayForecast && observedPoints.isNotEmpty
        ? 'obs max'
        : 'max';

    final showHkoForecastIcons = series.siteId == HkoTemperatureApi.stationId;
    final forecastIconPoints = [
      for (final p in forecastPoints)
        if (p.weatherIconCode != null) p,
    ];
    final forecastRetrievedCaption = formatHkoForecastRetrievedCaption(
      modelTime: series.forecastModelTime,
      retrievedAtUtc: series.forecastRetrievedAtUtc,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (probeTemp != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: leftTitleWidth, right: 4, bottom: 6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F3FF),
                  border: Border.all(color: probeColor.withValues(alpha: 0.35)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        probeAboveSummary!,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.25,
                          color: Color(0xFF4C1D95),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        probeBelowSummary!,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.25,
                          color: Color(0xFF4C1D95),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (showHkoForecastIcons && forecastIconPoints.isNotEmpty)
            SizedBox(
              height: 26,
              child: Padding(
                padding: const EdgeInsets.only(left: leftTitleWidth, right: 4),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final span = (dayEndMs - dayMs).abs();
                    if (span <= 0 || width <= 0) {
                      return const SizedBox.shrink();
                    }
                    // One icon per forecast hour (OCF sparse codes expanded with
                    // rain-priority fill). Prefer chronological order.
                    final hourlyIcons = [...forecastIconPoints]..sort(
                          (a, b) => a.localHourStart
                              .compareTo(b.localHourStart),
                        );
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final p in hourlyIcons)
                          _HkoForecastWeatherIcon(
                            left: ((p.localHourStart.millisecondsSinceEpoch
                                            .toDouble() -
                                        dayMs) /
                                    span) *
                                width,
                            code: p.weatherIconCode!,
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: LineChart(
                LineChartData(
                  minX: dayMs,
                  maxX: dayEndMs,
                  minY: minY,
                  maxY: maxY,
                  // Avoid clipping the next-day 00:00 endpoint / extreme stars at the right edge.
                  clipData: const FlClipData.none(),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: true,
                    horizontalInterval: 1,
                    verticalInterval:
                        const Duration(hours: 1).inMilliseconds.toDouble(),
                    checkToShowVerticalLine: (value) {
                      final local =
                          tz.TZDateTime.fromMillisecondsSinceEpoch(
                        series.dayStart.location,
                        value.round(),
                      );
                      return local.minute == 0 &&
                          local.second == 0 &&
                          local.millisecond == 0;
                    },
                    getDrawingHorizontalLine: (v) => FlLine(
                      color: Colors.grey.shade300,
                      strokeWidth: 1,
                    ),
                    getDrawingVerticalLine: (v) => FlLine(
                      color: Colors.grey.shade200,
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.grey.shade400, width: 1),
                  ),
                  rangeAnnotations: RangeAnnotations(
                    horizontalRangeAnnotations: [
                      if (probeTemp != null)
                        HorizontalRangeAnnotation(
                          y1: probeTemp,
                          y2: probeTemp + 0.99,
                          color: probeColor.withValues(alpha: 0.22),
                        ),
                    ],
                  ),
                  extraLinesData: ExtraLinesData(
                    horizontalLines: [
                      if (dailyMinTemp != null)
                        HorizontalLine(
                          y: dailyMinTemp,
                          color: minColor,
                          strokeWidth: 1.5,
                          dashArray: const [6, 4],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.topLeft,
                            padding: const EdgeInsets.only(left: 4, bottom: 2),
                            style: const TextStyle(
                              fontSize: 10,
                              color: minStroke,
                              fontWeight: FontWeight.w600,
                            ),
                            labelResolver: (line) =>
                                '$minLabelPrefix ${line.y.toStringAsFixed(1)}$unitSuffix',
                          ),
                        ),
                      if (showForecastMinLine)
                        HorizontalLine(
                          y: fcMin,
                          color: fcMinColor,
                          strokeWidth: 1.5,
                          dashArray: const [3, 3],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.bottomLeft,
                            padding: const EdgeInsets.only(left: 4, top: 2),
                            style: const TextStyle(
                              fontSize: 10,
                              color: fcMinStroke,
                              fontWeight: FontWeight.w600,
                            ),
                            labelResolver: (line) =>
                                'fc min ${line.y.toStringAsFixed(1)}$unitSuffix',
                          ),
                        ),
                      if (dailyMaxTemp != null)
                        HorizontalLine(
                          y: dailyMaxTemp,
                          color: maxColor,
                          strokeWidth: 1.5,
                          dashArray: const [6, 4],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.topLeft,
                            padding: const EdgeInsets.only(left: 4, bottom: 2),
                            style: const TextStyle(
                              fontSize: 10,
                              color: maxStroke,
                              fontWeight: FontWeight.w600,
                            ),
                            labelResolver: (line) =>
                                '$maxLabelPrefix ${line.y.toStringAsFixed(1)}$unitSuffix',
                          ),
                        ),
                      if (showForecastMaxLine)
                        HorizontalLine(
                          y: fcMax,
                          color: fcMaxColor,
                          strokeWidth: 1.5,
                          dashArray: const [3, 3],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.bottomLeft,
                            padding: const EdgeInsets.only(left: 4, top: 2),
                            style: const TextStyle(
                              fontSize: 10,
                              color: fcMaxStroke,
                              fontWeight: FontWeight.w600,
                            ),
                            labelResolver: (line) =>
                                'fc max ${line.y.toStringAsFixed(1)}$unitSuffix',
                          ),
                        ),
                    ],
                    verticalLines: [
                      if (nowMs > dayMs && nowMs < dayEndMs)
                        VerticalLine(
                          x: nowMs,
                          color: nowColor,
                          strokeWidth: 1.5,
                          dashArray: const [5, 4],
                          label: VerticalLineLabel(
                            show: true,
                            alignment: Alignment.topRight,
                            padding: const EdgeInsets.only(left: 4, top: 2),
                            style: const TextStyle(
                              fontSize: 10,
                              color: nowColor,
                              fontWeight: FontWeight.w600,
                            ),
                            labelResolver: (_) => _nowLineLabel(
                              series: series,
                              hourFmt: hourFmt,
                              unitSuffix: unitSuffix,
                            ),
                          ),
                        ),
                    ],
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: leftTitleWidth,
                        interval: 1,
                        getTitlesWidget: (value, meta) {
                          if ((value - value.roundToDouble()).abs() > 1e-6) {
                            return const SizedBox.shrink();
                          }
                          final degree = value.roundToDouble();
                          final selected = probeTemp == degree;
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              setState(() {
                                _probeTemp =
                                    selected ? null : degree;
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                '${degree.round()}$unitSuffix',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: selected
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: selected
                                      ? probeColor
                                      : Colors.grey.shade700,
                                  decoration: TextDecoration.underline,
                                  decorationColor: selected
                                      ? probeColor
                                      : Colors.grey.shade400,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 22,
                        // Step hourly; only label every 3h so ticks stay on grid lines.
                        interval:
                            const Duration(hours: 1).inMilliseconds.toDouble(),
                        getTitlesWidget: (value, meta) {
                          final local =
                              tz.TZDateTime.fromMillisecondsSinceEpoch(
                            series.dayStart.location,
                            value.round(),
                          );
                          if (local.minute != 0 ||
                              local.second != 0 ||
                              local.millisecond != 0) {
                            return const SizedBox.shrink();
                          }
                          final isNextDayMidnight = local.hour == 0 &&
                              local.millisecondsSinceEpoch !=
                                  series.dayStart.millisecondsSinceEpoch;
                          if (local.hour % 3 != 0 && !isNextDayMidnight) {
                            return const SizedBox.shrink();
                          }
                          final label = isNextDayMidnight
                              ? dayFmt.format(local)
                              : hourFmt.format(local);
                          return SideTitleWidget(
                            meta: meta,
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 9,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  lineTouchData: LineTouchData(
                    enabled: true,
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touched) {
                        return touched.map((spot) {
                          final local =
                              tz.TZDateTime.fromMillisecondsSinceEpoch(
                            series.dayStart.location,
                            spot.x.round(),
                          );
                          HourlyTempPoint? point;
                          for (final p in points) {
                            if (p.localHourStart.millisecondsSinceEpoch ==
                                spot.x.round()) {
                              point = p;
                              break;
                            }
                          }
                          final tags = <String>[
                            if (point?.kind == TempPointKind.observed)
                              'Observed',
                            if (point?.kind == TempPointKind.forecast)
                              'Forecasted',
                            if (point?.isDailyMinimum == true) 'min',
                            if (point?.isDailyMaximum == true) 'max',
                          ];
                          final tagSuffix =
                              tags.isEmpty ? '' : ' · ${tags.join(' · ')}';
                          final tempUnit = series.unit == 'F' ? 'F' : 'C';
                          return LineTooltipItem(
                            '${_formatPointDateTime(local, hourFmt)}\n'
                            '${spot.y.toStringAsFixed(1)}$tempUnit$tagSuffix',
                            const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          );
                        }).toList();
                      },
                    ),
                  ),
                  lineBarsData: [
                    if (observedSpots.isNotEmpty)
                      LineChartBarData(
                        spots: observedSpots,
                        isCurved: false,
                        color: lineColor,
                        barWidth: 2,
                        isStrokeCapRound: true,
                        dotData: FlDotData(
                          show: true,
                          // Minute-level obs would otherwise stack into a black
                          // blob; only mark extrema + the latest sample.
                          checkToShowDot: (spot, bar) {
                            final index = bar.spots.indexWhere(
                              (s) => s.x == spot.x && s.y == spot.y,
                            );
                            if (index < 0 || index >= observedPoints.length) {
                              return false;
                            }
                            final point = observedPoints[index];
                            if (point.isDailyMaximum || point.isDailyMinimum) {
                              return true;
                            }
                            return index == observedSpots.length - 1;
                          },
                          getDotPainter: (spot, percent, bar, index) {
                            final point = observedPoints[index];
                            if (point.isDailyMaximum) {
                              return const _FlDotStarPainter(
                                color: maxColor,
                                strokeColor: maxStroke,
                                size: 12,
                              );
                            }
                            if (point.isDailyMinimum) {
                              return const _FlDotStarPainter(
                                color: minColor,
                                strokeColor: minStroke,
                                size: 12,
                              );
                            }
                            return FlDotCirclePainter(
                              radius: 4.5,
                              color: lineColor,
                              strokeWidth: 0,
                              strokeColor: lineColor,
                            );
                          },
                        ),
                        belowBarData: BarAreaData(show: false),
                      ),
                    if (forecastSpots.isNotEmpty)
                      LineChartBarData(
                        spots: forecastSpots,
                        isCurved: false,
                        color: forecastLineColor,
                        barWidth: 2,
                        isStrokeCapRound: true,
                        dotData: FlDotData(
                          show: true,
                          checkToShowDot: (spot, bar) {
                            // Hide bridge duplicate of last observed point.
                            if (!bridgeObserved) return true;
                            final bridge = forecastSpots.first;
                            return spot.x != bridge.x || spot.y != bridge.y;
                          },
                          getDotPainter: (spot, percent, bar, index) {
                            final pointIndex =
                                bridgeObserved ? index - 1 : index;
                            if (pointIndex < 0 ||
                                pointIndex >= forecastPoints.length) {
                              return FlDotCirclePainter(
                                radius: 0,
                                color: Colors.transparent,
                                strokeWidth: 0,
                                strokeColor: Colors.transparent,
                              );
                            }
                            final point = forecastPoints[pointIndex];
                            if (point.isDailyMaximum) {
                              return const _FlDotStarPainter(
                                color: maxColor,
                                strokeColor: maxStroke,
                                size: 12,
                              );
                            }
                            if (point.isDailyMinimum) {
                              return const _FlDotStarPainter(
                                color: minColor,
                                strokeColor: minStroke,
                                size: 12,
                              );
                            }
                            final rain = point.weatherIconCode != null &&
                                isHkoRainWeatherIcon(point.weatherIconCode!);
                            if (rain) {
                              return const _FlDotCrossPainter(
                                color: Color(0xFFDC2626),
                                size: 10,
                              );
                            }
                            return FlDotCirclePainter(
                              radius: 2.5,
                              color: Colors.white,
                              strokeWidth: 1.5,
                              strokeColor: forecastLineColor,
                            );
                          },
                        ),
                        belowBarData: BarAreaData(show: false),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (forecastRetrievedCaption != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: leftTitleWidth, right: 4),
              child: Text(
                forecastRetrievedCaption,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF334155),
                ),
              ),
            ),
          ],
          if (showPointsTable) ...[
            const SizedBox(height: 8),
            _TemperaturePointsTable(
              points: points,
              unit: series.unit == 'F' ? 'F' : 'C',
              hourFmt: hourFmt,
              minColor: minColor,
              maxColor: maxColor,
              hideNonExtremeTempRows: hideNonExtremeTempRows,
            ),
          ],
        ],
      ),
    );
  }
}

String _ordinalDay(int day) {
  if (day >= 11 && day <= 13) return '${day}th';
  return switch (day % 10) {
    1 => '${day}st',
    2 => '${day}nd',
    3 => '${day}rd',
    _ => '${day}th',
  };
}

String _formatPointDateTime(tz.TZDateTime local, DateFormat hourFmt) {
  return '${_ordinalDay(local.day)} ${DateFormat('MMM yyyy').format(local)} '
      '${hourFmt.format(local)}';
}

/// Label for the red "now" line: latest HK Observatory air temp + time.
String _nowLineLabel({
  required DailyTemperatureSeries series,
  required DateFormat hourFmt,
  required String unitSuffix,
}) {
  final latest = series.latestObservation;
  if (latest == null) return 'now';
  final temp = latest.temperature.toStringAsFixed(1);
  final time = hourFmt.format(latest.observedAtLocal);
  return '$temp$unitSuffix @ $time';
}

class _TemperaturePointsTable extends StatelessWidget {
  const _TemperaturePointsTable({
    required this.points,
    required this.unit,
    required this.hourFmt,
    required this.minColor,
    required this.maxColor,
    required this.hideNonExtremeTempRows,
  });

  final List<HourlyTempPoint> points;
  final String unit;
  final DateFormat hourFmt;
  final Color minColor;
  final Color maxColor;
  final bool hideNonExtremeTempRows;

  @override
  Widget build(BuildContext context) {
    final visiblePoints = hideNonExtremeTempRows
        ? [
            for (final p in points)
              if (p.isDailyMinimum ||
                  p.isDailyMaximum ||
                  p.kind == TempPointKind.forecast)
                p,
          ]
        : points;

    const headerStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: Color(0xFF334155),
    );
    const cellStyle = TextStyle(
      fontSize: 11,
      color: Color(0xFF0F172A),
    );

    Widget header(String text, {TextAlign align = TextAlign.left}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Text(text, style: headerStyle, textAlign: align),
      );
    }

    Widget cell(String text, {TextStyle? style, TextAlign align = TextAlign.left}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(text, style: style ?? cellStyle, textAlign: align),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFCBD5E1)),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(2.2),
          1: FlexColumnWidth(0.8),
          2: FlexColumnWidth(0.8),
          3: FlexColumnWidth(1.1),
          4: FlexColumnWidth(2.4),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            decoration: const BoxDecoration(color: Color(0xFFF1F5F9)),
            children: [
              header('Date / time'),
              header('Temp', align: TextAlign.right),
              header('Extreme'),
              header('Type'),
              header('Data Source'),
            ],
          ),
          if (visiblePoints.isEmpty)
            TableRow(
              children: [
                cell('No Min/Max extremes in range'),
                cell(''),
                cell(''),
                cell(''),
                cell(''),
              ],
            )
          else
            for (var i = 0; i < visiblePoints.length; i++)
              TableRow(
                decoration: BoxDecoration(
                  color: i.isOdd ? const Color(0xFFF8FAFC) : Colors.white,
                ),
                children: [
                  cell(
                    _formatPointDateTime(
                      visiblePoints[i].localHourStart,
                      hourFmt,
                    ),
                  ),
                  cell(
                    '${visiblePoints[i].temperature.toStringAsFixed(1)}$unit',
                    align: TextAlign.right,
                  ),
                  cell(
                    visiblePoints[i].isDailyMaximum
                        ? 'Max'
                        : visiblePoints[i].isDailyMinimum
                            ? 'Min'
                            : '—',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: (visiblePoints[i].isDailyMinimum ||
                              visiblePoints[i].isDailyMaximum)
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: visiblePoints[i].isDailyMaximum
                          ? maxColor
                          : visiblePoints[i].isDailyMinimum
                              ? minColor
                              : const Color(0xFF94A3B8),
                    ),
                  ),
                  cell(
                    visiblePoints[i].kind == TempPointKind.observed
                        ? 'Observed'
                        : 'Forecasted',
                  ),
                  cell(
                    visiblePoints[i].dataSource.isEmpty
                        ? '—'
                        : visiblePoints[i].dataSource,
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
        ],
      ),
    );
  }
}

/// HKO forecast weather icon anchored above the yellow series timeline.
class _HkoForecastWeatherIcon extends StatelessWidget {
  const _HkoForecastWeatherIcon({
    required this.left,
    required this.code,
  });

  final double left;
  final int code;

  static const _size = 18.0;
  static const _rainColor = Color(0xFFDC2626);

  @override
  Widget build(BuildContext context) {
    final caption = hkoWeatherIconCaption(code);
    final rain = isHkoRainWeatherIcon(code);
    final image = Image.network(
      hkoWeatherIconImageUrl(code),
      width: _size,
      height: _size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => Icon(
        _fallbackIcon(code),
        size: 16,
        color: rain ? _rainColor : const Color(0xFF64748B),
      ),
    );
    return Positioned(
      left: left - _size / 2,
      top: 2,
      width: _size,
      height: _size,
      child: Tooltip(
        message: caption,
        waitDuration: const Duration(milliseconds: 400),
        child: rain
            ? ColorFiltered(
                colorFilter:
                    const ColorFilter.mode(_rainColor, BlendMode.srcIn),
                child: image,
              )
            : image,
      ),
    );
  }

  static IconData _fallbackIcon(int code) {
    if (isHkoRainWeatherIcon(code)) return Icons.umbrella;
    if (code >= 70 && code <= 77) return Icons.nights_stay;
    if (code >= 50 && code <= 54) return Icons.wb_sunny;
    return Icons.cloud;
  }
}

/// Star marker for daily min/max temperature hours.
class _FlDotStarPainter extends FlDotPainter {
  const _FlDotStarPainter({
    required this.color,
    required this.strokeColor,
    required this.size,
  });

  final Color color;
  final Color strokeColor;
  final double size;

  @override
  void draw(Canvas canvas, FlSpot spot, Offset offsetInCanvas) {
    final path = _starPath(offsetInCanvas, size / 2);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = strokeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  static Path _starPath(Offset center, double radius) {
    const points = 5;
    final path = Path();
    final inner = radius * 0.45;
    for (var i = 0; i < points * 2; i++) {
      final r = i.isEven ? radius : inner;
      final angle = -math.pi / 2 + (i * math.pi / points);
      final x = center.dx + r * math.cos(angle);
      final y = center.dy + r * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  @override
  Size getSize(FlSpot spot) => Size(size, size);

  @override
  Color get mainColor => color;

  @override
  List<Object?> get props => [color, strokeColor, size];

  @override
  FlDotPainter lerp(FlDotPainter a, FlDotPainter b, double t) => this;
}

/// Red X marker for forecast hours with rain weather icons.
class _FlDotCrossPainter extends FlDotPainter {
  const _FlDotCrossPainter({
    required this.color,
    required this.size,
  });

  final Color color;
  final double size;

  @override
  void draw(Canvas canvas, FlSpot spot, Offset offsetInCanvas) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final half = size / 2;
    canvas.drawLine(
      Offset(offsetInCanvas.dx - half, offsetInCanvas.dy - half),
      Offset(offsetInCanvas.dx + half, offsetInCanvas.dy + half),
      paint,
    );
    canvas.drawLine(
      Offset(offsetInCanvas.dx + half, offsetInCanvas.dy - half),
      Offset(offsetInCanvas.dx - half, offsetInCanvas.dy + half),
      paint,
    );
  }

  @override
  Size getSize(FlSpot spot) => Size(size, size);

  @override
  Color get mainColor => color;

  @override
  List<Object?> get props => [color, size];

  @override
  FlDotPainter lerp(FlDotPainter a, FlDotPainter b, double t) => this;
}
