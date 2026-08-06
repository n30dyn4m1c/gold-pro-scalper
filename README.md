# N30 Gold Reversion

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-MetaTrader%205-blue.svg)](https://www.metatrader5.com/)
[![Language](https://img.shields.io/badge/Language-MQL5-orange.svg)](https://www.mql5.com/)
[![Symbol](https://img.shields.io/badge/Symbol-XAUUSD%20%2F%20GOLD-yellow.svg)](https://github.com/n30dyn4m1c/gold-pro-scalper)

**MetaTrader 5 mean-reversion scalping EAs for gold (XAUUSD / GOLD) on M1 — Z-Score entries, cost-aware exits, and dynamic risk tiers.**

Built for aggressive small-account growth on XM Global–style micro accounts. Multiple variants share the same core idea: trade statistical extremes when the market is ranging, and defend against Every-Tick noise, spread, and news.

## EAs in this repo

| EA | File | Focus |
|----|------|--------|
| **TickRobust** | `XAU_Quant_Reversion_TickRobust.mq5` | Once-per-bar decisions; survives Every Tick testing |
| **M1 OHLC** | `XAU_Quant_Reversion_m1_OLHC.mq5` | Full-featured mean reversion (OHLC-oriented) |
| **M1 EveryTick** | `XAU_Quant_Reversion_m1_EveryTick.mq5` | Tick-path variant |
| **Dual Strategy** | `XAU_Quant_Reversion_Breakout.mq5` | Mean reversion + Donchian trend breakout |

All target **GOLD / XAUUSD** on **M1**. Magic numbers keep strategies independent (e.g. 777555 TickRobust, 777333 MR, 777444 breakout).

---

## TickRobust (`XAU_Quant_Reversion_TickRobust.mq5`)

Mean-reversion EA rebuilt to survive **Every Tick** backtesting, not just M1 OHLC. Earlier designs decided on individual ticks — fine under sparse synthetic OHLC ticks, but losing under real ticks where noise hits the Z-exit at the worst price and spread eats thin snap-backs.

### Every-Tick defence

1. **Once-per-bar decisions on closed-bar data** — entry, exits, breakeven, and TP retargeting run once at each bar open from shift-1 values. Only server-side SL/TP act intra-bar.
2. **Cost gate** — trade only when StdDev and distance to the mean are clear multiples of full round-trip cost (spread + `InpExtraCostPts`). Defaults: StdDev ≥ 3× cost, TP distance ≥ 4× cost.
3. **Server-side limit TP at the mean** — SMA as broker TP (limit exit, no spread on fill); retargeted each bar (“gravity”), floored so a fill still covers cost.
4. **Turn confirmation** — last closed bar must stop extending the stretch (`Close[1]` vs `Close[2]`).
5. **Wide, volatility-aware SL** — `max(800 pts, 2.5×ATR)` so intra-bar spikes that OHLC hides don’t become surprise stop-outs.

### Entry (each M1 bar open)

- Closed-bar Z beyond ±2.2 (`InpEntryZ`)
- Turn confirmation (`InpRequireTurn`)
- Closed-bar ADX ≤ 22
- ATR between 0.4× and 2.0× of its 50-bar average
- Cost gate passes; spread ≤ 50 pts
- Session 10:00–20:00; no red-folder USD news; loss cooldown elapsed
- Optional H1 SMA alignment (closed H1, no repaint)

### Exit priority

1. Server-side limit TP at the mean  
2. Closed-bar Z backup (`|Z| ≤ 0.2`)  
3. Time exit — 40 bars (`InpMaxHoldBars`)  
4. Breakeven after 1×ATR in profit  
5. Server-side SL — `max(800 pts, 2.5×ATR)`

Shared with the other EAs: risk tiers, news filter, daily loss limit, Friday/weekend close, loss cooldown. Magic **777555**.

### Backtesting

- Prefer **Every Tick (real ticks)**. OHLC and tick results should stay close; large divergence usually means spread/symbol setup issues.
- Set `InpExtraCostPts` to round-trip commission in gold points if the broker charges commission.
- Expect **fewer trades** than older EAs — the cost gate skips marginal setups that only looked good on OHLC.

---

## Classic mean reversion (M1 OHLC / EveryTick builds)

Pure Z-Score scalper: deviations from an SMA mark extremes; trade the snap-back.

### Entry

- **Z < -2.4** → BUY  
- **Z > +2.4** → SELL  

| Filter | Typical value | Purpose |
|--------|---------------|---------|
| Z-Score | > 2.4 | Statistical extreme |
| ADX | < 20 | Ranging, not trending |
| Spread | < 50 pts | Avoid illiquid fills |
| Volatility | ATR ratio 0.5–2.0× | Skip dead or spike markets |
| Session | 10:00–20:00 | London + NY overlap |
| News | No high-impact USD | Avoid red-folder spikes |

### Exit (priority)

1. **Z-Score TP** — close near ±0.3  
2. **Trailing stop** — ATR-based on new bar closes  
3. **Hard SL** — fixed points, server-side  
4. **Hard TP** — server-side safety net  

### Dynamic risk tiers

| Equity | Risk / trade | Daily loss limit |
|--------|--------------|------------------|
| < $500 | 10% | 25% |
| $500 – $2,000 | 7% | 20% |
| $2,000 – $5,000 | 5% | 15% |
| $5,000 – $20,000 | 3% | 10% |
| $20,000+ | 1.5% | 7% |

Lot size from SL distance and risk %. Toggle with `InpUseDynamicRisk` for fixed risk instead.

### News filter

MQL5 economic calendar, **high importance** USD only (Forex Factory–style red folder):

- Block new entries 60 minutes before and after  
- Optional close of open trades before the event  

Moderate calendar events are intentionally ignored (too much noise for gold).

---

## Dual strategy (`XAU_Quant_Reversion_Breakout.mq5`)

Two independent strategies on one chart, separate magic numbers.

| Strategy | Magic | Logic |
|----------|-------|--------|
| **Mean reversion** | 777333 | Z-Score when ADX < 20; SL 800 / hard TP 1500 / trail 1.5× ATR |
| **Trend breakout** | 777444 | Donchian 30 break when ADX > 30; EMA 50 + DI spread ≥ 5; SL 1000 / hard TP 2000 / trail 2.0× ATR; 10-bar loss cooldown |

Shared: session, spread, news, volatility filter, daily loss limit.

---

## Installation

1. Copy the `.mq5` files into `MQL5/Experts/`.
2. Compile in MetaEditor (`F7`).
3. Attach to a **GOLD / XAUUSD M1** chart.
4. Enable **AutoTrading**.

## Chart overlay (example)

```text
--- N30 GOLD REVERSION ---
Equity: $52.30
Risk: 10.0% | DLL: 25.0%
Z-Score: -1.45
ADX: 16.3
ATR: 4.82
Spread: 25.0 pts
News Block: no
Vol Filter: OK
Daily P/L: +4.60% / -25.0% limit
```

## Design notes

- **Fixed-point SL** — ATR stops get clipped by gold spikes; fixed points survive better.
- **Z / mean TP** — mean reversion targets the average, not an arbitrary pip count.
- **Hard TP** — server-side backup if the VPS drops.
- **Dynamic risk** — aggressive on micro equity, tighter as the account grows.
- **New-bar trailing** — fewer modify requests, less noise-driven exit.
- **Separate magics** — dual EA strategies manage positions independently.

## Disclaimer

For educational and research use. Leveraged gold trading can lose the entire account. 10% risk per trade is aggressive. Demo thoroughly before live capital. Past results do not guarantee future performance.

## License

This project is licensed under the [MIT License](LICENSE).

## Author

**Neo Malesa** — [n30dyn4m1c](https://github.com/n30dyn4m1c)
