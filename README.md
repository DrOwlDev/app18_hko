# app18_hko

Hong Kong HKO Polymarket temperature markets — **Windows desktop** + **GitHub Pages**.

Tracks Polymarket daily **lowest** and **highest** temperature markets for Hong Kong only. Archives HKO observed (minute) and forecast (hourly) data as CSV, with a **Forecast Accuracy** tab comparing predicted vs actual temperature buckets.

- Live site: https://drowldev.github.io/app18_hko/
- Polymarket tags: lowest `104597`, highest `104596` (filtered to Hong Kong)

## Features

- **Markets** — Hong Kong low/high events with HKO temperature charts, settlement HUD, Polymarket odds
- **Forecast Accuracy** — observed vs forecast curves and bucket hit/miss table per HKO `ModelTime` snapshot
- **CSV archive** — dual storage: local (Windows) + repo/Pages (GitHub Actions)

## Settlement rule

Polymarket HK markets truncate toward zero: **27.9°C → bucket 27**, **22.9°C → bucket 22**.

Resolution source: HKO Daily Extract Absolute Daily Min/Max (°C, one decimal) from [weather.gov.hk](https://www.weather.gov.hk/en/cis/climat.htm). Live charts use `hkoc.csv` + OCF `HKO.xml`.

## HKO data sources

| Data | URL |
|------|-----|
| Observed (minute) | `https://www.hko.gov.hk/wxinfo/awsgis/hkoc.csv` |
| Forecast (hourly) | `https://maps.weather.gov.hk/ocf/dat/HKO.xml` (JSON) |
| Now label | `latest_1min_temperature.csv` |

Forecast snapshots dedupe on top-level **`ModelTime`** (~midnight + ~noon HKT updates).

## CSV layout

```
data/hko/
  observed/YYYY-MM-DD.csv     # minute observations (HKT day)
  forecast/YYYYMMDDHH.csv     # one file per ModelTime
  meta/last_model_time.txt
  meta/forecast_index.txt     # web index of snapshots
```

**Windows local path:** `%USERPROFILE%\Documents\app18_hko\data\hko\`

## Run (Windows)

```bat
flutter pub get
flutter run -d windows
```

Or `run.bat`. The app collects HKO CSVs every minute (observed) and hourly (forecast check).

## GitHub Pages

```bat
flutter build web --release --base-href /app18_hko/
```

- [Deploy GitHub Pages](https://github.com/DrOwlDev/app18_hko/actions/workflows/deploy-pages.yml) — on push to `main`
- [Refresh Pages Data](https://github.com/DrOwlDev/app18_hko/actions/workflows/refresh-data.yml) — every ~5 min: collect HKO CSVs, export markets, update `gh-pages`

## Tools

```bat
dart run tool/collect_hko_data.dart data/hko
dart run tool/export_markets.dart web/data/markets.json
```
