# Quant Mean Reversion Scalpers

Two **mean-reversion scalping EAs** for MetaTrader 5, designed for aggressive small-account growth on XM Global micro accounts. Both use Z-Score deviations from a moving average to identify statistically extreme price levels, then trade the snap-back.

## EAs

| EA | File | Symbol | Timeframe | SL | TP | R:R |
|----|------|--------|-----------|----|----|-----|
| **Gold Quant** | `gold-quant-simple-ea.mq5` | GOLD (XAUUSD) | M5 | 1.2 ATR | 2.0 ATR | 1.67:1 |
| **BTC Quant** | `bitcoin-quant-simple-ea.mq5` | BTCUSD | M15 | 1.5 ATR | 1.5 ATR | 1:1 |

Both are built for a **$50 account at 10% risk per trade** (0.01 lot sizing). No partial closes, no trailing stops — just hard SL/TP on the server.

## How It Works

### Entry

The EA calculates a **Z-Score** — how many standard deviations price is from its SMA. When price is stretched and filters agree, it enters:

- **Z-Score < -threshold** -> BUY (price is abnormally low)
- **Z-Score > +threshold** -> SELL (price is abnormally high)

**Filters that must pass before entry:**

| Filter | Gold | BTC | Purpose |
|--------|------|-----|---------|
| Z-Score | > 2.2 | > 2.2 | Price is statistically extreme |
| ADX | < 25 | < 22 | Market is ranging, not trending |
| RSI | off | on (38/62) | BTC needs momentum confirmation to avoid fading trends |
| Spread | < 35 pts | < 5000 pts | Avoids bad fills during illiquid conditions |
| Session | 08:00-20:00 GMT+2 | 24/7 | Gold needs London+NY; BTC trades around the clock |

### Exit

Simple and clean — three possible exits:

1. **Hard TP hit** — server-side, survives disconnects
2. **Hard SL hit** — server-side, survives disconnects
3. **Loser cut** — EA closes underwater trades after N bars (Gold: 4 bars/20min, BTC: 3 bars/45min)
4. **Stall cut** — EA closes stagnant trades after N bars if profit < threshold (Gold: 8 bars/40min, BTC: 6 bars/90min)

### Risk Sizing

Each trade risks **10% of account balance**. Lot size is calculated from the SL distance and symbol tick value. On a $50 account this produces 0.01 lots (minimum on XM micro).

### Daily Loss Limit

If equity drops **25%** from the day's starting balance, the EA closes all positions and stops trading until the next day.

## Input Parameters

### Strategy
| Parameter | Gold Default | BTC Default | Description |
|-----------|-------------|-------------|-------------|
| `TradeSymbol` | GOLD | BTCUSD | Symbol to trade |
| `InpEntryZ` | 2.2 | 2.2 | Z-Score threshold for entry |
| `InpADXFilter` | 25 | 22 | ADX must be below this (ranging market) |
| `InpRiskPct` | 10.0 | 10.0 | Risk % of balance per trade |
| `InpATRStop` | 1.2 | 1.5 | ATR multiplier for stop loss |
| `InpHardTP_ATR` | 2.0 | 1.5 | ATR multiplier for take profit |
| `InpStartHour` | 8 | 0 | Trading window start (GMT+2) |
| `InpEndHour` | 20 | 24 | Trading window end (GMT+2) |
| `InpStallBars` | 8 | 6 | Close stalled trade after N bars |
| `InpStallMinATR` | 0.2 | 0.2 | Min ATR profit within stall window |
| `InpLoserBars` | 4 | 3 | Close if underwater after N bars |
| `InpMagic` | 777333 | 777444 | Magic number for position ID |

### Indicators
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpMAPeriod` | 20 | SMA and StdDev period |
| `InpATRPeriod` | 14 | ATR period |
| `InpADXPeriod` | 14 | ADX period |
| `InpRSIPeriod` | 14 | RSI period |

### RSI Confirmation
| Parameter | Gold Default | BTC Default | Description |
|-----------|-------------|-------------|-------------|
| `InpUseRSIFilter` | false | true | Enable RSI confirmation |
| `InpRSIOversold` | 35 | 38 | RSI must be below this for BUY |
| `InpRSIOverbought` | 65 | 62 | RSI must be above this for SELL |

### Execution
| Parameter | Gold Default | BTC Default | Description |
|-----------|-------------|-------------|-------------|
| `InpSlippage` | 30 | 50 | Max slippage in points |
| `InpMaxSpreadPts` | 35 | 5000 | Max spread in points |

### Daily Loss Limit
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseDailyLossLimit` | true | Enable daily loss stop |
| `InpMaxDailyLossPct` | 25.0 | Max daily loss % before stopping |

## Installation

1. Copy the `.mq5` file(s) to your MetaTrader 5 `MQL5/Experts/` folder
2. Compile in MetaEditor
3. Drag onto a chart with the correct symbol and timeframe:
   - Gold EA -> **GOLD / XAUUSD M5** chart
   - BTC EA -> **BTCUSD M15** chart
4. Enable **AutoTrading**

## Chart Display

Both EAs show a real-time status overlay:

```
--- GOLD QUANT MICRO v5 ---
Equity: $52.30
Z-Score: -1.45
ADX: 16.3
ATR: 4.82
Spread: 25.0 pts
Daily P/L: +4.60% / -25.0% limit
```

## Design Rationale

These EAs are intentionally simple. On a $50 micro account:

- **No partial closes** — at 0.01 lots you can't split a position. Every partial close would fail.
- **No trailing stops** — with minimum lot size, the only clean exit is a hard SL or hard TP on the server.
- **Hard TP always set** — protects against VPS disconnects and MT5 crashes. On a small account, one missed exit is catastrophic.
- **RSI on for BTC, off for gold** — gold mean-reverts reliably in ranges. BTC has fat tails and trends harder, so RSI prevents fading momentum moves.

## Risk Warning

These EAs are for **educational and research purposes**. Trading leveraged instruments carries significant risk. 10% risk per trade is aggressive and can blow an account quickly. Always test on demo first. Past performance does not guarantee future results.

## License

Copyright 2026, Gemini Quant Lab
