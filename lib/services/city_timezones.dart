import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Hong Kong IANA timezone for HKO / Polymarket markets.
class CityTimezones {
  CityTimezones._();

  static bool _initialized = false;

  static void ensureInitialized() {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    _initialized = true;
  }

  static const Map<String, String> _byCity = {
    'Hong Kong': 'Asia/Hong_Kong',
  };

  static tz.Location? locationForCity(String city) {
    ensureInitialized();
    final tzName = _byCity[city.trim()];
    if (tzName == null) return null;
    try {
      return tz.getLocation(tzName);
    } catch (_) {
      return null;
    }
  }

  /// 23:59:59 on [year]/[month]/[day] in the city's timezone, as UTC.
  static DateTime? endOfDayUtc({
    required String cityName,
    required int year,
    required int month,
    required int day,
  }) {
    final location = locationForCity(cityName);
    if (location == null) return null;
    final eodLocal = tz.TZDateTime(location, year, month, day, 23, 59, 59);
    return eodLocal.toUtc();
  }

  static tz.TZDateTime? nowInCity(String cityName) {
    final location = locationForCity(cityName);
    if (location == null) return null;
    return tz.TZDateTime.from(DateTime.now().toUtc(), location);
  }
}
