## Learned User Preferences

- Dense Windows UI: tight spacing, white backgrounds, no top banners; colored fills only for convergence thresholds.
- Hide markets past local EOD; sort by time-to-EOD; auto-refresh every 3 minutes; Hide Odds / Hide Table on by default.
- Outcome percentages must match Polymarket (including "—" when unavailable); prefer mid over stale last on wide spreads.
- Accordion: one market open; Settlement HUD with full English labels; physics-eliminated outcomes as "Eliminated".
- Always show all Hong Kong low and high markets (no Type / Strategy filters).
- Hong Kong only — no city search; HKO regional portal button on every market row.
- Portfolio: sort by time-to-close (EOD passed first); label "Shares / Payout"; show Initial Cost; open market links in Firefox.
- Forecast chart: taller vertically; always draw the yellow forecast line from HKT 00:00 through next-day 00:00 alongside observed (backfill past hours HKO drops on refresh); when forecasted min/max differs from observed, draw extra horizontal lines for those forecast extrema.

## Learned Workspace Facts

- Flutter app `app18_hko`: Hong Kong Polymarket daily temperature markets (lowest Gamma `104597` + highest `104596`), filtered to `cityName == Hong Kong`.
- **Windows**: live Gamma/CLOB + HKO APIs; background CSV collector to `%USERPROFILE%\Documents\app18_hko\data\hko\`.
- **GitHub Pages**: same-origin `data/markets.json` + `data/hko/` (no CORS); Actions refresh ~every 5 minutes.
- HKO charts: `hkoc.csv` observed + OCF `HKO.xml` forecast; forecast dedupe via OCF `ModelTime`.
- Settlement buckets: truncate toward zero (`27.9°C → 27`).
- Tabs: **Forecast** (first) + **Markets** + **Portfolio** (no Sites, Android). Forecast HKT day list is today−3 through today+3 (forecast-only days labeled), plus any archived observed days.
- Portfolio loads Polymarket Data API for proxy wallet `0x8cEF3c1B592953D61EEE2bC9375C5944A8926B6d`; tap opens/expands matching HK market on Markets when present.
