# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MetaTrader 5 Expert Advisor (EA) for automated gold (XAUUSD) trading. Written in MQL5.

**Primary EA**: `XAU_Quant_Reversion.mq5` - Mean reversion scalper using Z-Score
**Secondary EA**: `XAU_Quant_Reversion_Breakout.mq5` - Dual strategy combining mean reversion + Donchian channel breakout

## Build & Deploy

1. Copy `.mq5` files to MetaTrader 5's `MQL5/Experts/` folder
2. Open in MetaEditor and press F7 to compile (produces `.ex5` binary)
3. Attach to GOLD/XAUUSD M1 chart with AutoTrading enabled

No external dependencies. MQL5 is compiled within MetaEditor.

## Architecture

### Core Strategy Logic (XAU_Quant_Reversion.mq5)

**Entry**: Z-Score measures how many standard deviations price is from its SMA. Enters when Z-Score exceeds threshold (±2.4) indicating statistical extremes.

**Entry Filters** (all must pass):
- ADX < 20 (market is ranging, not trending)
- Spread < 50 points
- ATR ratio between 0.5x-2.0x of 50-period average (volatility filter)
- Trading session window (10:00-20:00 broker time)
- No high-impact USD news (uses MQL5 `CalendarValueHistory` API)

**Exit Priority**:
1. Z-Score TP - closes when Z returns to ±0.3 (mean reversion complete)
2. ATR trailing stop (new bar only, not every tick)
3. Fixed SL (800 points - survives gold spikes)
4. Hard TP (1500 points - server-side safety net)

**Dynamic Risk Tiers** (`GetRiskPct()`, `GetDailyLossLimitPct()`):
- Risk and daily loss limits auto-scale based on equity thresholds
- Aggressive at micro level (10% risk under $500), conservative as capital grows (1.5% risk above $20k)

### Dual Strategy (XAU_Quant_Reversion_Breakout.mq5)

Combines mean reversion with Donchian channel trend breakout:
- Mean Reversion: same as primary EA (ADX < 20)
- Trend Breakout: Donchian channel breakout when ADX > 30, with EMA and DI+/DI- confirmation

Uses separate magic numbers (777333 for MR, 777444 for TB) to manage positions independently.

### Key Constants

- `MAX_NEWS = 40` - max high-impact news events cached per day
- `InpMagic = 777333` - position identification
- SL/TP in points (not pips) - 800 pts SL, 1500 pts hard TP

## MQL5-Specific Notes

- Indicator handles created in `OnInit()`, released in `OnDeinit()`
- Position iteration via `PositionsTotal()` / `PositionGetTicket()`
- Order execution via `OrderSend()` with `MqlTradeRequest`/`MqlTradeResult`
- News data from `CalendarValueHistory()` - only `CALENDAR_IMPORTANCE_HIGH` (red folder) is filtered
- Fill mode detection: check `SYMBOL_FILLING_MODE` for FOK/IOC support

## After Every EA Update

After every update to any `.mq5` EA file, ensure this comment is the very last line of the file:
```
// This work is my worship unto GOD
```
