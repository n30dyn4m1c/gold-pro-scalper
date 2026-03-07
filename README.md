# Gold Quant M5 Scalper

A **mean-reversion scalping EA** for MetaTrader 5, designed for XAUUSD (Gold). It uses Z-Score deviations from a moving average to identify statistically extreme price levels, then trades the snap-back to the mean.

## How It Works

### Entry — "Price is stretched, it should come back"

The EA calculates a **Z-Score** — how many standard deviations price is from its 20-period SMA. When price is extremely stretched AND all filters agree, it enters:

- **Z-Score < -2.5** → BUY (price is abnormally low)
- **Z-Score > +2.5** → SELL (price is abnormally high)

**5 filters must all pass before entry:**

| Filter | Condition | Purpose |
|--------|-----------|---------|
| ADX | < 20 | Market is ranging, not trending (mean-reversion only works in ranges) |
| RSI(14) | < 30 for BUY, > 70 for SELL | Double-confirms the extreme with oversold/overbought |
| Volatility | ATR(14)/ATR(50) between 0.5–1.7× | Skips dead markets and volatile spikes/near-breakouts |
| Spread | < 50 points | Avoids bad fills during illiquid conditions |
| Time window | 09:00–18:00 server time | London + early NY session only (avoids late NY chop) |

Additionally, entries are blocked during high-impact news events and when any capital protection limit has been hit.

### Exit — 3-Stage Profit Management

Once in a trade, the EA manages the position in three stages:

| Stage | Trigger | Action | Remaining |
|-------|---------|--------|-----------|
| **TP1** | +0.5× ATR profit | Close **50%**, move SL to breakeven | 50% |
| **TP2** | +2.0× ATR profit | Close another **25%** (half of remaining) | ~25% |
| **Runner** | Trailing stop | Let the last ~25% ride with loose trail | Until stopped |

**Stepped trailing stop:**

- **No trailing** until price moves +1.0× ATR from entry (prevents early stop-outs on normal pullbacks)
- **Tight trail (1.0× ATR)** between TP1 and TP2 — locks gains without choking the move
- **Loose trail (2.0× ATR)** after TP2 — gives the runner room to breathe
- Optional **asymmetric trailing** — separate multipliers for buys vs sells (gold often trends stronger upward)

### News Protection

The EA reads the **MQL5 Economic Calendar** automatically and classifies USD events into two tiers:

| Tier | Events | Default Blackout |
|------|--------|-----------------|
| High-impact | All USD high-importance events | ±15 minutes |
| Very-high-impact (VHI) | NFP, CPI, FOMC, GDP, PCE, Retail Sales, Unemployment Rate | ±60 minutes |

When a VHI event is approaching, the EA **automatically closes all open positions** before the news hits (configurable via `InpCloseBeforeVHINews`).

### Capital Protection — 3 Layers

| Layer | Default | Trigger | Recovery |
|-------|---------|---------|----------|
| **Daily loss** | 4% | Equity drawdown from day's opening balance | Closes all positions, auto-resets next day |
| **Weekly loss** | 10% | Equity drawdown from week's opening balance | Closes all positions, auto-resets next week |
| **Equity drawdown** | 15% from peak | Drawdown from all-time high equity | Closes all positions, **halts EA** — must remove and re-attach |

The equity stop catches streaky losing regimes where daily/weekly limits keep resetting but the account is bleeding. It requires manual review before re-enabling.

### Risk Sizing

Each trade risks **10% of account balance**. The SL is placed at **2.0× ATR** from entry. Lot size is calculated automatically based on risk %, SL distance, and the symbol's tick value. Volume is clamped to broker min/max/step.

## Input Parameters

