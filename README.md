# N30 Gold Reversion

Automated gold (XAUUSD) scalping EAs for MetaTrader 5. Built for aggressive small-account growth on XM Global micro accounts.

## EAs

| EA | File | Symbol | Timeframe | SL | TP |
|----|------|--------|-----------|----|----|
| **N30 Gold Reversion** | `XAU_Quant_Reversion.mq5` | GOLD (XAUUSD) | M1 | Fixed 800 pts | Z-Score return to 0 |
| **N30 Gold Dual Strategy** | `XAU_Quant_Reversion_Breakout.mq5` | GOLD (XAUUSD) | M1 | MR: 800 pts / TB: 1000 pts | Z-Score / Donchian TP |

---

## N30 Gold Reversion (`XAU_Quant_Reversion.mq5`)

Pure mean-reversion scalper. Uses Z-Score deviations from a moving average to identify statistically extreme price levels, then trades the snap-back.

### Entry

The EA calculates a **Z-Score** — how many standard deviations price is from its SMA. When price is stretched and filters agree, it enters:

- **Z-Score < -2.4** → BUY (price is abnormally low)
- **Z-Score > +2.4** → SELL (price is abnormally high)

**Filters that must pass before entry:**

| Filter | Value | Purpose |
|--------|-------|---------|
| Z-Score | > 2.4 | Price is statistically extreme |
| ADX | < 20 | Market is ranging, not trending |
| Spread | < 50 pts | Avoids bad fills during illiquid conditions |
| Volatility | ATR ratio 0.5–2.0x | Skips abnormally quiet or volatile periods |
| Session | 10:00–20:00 broker time | London+NY overlap session |
| News | No red-folder USD events | Avoids high-impact news spikes |

### Exit

Four possible exits, in priority order:

1. **Z-Score TP** — EA closes when Z-Score reverts to ±0.3 (price returned to mean)
2. **Trailing stop** — ATR-based trail tightens on new bar closes (2.0× ATR)
3. **Hard SL** — fixed 800 points, server-side (survives gold spikes and disconnects)
4. **Hard TP** — fixed 1500 points, server-side safety net

### Dynamic Risk Tiers

Risk automatically scales down as your account grows:

| Equity | Risk/Trade | Daily Loss Limit |
|--------|-----------|-----------------|
| < $500 | 10% | 25% |
| $500 – $2,000 | 7% | 20% |
| $2,000 – $5,000 | 5% | 15% |
| $5,000 – $20,000 | 3% | 10% |
| $20,000+ | 1.5% | 7% |

Lot size is calculated from the SL distance and risk %. On a $50 account this produces 0.01 lots (minimum on XM micro). Dynamic risk can be toggled off via `InpUseDynamicRisk` to use fixed values.

### News Filter

Uses the MQL5 built-in economic calendar to avoid trading around high-impact USD news events (`CALENDAR_IMPORTANCE_HIGH` — equivalent to Forex Factory red folder news).

- **60 minutes before** a red-folder event: new entries blocked
- **60 minutes after** a red-folder event: new entries blocked
- **Pre-news close**: optionally closes all open trades before red-folder news hits

Note: MQL5's `CALENDAR_IMPORTANCE_MODERATE` does not match Forex Factory's orange folder — it includes CFTC positioning and Baker Hughes rig counts which don't move gold. Only `CALENDAR_IMPORTANCE_HIGH` is filtered.

### Input Parameters

#### Strategy
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpTradeSymbol` | GOLD | Symbol to trade |
| `InpEntryZ` | 2.4 | Z-Score threshold for entry |
| `InpADXFilter` | 20 | ADX must be below this (ranging market) |
| `InpUseDynamicRisk` | true | Enable equity-based risk tiers |
| `InpRiskPct` | 10.0 | Risk % per trade (when dynamic risk is off) |
| `InpSLPoints` | 800 | Fixed SL in points |
| `InpHardTPPoints` | 1500 | Hard TP in points (server-side safety net) |
| `InpExitZ` | 0.3 | Z-Score exit threshold (close when Z returns near 0) |
| `InpTrailingATR` | 2.0 | ATR multiplier for trailing stop |
| `InpMaxPositions` | 1 | Max open positions allowed |
| `InpStartHour` | 10 | Trading window start (broker time) |
| `InpEndHour` | 20 | Trading window end (broker time) |
| `InpMagic` | 777333 | Magic number for position ID |

#### Indicators
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpMAPeriod` | 20 | SMA and StdDev period |
| `InpATRPeriod` | 14 | ATR period |
| `InpADXPeriod` | 14 | ADX period |

#### Execution
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpSlippage` | 30 | Max slippage in points |
| `InpMaxSpreadPts` | 50 | Max spread in points |

#### News Filter
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseNewsFilter` | true | Enable red-folder news filter |
| `InpNewsMinsBefore` | 60 | Minutes to pause before red-folder news |
| `InpNewsMinsAfter` | 60 | Minutes to pause after red-folder news |
| `InpCloseBeforeNews` | true | Close open trades before red-folder news |

#### Volatility Filter
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseVolFilter` | true | Enable volatility-adjusted entry |
| `InpATRMaxMultiple` | 2.0 | Max ATR vs 50-period avg (skip if exceeded) |
| `InpATRMinMultiple` | 0.5 | Min ATR vs 50-period avg (skip if too quiet) |

#### Daily Loss Limit
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseDailyLossLimit` | true | Enable daily loss stop |
| `InpMaxDailyLossPct` | 20.0 | Max daily loss % (when dynamic risk is off) |

