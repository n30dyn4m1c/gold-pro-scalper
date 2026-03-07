# Gold Quant M5 Scalper

A **mean-reversion scalping EA** for MetaTrader 5, designed for XAUUSD (Gold). It uses Z-Score deviations from a moving average to identify statistically extreme price levels, then trades the snap-back to the mean.

## How It Works

### Entry Logic

The EA calculates a **Z-Score** — how many standard deviations price is from its 20-period SMA. When price stretches beyond the threshold (default 2.0 SD), a mean-reversion trade is triggered:

- **Z-Score < -2.0** → BUY (price is unusually low, expect reversion up)
- **Z-Score > +2.0** → SELL (price is unusually high, expect reversion down)

Entries are only taken when **all filters pass**:

| Filter | Purpose |
|--------|---------|
| ADX < 20 | Confirms ranging/mean-reverting market (not trending) |
| Trade window (10:00–20:00) | Restricts to active session hours |
| Spread filter | Blocks entries when spread exceeds threshold |
| Volatility filter | Skips abnormal ATR conditions (spikes or dead markets) |
| News filter | Pauses around high-impact USD economic events |
| Daily loss limit | Stops all trading if daily drawdown is hit |

### Position Management

Once in a trade, the EA manages the position in two phases:

1. **Scale out 50%** when Z-Score returns near zero (mean). SL is moved to breakeven (entry + spread).
2. **ATR trailing stop** on the remaining 50%, locking in profits as price continues.

### News Protection

The EA reads the **MQL5 Economic Calendar** and classifies USD events into two tiers:

| Tier | Events | Default Blackout |
|------|--------|-----------------|
| High-impact | All USD high-importance events | 15 min before / 15 min after |
| Very-high-impact (VHI) | NFP, CPI, FOMC, GDP, PCE, Retail Sales, Unemployment Rate | 60 min before / 60 min after |

When a VHI event is approaching, the EA **automatically closes all open positions** before the news hits (configurable via `InpCloseBeforeVHINews`).

### Daily Loss Limit

Tracks equity against start-of-day balance. If drawdown reaches the configured threshold (default 5%), the EA:

1. Closes all open positions immediately
2. Blocks new entries for the rest of the day
3. Displays a warning on the chart
4. Resets automatically the next trading day

## Input Parameters

### Strategy
| Parameter | Default | Description |
|-----------|---------|-------------|
| `TradeSymbol` | GOLD | Symbol to trade |
| `InpEntryZ` | 2.0 | Z-Score threshold for entry (recommended 1.8–2.5) |
| `InpADXFilter` | 20 | ADX must be below this value (ranging market) |
| `InpRiskPct` | 10.0 | Risk % of balance per trade |
| `InpATRStop` | 2.0 | ATR multiplier for stop loss (recommended 1.5–2.5) |
| `InpTrailingATR` | 1.5 | ATR multiplier for trailing stop |
| `InpStartHour` | 10 | Trading window start (server hour) |
| `InpEndHour` | 20 | Trading window end, exclusive (server hour) |
| `InpMagic` | 777333 | Magic number for position identification |

### Indicators
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpMAPeriod` | 20 | Period for SMA and Standard Deviation |
| `InpATRPeriod` | 14 | ATR period |
| `InpADXPeriod` | 14 | ADX period |

### Execution
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpSlippage` | 30 | Maximum slippage in points |
| `InpMaxSpreadPts` | 50.0 | Maximum allowed spread in points |

### News Filter
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseNewsFilter` | true | Enable/disable news filter |
| `InpNewsMinsBefore` | 15 | Blackout minutes before high-impact news |
| `InpNewsMinsAfter` | 15 | Blackout minutes after high-impact news |
| `InpVHINewsMinsBefore` | 60 | Blackout minutes before VHI news (NFP, etc.) |
| `InpVHINewsMinsAfter` | 60 | Blackout minutes after VHI news |
| `InpCloseBeforeVHINews` | true | Close open positions before VHI events |

### Daily Loss Limit
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseDailyLossLimit` | true | Enable/disable daily loss stop |
| `InpMaxDailyLossPct` | 5.0 | Max daily loss % before trading halts |

### Volatility Filter
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseVolFilter` | true | Enable/disable volatility filter |
| `InpATRMaxMultiple` | 2.0 | Max ATR(14)/ATR(50) ratio (blocks spikes) |
| `InpATRMinMultiple` | 0.5 | Min ATR(14)/ATR(50) ratio (blocks dead markets) |

## Installation

1. Copy `gold-quant-m5-scalper.mq5` to your MetaTrader 5 `MQL5/Experts/` folder
2. Open MetaEditor and compile the file
3. In MT5, drag the EA onto a **GOLD / XAUUSD M5 chart**
4. Enable **AutoTrading** and allow the EA to access the economic calendar

## Chart Display

The EA shows a real-time status overlay on the chart:

```
--- GOLD QUANT M5 SCALPER v4 ---
Z-Score: -1.45
ADX: 16.3
ATR: 4.82
Spread: 25.0 pts
News Block: no
Vol Filter: OK
Daily P/L: +1.23% / -5.0% limit
```

## Risk Warning

This EA is provided for **educational and research purposes**. Trading gold with leverage carries significant risk. Always test thoroughly on a demo account before considering live deployment. Past performance does not guarantee future results.

## License

Copyright 2026, Gemini Quant Lab