### Strategy
| Parameter | Default | Description |
|-----------|---------|-------------|
| `TradeSymbol` | GOLD | Symbol to trade |
| `InpEntryZ` | 2.5 | Z-Score threshold for entry (2.3–2.7 sweet spot) |
| `InpADXFilter` | 20 | ADX must be below this value (ranging market) |
| `InpRiskPct` | 10.0 | Risk % of balance per trade |
| `InpATRStop` | 2.0 | ATR multiplier for stop loss |
| `InpStartHour` | 9 | Trading window start, server hour (London open) |
| `InpEndHour` | 18 | Trading window end, exclusive (avoid late NY chop) |
| `InpMagic` | 777333 | Magic number for position identification |

### Partial Profit & Trailing
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpTP1_ATR` | 0.5 | TP1: close 50% at this ATR profit |
| `InpTP2_ATR` | 2.0 | TP2: close 25% at this ATR profit |
| `InpTrailActivATR` | 1.0 | Start trailing after this ATR profit |
| `InpTrailTightATR` | 1.0 | Tight trail multiplier (before TP2) |
| `InpTrailLooseATR` | 2.0 | Loose trail multiplier (after TP2) |
| `InpTrailBuyATR` | 0 | Buy trail override (0 = use standard) |
| `InpTrailSellATR` | 0 | Sell trail override (0 = use standard) |

### Indicators
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpMAPeriod` | 20 | Period for SMA and Standard Deviation |
| `InpATRPeriod` | 14 | ATR period |
| `InpADXPeriod` | 14 | ADX period |
| `InpRSIPeriod` | 14 | RSI period |

### RSI Confirmation
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseRSIFilter` | true | Enable/disable RSI confirmation |
| `InpRSIOversold` | 30.0 | RSI must be below this to allow BUY |
| `InpRSIOverbought` | 70.0 | RSI must be above this to allow SELL |

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

### Capital Protection
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseDailyLossLimit` | true | Enable daily loss stop |
| `InpMaxDailyLossPct` | 4.0 | Max daily loss % (stops trading for the day) |
| `InpUseWeeklyLossLimit` | true | Enable weekly loss stop |
| `InpMaxWeeklyLossPct` | 10.0 | Max weekly loss % (stops trading until next week) |
| `InpUseEquityStop` | true | Enable equity drawdown global stop |
| `InpMaxEquityDDPct` | 15.0 | Max drawdown % from peak equity (halts EA) |

### Volatility Filter
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseVolFilter` | true | Enable/disable volatility filter |
| `InpATRMaxMultiple` | 1.7 | Max ATR(14)/ATR(50) ratio (blocks spikes/near-breakouts) |
| `InpATRMinMultiple` | 0.5 | Min ATR(14)/ATR(50) ratio (blocks dead markets) |

## Installation

1. Copy `gold-quant-m5-scalper.mq5` to your MetaTrader 5 `MQL5/Experts/` folder
2. Open MetaEditor and compile the file
3. In MT5, drag the EA onto a **GOLD / XAUUSD M5 chart**
4. Enable **AutoTrading** and allow the EA to access the economic calendar

## Chart Display

The EA shows a real-time status overlay on the chart:

```
--- GOLD QUANT M5 SCALPER v7 ---
Z-Score: -1.45 | RSI: 28.3
ADX: 16.3
ATR: 4.82
Spread: 25.0 pts
News Block: no
Vol Filter: OK
Profit: 0.72 ATR | TP1 done (50% running, tight trail)
Day: -0.50% / -4.0% | Wk: -1.23% / -10.0% | DD: 0.80% / 15.0%
```

## In Short

The EA waits for a statistically extreme price move in a ranging market, confirmed by both Z-Score and RSI, during active London/NY hours, with clean spreads, normal volatility, and no news — then enters expecting a snap-back to the mean. It takes profit in three stages and has three layers of circuit breakers to protect capital during losing streaks.

## Risk Warning

This EA is provided for **educational and research purposes**. Trading gold with leverage carries significant risk. Always test thoroughly on a demo account before considering live deployment. Past performance does not guarantee future results.

## License

Copyright 2026, Gemini Quant Lab