---

## N30 Gold Dual Strategy (`XAU_Quant_Reversion_Breakout.mq5`)

Runs two independent strategies on the same chart using separate magic numbers. Mean Reversion targets ranging conditions; Trend Breakout targets strong directional moves.

### Strategies

**Mean Reversion (Magic 777333)**
- Identical logic to the primary EA: Z-Score entry when ADX < 20
- SL: 800 pts | Hard TP: 1500 pts | Trailing: 1.5× ATR

**Trend Breakout (Magic 777444)**
- Entry: price breaks above/below Donchian Channel (30-bar high/low) when ADX > 30
- Confirmation: price must be above/below EMA 50, DI+/DI- spread ≥ 5.0
- SL: 1000 pts | Hard TP: 2000 pts | Trailing: 2.0× ATR
- Cooldown: 10 bars must elapse after a loss before re-entry

Both strategies share the same session window, spread filter, news filter, volatility filter, and daily loss limit.

### Input Parameters

#### Shared Settings
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpTradeSymbol` | GOLD | Symbol to trade |
| `InpUseDynamicRisk` | true | Enable equity-based risk tiers |
| `InpRiskPct` | 10.0 | MR risk % per trade (when dynamic risk is off) |
| `InpTBRiskPct` | 3.0 | TB risk % per trade (when dynamic risk is off) |
| `InpStartHour` | 10 | Trading window start (broker time) |
| `InpEndHour` | 20 | Trading window end (broker time) |
| `InpSlippage` | 30 | Max slippage in points |
| `InpMaxSpreadPts` | 50 | Max spread in points |
| `InpMaxMRPositions` | 1 | Max Mean Reversion positions |
| `InpMaxTBPositions` | 1 | Max Trend Breakout positions |

#### Mean Reversion
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseReversion` | true | Enable Mean Reversion strategy |
| `InpEntryZ` | 2.4 | Z-Score entry threshold |
| `InpExitZ` | 0.3 | Z-Score exit threshold |
| `InpMRAdxFilter` | 20 | ADX below this = ranging |
| `InpMRSLPoints` | 800 | Fixed SL in points |
| `InpMRHardTPPoints` | 1500 | Hard TP in points |
| `InpMRTrailingATR` | 1.5 | ATR multiplier for trailing |
| `InpMAPeriod` | 20 | MA / StdDev period |
| `InpMRMagic` | 777333 | Magic number |

#### Trend Breakout
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseBreakout` | true | Enable Trend Breakout strategy |
| `InpDonchianPeriod` | 30 | Donchian Channel lookback (bars) |
| `InpTBAdxThreshold` | 30 | ADX above this = trending |
| `InpTBSLPoints` | 1000 | Fixed SL in points |
| `InpTBHardTPPoints` | 2000 | Hard TP in points |
| `InpTBTrailingATR` | 2.0 | ATR multiplier for trailing |
| `InpEMAPeriod` | 50 | EMA for trend direction confirmation |
| `InpCooldownBars` | 10 | Bars to wait after a loss before re-entry |
| `InpMinDISpread` | 5.0 | Min DI+/DI- spread for entry |
| `InpTBMagic` | 777444 | Magic number |

#### Indicators
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpATRPeriod` | 14 | ATR period |
| `InpADXPeriod` | 14 | ADX period |

#### News Filter
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseNewsFilter` | true | Enable red-folder news filter |
| `InpNewsMinsBefore` | 60 | Minutes to pause before red-folder news |
| `InpNewsMinsAfter` | 60 | Minutes to pause after red-folder news |
| `InpCloseBeforeNews` | true | Close open trades before red-folder news |

#### Volatility Filter
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseVolFilter` | true | Enable volatility-adjusted entry |
| `InpATRMaxMultiple` | 2.0 | Max ATR ratio (skip if too wild) |
| `InpATRMinMultiple` | 0.5 | Min ATR ratio (skip if too quiet) |

#### Daily Loss Limit
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseDailyLossLimit` | true | Enable daily loss stop |
| `InpMaxDailyLossPct` | 20.0 | Max daily loss % (when dynamic risk is off) |

---

## Installation

1. Copy `.mq5` files to your MetaTrader 5 `MQL5/Experts/` folder
2. Compile in MetaEditor (F7)
3. Drag onto a **GOLD / XAUUSD M1** chart
4. Enable **AutoTrading**

## Chart Display

Real-time status overlay (primary EA):

```
--- N30 GOLD REVERSION v5 ---
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

## Design Rationale

- **Fixed-point SL** — ATR-based stops get clipped by gold spikes. Fixed 800-point SL survives volatility.
- **Z-Score TP** — mean reversion naturally targets Z=0. Closing at ±0.3 captures the snap-back without waiting for an arbitrary pip target.
- **Hard TP as safety net** — server-side TP protects against VPS disconnects. The Z-Score exit usually triggers first.
- **Dynamic risk tiers** — aggressive at micro level (10% risk), conservative as capital grows. Prevents giving back gains.
- **New-bar trailing** — trails only on bar close, not every tick. Reduces broker modify requests and avoids noise-triggered exits.
- **Dual strategy separation** — separate magic numbers let the two strategies in the Breakout EA open, manage, and close positions independently without interfering.

## Risk Warning

This EA is for **educational and research purposes**. Trading leveraged instruments carries significant risk. 10% risk per trade is aggressive and can blow a small account. Always test on demo first. Past performance does not guarantee future results.

## License

Copyright 2026, n30dyn4m1c
