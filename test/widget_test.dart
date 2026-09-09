import 'package:flutter_test/flutter_test.dart';

import 'package:app18_hko/main.dart';
import 'package:app18_hko/models/market_event.dart';
import 'package:app18_hko/services/city_timezones.dart';

void main() {
  setUpAll(CityTimezones.ensureInitialized);

  testWidgets('HKO app shows Markets, Forecast Accuracy, and Portfolio tabs',
      (WidgetTester tester) async {
    await tester.pumpWidget(const LowTempApp());
    expect(find.text('Markets'), findsOneWidget);
    expect(find.text('Forecast Accuracy'), findsOneWidget);
    expect(find.text('Portfolio'), findsOneWidget);
    expect(find.textContaining('Hide Odds'), findsOneWidget);
    expect(find.textContaining('Hide Table'), findsOneWidget);
  });

  test('MarketEvent parses Hong Kong low temperature market', () {
    final event = MarketEvent.fromJson({
      'id': '1',
      'title': 'Lowest temperature in Hong Kong on September 5?',
      'slug': 'lowest-temperature-in-hong-kong-on-september-5-2026',
      'volume': 1000,
      'volume24hr': 500,
      'endDate': '2026-09-05T12:00:00Z',
      'markets': [
        {
          'id': '10',
          'question': '26°C?',
          'groupItemTitle': '26°C',
          'outcomes': '["Yes", "No"]',
          'outcomePrices': '["0.61", "0.39"]',
          'volumeNum': 100,
          'bestAsk': 0.62,
          'bestBid': 0.58,
          'clobTokenIds': '["111", "222"]',
        },
      ],
    });

    expect(event.cityName, 'Hong Kong');
    expect(isHongKongTemperatureMarket(event), isTrue);
    expect(event.leadingYesPrice, closeTo(0.62, 0.001));
  });

  test('resolutionSourceUrl from HKO description', () {
    final event = MarketEvent.fromJson({
      'id': '2',
      'title': 'Lowest temperature in Hong Kong on September 5?',
      'slug': 'hk',
      'resolutionSource': '',
      'description':
          'available here: https://www.weather.gov.hk/en/cis/climat.htm',
      'markets': [],
    });
    expect(
      event.resolutionSourceUrl,
      'https://www.weather.gov.hk/en/cis/climat.htm',
    );
    expect(event.resolutionSourceOpenUrl, event.resolutionSourceUrl);
  });

  test('displayChance uses mid when bid/ask spread is wide', () {
    final market = OutcomeMarket.fromJson({
      'id': '13',
      'question': '13°C or below?',
      'groupItemTitle': '13°C or below',
      'outcomes': '["Yes", "No"]',
      'outcomePrices': '["0.505", "0.495"]',
      'volumeNum': 200,
      'bestBid': 0.08,
      'bestAsk': 0.93,
    });
    expect(market.displayChance, closeTo(0.505, 0.001));
  });
}
