//+------------------------------------------------------------------+
//|                                       XAU_Quant_Reversion.mq5    |
//|                                     Copyright 2026, n30dyn4m1c  |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2026, n30dyn4m1c"
#property link      ""
#property version   "5.00"
#property description "N30 Gold Reversion - Mean Reversion Z-Score EA"

//--- Inputs: Strategy
input string   InpTradeSymbol = "GOLD";        // Trade symbol (GOLD, XAUUSD, etc.)
string         TradeSymbol;
input double   InpEntryZ      = 2.0;      // Z-Score entry threshold
input bool     InpUseDynamicRisk = true;  // Enable equity-based risk tiers (overrides InpRiskPct)
input double   InpRiskPct     = 10.0;     // Risk % per trade (used when dynamic risk is off)
input double   InpSLPoints    = 800;      // Fixed SL in points (survives gold spikes)
input double   InpHardTPPoints = 1500;    // Hard TP in points (server-side safety net, wide)
input double   InpExitZ       = 0.5;      // Z-Score exit threshold (close when Z returns near 0)
input double   InpTrailingATR = 2.0;      // ATR multiplier for trailing
input double   InpMinProfitBuffer = 50.0; // Minimum profit buffer in points before breakeven triggers
input int      InpStartHour   = 10;       // Trade window start hour
input int      InpEndHour     = 20;       // Trade window end hour (exclusive)
input int      InpFridayCloseHour = 20;   // Friday hour to close and stop
input int      InpMaxHoldMinutes = 30;    // Max trade duration in minutes
input int      InpCooldownMins = 10;      // Pause after a losing trade, minutes (0 = disabled)
input int      InpMagic       = 777333;   // Magic number

//--- Inputs: Indicators
input int      InpMAPeriod    = 20;       // MA / StdDev period
input int      InpATRPeriod   = 14;       // ATR period
input int      InpFilterPeriodH1 = 50;   // H1 SMA period for trend filter (0 = disabled)
input int      InpADXPeriod   = 14;       // ADX period
input double   InpADXMax      = 25.0;     // Skip entries when ADX above this (0 = disabled)

//--- Inputs: Execution
input int      InpSlippage    = 30;       // Max slippage in points
input double   InpMaxSpreadPts = 50.0;    // Max allowed spread in points
input int      InpMaxPositions = 1;       // Max open positions allowed

//--- Inputs: News Filter (red folder / CALENDAR_IMPORTANCE_HIGH only)
input bool     InpUseNewsFilter      = true;  // Enable news time filter
input int      InpNewsMinsBefore     = 60;    // Minutes to pause BEFORE red-folder news
input int      InpNewsMinsAfter      = 120;   // Minutes to pause AFTER red-folder news (washout buffer)
input bool     InpCloseBeforeNews    = true;  // Close open trades before red-folder news

//--- Inputs: Daily Loss Limit
input bool     InpUseDailyLossLimit  = true;  // Enable max daily loss stop
input double   InpMaxDailyLossPct    = 20.0;  // Max daily loss % of balance (stops trading)

//--- Trade log: open-trade snapshot captured at entry
struct TradeRecord {
   ulong    ticket;
   datetime openTime;
   double   openPrice;
   double   lots;
   int      type;          // POSITION_TYPE_BUY or POSITION_TYPE_SELL
   double   openBalance;
   double   openEquity;
   double   zScore;
   double   atr;
   double   spreadAtEntry;
   double   riskPct;
   double   sl;
   double   tp;
   string   h1Status;
   string   comment;
};

//--- Global Handles & State
int handleMA, handleSD, handleATR, handleMA_H1, handleADX;
ulong       glTicket            = 0;   // active position ticket (0 = no open trade)
string      glPendingCloseReason = ""; // reason set by CloseAllOwnPositions, read on next tick
TradeRecord glTradeRecord;             // snapshot of the open trade
int         glTradeCount        = 0;   // cumulative trade counter (persists across sessions via file)
double      glZScore            = 0;   // Z-Score of last closed bar
bool        glZValid            = false; // false until first successful Z computation (guards exits after restart)
datetime    glLossCooldownUntil = 0;   // no new entries until this time after a losing trade
double spreadBuffer[20];
int    spreadIdx = 0;
bool   spreadBufferFull = false;

//--- News schedule: red folder (CALENDAR_IMPORTANCE_HIGH) only
#define MAX_NEWS 40
datetime newsRed[MAX_NEWS];
int newsRedCount = 0;
datetime lastNewsLoad = 0;

//--- Daily loss tracking
double dailyStartBalance = 0;
int    dailyStartDay = -1;
bool   dailyLossHit = false;

//--- New-bar tracking
datetime lastTrailBar = 0;
datetime lastBarTime = 0;

//--- Entry confirmation gate: filter out flash spikes
//    ExecuteTrade fires only after signal persists 3+ consecutive ticks OR 2+ seconds
int      glEntryConfirmTicks = 0;   // ticks that have confirmed the current signal
datetime glEntryConfirmStart = 0;   // wall-clock time of the first confirming tick
int      glEntryConfirmDir   = 0;   // 1 = buy signal, -1 = sell signal, 0 = no signal

//--- Price Velocity filter: block entry when price moves > 25% of M1 ATR within 10 ticks
#define VELOCITY_TICKS 10
double   glVelBuf[VELOCITY_TICKS];   // circular buffer of last 10 bid prices
datetime glVelTime[VELOCITY_TICKS];  // arrival time of each buffered tick
int      glVelIdx        = 0;      // write index
bool     glVelBufFull    = false;  // true once buffer has been filled once
datetime glVelBlockUntil = 0;      // entry blocked until this server time

//+------------------------------------------------------------------+
int OnInit() {
   // Initialize and validate symbol
   TradeSymbol = InpTradeSymbol;
   if(!SymbolInfoInteger(TradeSymbol, SYMBOL_EXIST)) {
      Print("Symbol ", TradeSymbol, " not found - trying XAUUSD");
      TradeSymbol = "XAUUSD";
      if(!SymbolInfoInteger(TradeSymbol, SYMBOL_EXIST)) {
         Print("Neither GOLD nor XAUUSD found. Please set TradeSymbol manually.");
         return(INIT_FAILED);
      }
   }
   // Ensure symbol is in Market Watch so indicator handles and quotes work
   if(!SymbolSelect(TradeSymbol, true)) {
      Print("Failed to add ", TradeSymbol, " to Market Watch");
      return(INIT_FAILED);
   }

   handleMA    = iMA(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleSD    = iStdDev(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleATR   = iATR(TradeSymbol, _Period, InpATRPeriod);

   if(InpFilterPeriodH1 > 0)
      handleMA_H1 = iMA(TradeSymbol, PERIOD_H1, InpFilterPeriodH1, 0, MODE_SMA, PRICE_CLOSE);
   else
      handleMA_H1 = INVALID_HANDLE;

   if(InpADXMax > 0)
      handleADX = iADX(TradeSymbol, _Period, InpADXPeriod);
   else
      handleADX = INVALID_HANDLE;

   if(handleMA == INVALID_HANDLE || handleSD == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE) {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }
   if(InpFilterPeriodH1 > 0 && handleMA_H1 == INVALID_HANDLE) {
      Print("Failed to create H1 MA handle");
      return(INIT_FAILED);
   }
   if(InpADXMax > 0 && handleADX == INVALID_HANDLE) {
      Print("Failed to create ADX handle");
      return(INIT_FAILED);
   }

   if(InpUseNewsFilter) LoadNewsEvents();
   InitTradeLog();

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dailyStartDay = dt.day_of_year;
   dailyLossHit = false;

   // Initialize bar trackers to current time to avoid immediate action on stale bars
   datetime currentBarTime = iTime(TradeSymbol, _Period, 0);
   lastBarTime = currentBarTime;
   lastTrailBar = currentBarTime;

   // Reset entry confirmation gate on (re)init
   glEntryConfirmDir   = 0;
   glEntryConfirmTicks = 0;
   glEntryConfirmStart = 0;

   // Reset price velocity filter on (re)init
   ArrayInitialize(glVelBuf, 0.0);
   for(int v = 0; v < VELOCITY_TICKS; v++) glVelTime[v] = 0;
   glVelIdx        = 0;
   glVelBufFull    = false;
   glVelBlockUntil = 0;

   // Seed Z-Score from the last closed bar so exits don't act on a bogus Z=0 after restart
   glZValid = false;
   UpdateZScore();

   // Recover an open position after restart so it keeps being managed
   // (without this, an orphaned position gets no trailing/exits and a
   //  fresh zScore of 0 would have instantly closed it as a false Gravity Exit)
   glTicket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      glTicket = ticket;
      glTradeRecord.ticket        = ticket;
      glTradeRecord.openTime      = (datetime)PositionGetInteger(POSITION_TIME);
      glTradeRecord.openPrice     = PositionGetDouble(POSITION_PRICE_OPEN);
      glTradeRecord.lots          = PositionGetDouble(POSITION_VOLUME);
      glTradeRecord.type          = (int)PositionGetInteger(POSITION_TYPE);
      glTradeRecord.openBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      glTradeRecord.openEquity    = AccountInfoDouble(ACCOUNT_EQUITY);
      glTradeRecord.zScore        = 0;
      glTradeRecord.atr           = 0;
      glTradeRecord.spreadAtEntry = 0;
      glTradeRecord.riskPct       = 0;
      glTradeRecord.sl            = PositionGetDouble(POSITION_SL);
      glTradeRecord.tp            = PositionGetDouble(POSITION_TP);
      glTradeRecord.h1Status      = "RECOVERED";
      glTradeRecord.comment       = PositionGetString(POSITION_COMMENT);
      Print("Recovered open position after restart: ticket=", ticket);
      break;
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//  UpdateZScore — Z-Score of the last closed bar (shift 1)
//+------------------------------------------------------------------+
void UpdateZScore() {
   double ma1[1], sd1[1];
   if(CopyBuffer(handleMA,0,1,1,ma1)>=1 && CopyBuffer(handleSD,0,1,1,sd1)>=1) {
      double close1 = iClose(TradeSymbol, _Period, 1);
      if(sd1[0] > 0.0) {
         glZScore = (close1 - ma1[0]) / sd1[0];
         glZValid = true;
      }
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(handleMA     != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleSD     != INVALID_HANDLE) IndicatorRelease(handleSD);
   if(handleATR    != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleMA_H1  != INVALID_HANDLE) IndicatorRelease(handleMA_H1);
   if(handleADX    != INVALID_HANDLE) IndicatorRelease(handleADX);
}

//+------------------------------------------------------------------+
//  Daily Loss Limit
//+------------------------------------------------------------------+
void CheckDailyReset() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != dailyStartDay) {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyStartDay = dt.day_of_year;
      dailyLossHit = false;
      Print("Daily loss tracker reset. Starting balance: ", dailyStartBalance);
   }
}

bool IsDailyLossLimitHit() {
   if(!InpUseDailyLossLimit) return false;
   if(dailyLossHit) return true;
   if(dailyStartBalance <= 0) return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = ((dailyStartBalance - equity) / dailyStartBalance) * 100.0;

   double dailyLimit = GetDailyLossLimitPct();
   if(lossPercent >= dailyLimit) {
      dailyLossHit = true;
      Print("DAILY LOSS LIMIT HIT: ", DoubleToString(lossPercent, 2), "% lost (limit ", DoubleToString(dailyLimit, 1), "%). Trading stopped for today.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//  News Filter — uses MQL5 economic calendar
//+------------------------------------------------------------------+
void LoadNewsEvents() {
   newsRedCount = 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   datetime dayStart = TimeCurrent() - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   // Extend past midnight so early-next-day events still trigger the pre-news pause
   datetime dayEnd   = dayStart + 86400 + InpNewsMinsBefore * 60;

   MqlCalendarValue values[];
   if(!CalendarValueHistory(values, dayStart, dayEnd)) return;
   int total = ArraySize(values);

   for(int i = 0; i < total; i++) {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;
      if(country.currency != "USD") continue;

      if(newsRedCount < MAX_NEWS) {
         newsRed[newsRedCount] = values[i].time;
         newsRedCount++;
      }
   }

   lastNewsLoad = TimeCurrent();
   Print("News loaded: ", newsRedCount, " (red folder) high-impact USD events today");
}

//+------------------------------------------------------------------+
bool IsNearNews() {
   if(!InpUseNewsFilter) return false;

   MqlDateTime dtNow, dtLast;
   TimeToStruct(TimeCurrent(), dtNow);
   TimeToStruct(lastNewsLoad, dtLast);
   if(dtNow.day_of_year != dtLast.day_of_year) LoadNewsEvents();

   datetime now = TimeCurrent();
   for(int i = 0; i < newsRedCount; i++) {
      long diff = (long)(newsRed[i] - now);
      if(diff > -(InpNewsMinsAfter * 60) && diff < (InpNewsMinsBefore * 60))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsRedNewsImminent() {
   if(!InpUseNewsFilter || !InpCloseBeforeNews) return false;

   datetime now = TimeCurrent();
   for(int i = 0; i < newsRedCount; i++) {
      long diff = (long)(newsRed[i] - now);
      if(diff > 0 && diff < (InpNewsMinsBefore * 60))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//  Dynamic Risk Tiers — scales risk down as equity grows
//+------------------------------------------------------------------+
double GetRiskPct() {
   if(!InpUseDynamicRisk) return InpRiskPct;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity < 500)        return 10.0;
   if(equity < 2000)       return 7.0;
   if(equity < 5000)       return 5.0;
   if(equity < 20000)      return 3.0;
   return 1.5;
}

double GetDailyLossLimitPct() {
   if(!InpUseDynamicRisk) return InpMaxDailyLossPct;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity < 500)        return 25.0;
   if(equity < 2000)       return 20.0;
   if(equity < 5000)       return 15.0;
   if(equity < 20000)      return 10.0;
   return 7.0;
}

//+------------------------------------------------------------------+
bool SelectOwnPosition() {
   if(glTicket == 0) return false;
   return PositionSelectByTicket(glTicket);
}

//+------------------------------------------------------------------+
int CountOwnPositions() {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic) {
         count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
string TruncateComment(string comment, int maxLen = 31) {
   if(StringLen(comment) <= maxLen) return comment;
   return StringSubstr(comment, 0, maxLen);
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot) {
   double minLot  = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, lot);
   lot = MathMin(maxLot, lot);
   // Strictly follow volume step using MathFloor to avoid 'Invalid Volume' errors
   lot = MathFloor(lot / stepLot) * stepLot;

   // Derive decimal places from step size without fragile float == comparison
   int digits = (int)MathRound(-MathLog10(stepLot + 1e-10));
   if(digits < 0) digits = 0;

   return NormalizeDouble(lot, digits);
}

//+------------------------------------------------------------------+
void CloseAllOwnPositions(string reason) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action   = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol   = TradeSymbol;
      req.volume   = PositionGetDouble(POSITION_VOLUME);
      long posType = PositionGetInteger(POSITION_TYPE);
      req.type     = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      
      double price = (req.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(TradeSymbol, SYMBOL_BID)
                                                   : SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
                                                   
      req.price    = NormalizeDouble(price, _Digits);
      req.deviation = InpSlippage;
      req.comment  = "N30 " + reason;
      uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
      if(fill & SYMBOL_FILLING_FOK) req.type_filling = ORDER_FILLING_FOK;
      else if(fill & SYMBOL_FILLING_IOC) req.type_filling = ORDER_FILLING_IOC;
      else req.type_filling = ORDER_FILLING_RETURN;

      if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
         Print("Close position failed (", reason, "): ticket=", ticket, " retcode=", res.retcode);
      } else {
         Print("Position closed (", reason, "): ticket=", ticket);
         if(ticket == glTicket) {
            glPendingCloseReason = reason;  // OnTick will detect close and log with this reason
         }
      }
   }
}

//+------------------------------------------------------------------+
//  IsWeekendRisk — block Friday late sessions and weekends
//+------------------------------------------------------------------+
bool IsWeekendRisk() {
   MqlDateTime dt;
   TimeCurrent(dt);
   // Friday late (>= InpFridayCloseHour) or Saturday (6) or Sunday (0)
   if((dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour) || dt.day_of_week == 6 || dt.day_of_week == 0)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//  H1 Trend Filter — skip M1 entries that fight the H1 structural trend
//+------------------------------------------------------------------+
bool IsAlignedWithH1Trend(bool isBuy) {
   if(InpFilterPeriodH1 <= 0 || handleMA_H1 == INVALID_HANDLE) return true;

   double h1ma[1];
   if(CopyBuffer(handleMA_H1, 0, 0, 1, h1ma) < 1) return true;  // fail open

   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   if(isBuy)  return bid > h1ma[0];  // only buy when price is above H1 SMA
   return bid < h1ma[0];             // only sell when price is below H1 SMA
}

//+------------------------------------------------------------------+
void OnTick() {
   CheckDailyReset();

   // Detect position close (works in both live and Strategy Tester)
   if(glTicket != 0 && !PositionSelectByTicket(glTicket)) {
      LogPositionClose(glPendingCloseReason);
      glTicket             = 0;
      glPendingCloseReason = "";
   }

   double ma[1], sd[1], atr[1];
   // We always need current data for spread and ATR (trailing)
   if(CopyBuffer(handleMA,0,0,1,ma)<1 || CopyBuffer(handleSD,0,0,1,sd)<1 ||
      CopyBuffer(handleATR,0,0,1,atr)<1) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   double bid   = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);

   // --- Spread Calculation & Buffer Update ---
   double currentSpread = (ask - bid) / point;
   spreadBuffer[spreadIdx] = currentSpread;
   spreadIdx++;
   if(spreadIdx >= 20) {
      spreadIdx = 0;
      spreadBufferFull = true;
   }
   
   double spreadSum = 0;
   int count = spreadBufferFull ? 20 : spreadIdx;
   for(int i = 0; i < count; i++) spreadSum += spreadBuffer[i];
   double spreadMA = (count > 0) ? (spreadSum / count) : currentSpread;

   // --- PRICE VELOCITY FILTER: update 10-tick bid buffer ---
   glVelBuf[glVelIdx]  = bid;
   glVelTime[glVelIdx] = TimeCurrent();
   glVelIdx++;
   if(glVelIdx >= VELOCITY_TICKS) { glVelIdx = 0; glVelBufFull = true; }
   if(glVelBufFull) {
      // oldest value is at current write position (about to be overwritten next tick)
      int oldIdx     = glVelIdx % VELOCITY_TICKS;
      int newIdx     = (glVelIdx + VELOCITY_TICKS - 1) % VELOCITY_TICKS;
      double velMove = MathAbs(glVelBuf[newIdx] - glVelBuf[oldIdx]);
      long   velSpan = (long)(glVelTime[newIdx] - glVelTime[oldIdx]);
      // Only a genuine spike counts: 10 ticks can span minutes in quiet markets,
      // and slow drift of 25% ATR over that span is normal, not a knife
      if(velSpan <= 10 && velMove > 0.25 * atr[0])
         glVelBlockUntil = TimeCurrent() + 3;  // block entries for 3 seconds
   }

   // --- NEW BAR DETECTION ---
   datetime currentTime = iTime(TradeSymbol, _Period, 0);
   bool isNewBar = (currentTime != lastBarTime);
   if(isNewBar) lastBarTime = currentTime; // STRICT OHLC: Update immediately so entry only runs once per bar

   // --- Z-Score Calculation (Shift 1 for OHLC alignment) ---
   // We only update Z-Score once per bar to match OHLC backtest signals
   if(isNewBar) UpdateZScore();
   double zScore = glZScore;

   // --- Live Z-Score (current bid vs current MA/SD) ---
   // Guards against stale signals: the closed-bar Z stays extreme for the whole
   // next bar even after price has already snapped back intra-bar
   double liveZ = (sd[0] > 0.0) ? (bid - ma[0]) / sd[0] : 0.0;

   // --- Volatility Ratio & Dynamic Z-Score Threshold ---
   double atrBuf100[100];
   double avgATR100 = 0;
   if(CopyBuffer(handleATR, 0, 0, 100, atrBuf100) >= 100) {
      double atrSum = 0;
      for(int k = 0; k < 100; k++) atrSum += atrBuf100[k];
      avgATR100 = atrSum / 100.0;
   } else {
      avgATR100 = atr[0]; // fallback: ratio = 1.0 (no adjustment)
   }
   double volRatio  = (avgATR100 > 0) ? (atr[0] / avgATR100) : 1.0;
   // Full threshold always; raised +0.5 in elevated volatility to avoid noise spikes.
   // (The old "soft" 0.75x threshold entered at Z~1.5 — too weak an extreme for
   //  mean reversion, producing many low-edge trades that mostly paid spread.)
   double entryZ    = InpEntryZ + (volRatio > 1.5 ? 0.5 : 0.0);

   bool nearNews        = IsNearNews();
   bool lossLimitHit    = IsDailyLossLimitHit();
   bool redNewsImminent = IsRedNewsImminent();
   bool weekendRisk     = IsWeekendRisk();

   // --- Spread Check ---
   double atrPts           = atr[0] / point;
   double maxAllowedSpread = atrPts * 0.12;  // block entry when spread > 12% of current M1 ATR
   bool spreadOk = (currentSpread <= maxAllowedSpread) &&     // ATR-relative gate
                   (currentSpread <= spreadMA * 1.5) &&       // liquidity-gap guard: no entry if spread > 1.5x 20-tick average
                   (currentSpread <= InpMaxSpreadPts);        // absolute cap

   // --- ADX Regime Filter: mean reversion only works in ranging markets ---
   bool   adxOk  = true;
   double adxVal = 0;
   if(InpADXMax > 0 && handleADX != INVALID_HANDLE) {
      double adxBuf[1];
      if(CopyBuffer(handleADX, 0, 0, 1, adxBuf) >= 1) {
         adxVal = adxBuf[0];
         adxOk  = (adxVal <= InpADXMax);
      }
   }

   // --- Loss Cooldown: no re-entry right after a losing trade ---
   bool cooldownOk = (TimeCurrent() >= glLossCooldownUntil);

   // --- Pre-compute filter states ---
   bool inWindow  = (dt.hour >= InpStartHour && dt.hour < InpEndHour);

   string h1Status = "OFF";
   if(InpFilterPeriodH1 > 0 && handleMA_H1 != INVALID_HANDLE) {
      double h1ma[1];
      if(CopyBuffer(handleMA_H1, 0, 0, 1, h1ma) >= 1)
         h1Status = (bid > h1ma[0]) ? "BULL" : "BEAR";
   }

   // --- DAILY LOSS: close everything and stop ---
   if(lossLimitHit) {
      if(SelectOwnPosition()) CloseAllOwnPositions("daily loss limit");
      Comment("--- N30 GOLD REVERSION (SIMPLE) ---\n",
              "DAILY LOSS LIMIT REACHED - TRADING STOPPED\n",
              "Loss: ", DoubleToString(((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0, 2), "%");
      return;
   }

   // --- FRIDAY EXIT / WEEKEND SAFETY ---
   if(weekendRisk) {
      if(SelectOwnPosition()) CloseAllOwnPositions("Friday Exit");
      Comment("--- N30 GOLD REVERSION (SIMPLE) ---\n",
              "WEEKEND PAUSE - NO NEW TRADES\n",
              "H1 Trend: ", h1Status);
      return;
   }

   // --- CLOSE BEFORE (RED FOLDER) HIGH-IMPACT NEWS ---
   if(redNewsImminent && SelectOwnPosition()) {
      CloseAllOwnPositions("(red folder) high-impact news imminent");
   }

   // --- POSITION MANAGEMENT (Every Tick) ---
   string tradeDurStr = "None";
   bool positionOpen = SelectOwnPosition();
   
   if(positionOpen) {
      long openTime = PositionGetInteger(POSITION_TIME);
      long durationSec = TimeCurrent() - openTime;
      int durMins = (int)(durationSec / 60);
      int durSecs = (int)(durationSec % 60);
      // Gravity Exit: exit Z decays 0.1 per every 5 mins open, floors at 0.0 after 15 mins
      double gravityExitZ = (durMins >= 15) ? 0.0 : MathMax(0.0, InpExitZ - (durMins / 5) * 0.1);
      tradeDurStr = IntegerToString(durMins) + "m " + IntegerToString(durSecs) + "s"
                  + " [ExitZ=" + DoubleToString(gravityExitZ, 2) + "]";

      // Time-Based Exit
      if(durMins >= InpMaxHoldMinutes) {
         CloseAllOwnPositions("Time Exit (" + tradeDurStr + ")");
      } else {
         // Z-Score TP: Gravity Exit — exit threshold decays toward 0 as trade ages
         // glZValid guard: never act on the uninitialized Z=0 right after a restart,
         // which would instantly close a recovered position as a false reversion
         long posType = PositionGetInteger(POSITION_TYPE);
         bool zRevert = false;
         if(glZValid) {
            if(posType == POSITION_TYPE_BUY && zScore >= -gravityExitZ) zRevert = true;
            if(posType == POSITION_TYPE_SELL && zScore <= gravityExitZ) zRevert = true;
         }

         if(zRevert) {
            CloseAllOwnPositions("Gravity Exit (Z=" + DoubleToString(zScore, 2) + " tgt=" + DoubleToString(gravityExitZ, 2) + ")");
         } else {
            // Breakeven: every tick — lock in no-loss once 1.5*ATR in profit
            CheckBreakeven(atr[0]);
            // Trail on new bar only
            if(currentTime != lastTrailBar) {
               lastTrailBar = currentTime;
               HandleTrailingStop(atr[0]);
            }
         }
      }
   } else { // --- ENTRY LOGIC (every tick, gated by flash-spike filter) ---
      if(CountOwnPositions() < InpMaxPositions) {
         bool baseFilters = (inWindow && spreadOk && !nearNews && adxOk && cooldownOk && glZValid);

         // Determine current signal direction (0 = no signal).
         // liveZ must still be stretched (90% of threshold): the closed-bar signal
         // alone would chase entries after the intra-bar snap-back already happened
         int signalDir = 0;
         if(baseFilters) {
            if(zScore < -entryZ && liveZ <= -entryZ * 0.9 && IsAlignedWithH1Trend(true))       signalDir =  1;
            else if(zScore > entryZ && liveZ >= entryZ * 0.9 && IsAlignedWithH1Trend(false))   signalDir = -1;
         }

         // --- Confirmation gate: accumulate or reset ---
         if(signalDir != 0 && signalDir == glEntryConfirmDir) {
            glEntryConfirmTicks++;                            // same direction: count up
         } else if(signalDir != 0) {
            glEntryConfirmDir   = signalDir;                 // new direction: start fresh
            glEntryConfirmTicks = 1;
            glEntryConfirmStart = TimeCurrent();
         } else {
            glEntryConfirmDir   = 0;                         // signal gone: reset
            glEntryConfirmTicks = 0;
            glEntryConfirmStart = 0;
         }

         // Fire only after 3+ consecutive ticks OR 2+ seconds of sustained signal,
         // and only when the price-velocity block has expired (no knife-catching)
         bool ticksOk = (glEntryConfirmTicks >= 3);
         bool timeOk  = (glEntryConfirmStart > 0 && (TimeCurrent() - glEntryConfirmStart) >= 2);
         bool velOk   = (TimeCurrent() >= glVelBlockUntil);
         if(glEntryConfirmDir != 0 && (ticksOk || timeOk) && velOk) {
            if(glEntryConfirmDir == 1)
               ExecuteTrade(ORDER_TYPE_BUY,  ask, atr[0], zScore);
            else
               ExecuteTrade(ORDER_TYPE_SELL, bid, atr[0], zScore);
            // Reset gate after firing to prevent double-entry
            glEntryConfirmDir   = 0;
            glEntryConfirmTicks = 0;
            glEntryConfirmStart = 0;
         }
      }
   }

   Comment("--- N30 GOLD REVERSION (SIMPLE) ---\n",
           "Z-Score(1): ", DoubleToString(zScore, 2),
           "  |  Live Z: ", DoubleToString(liveZ, 2),
           "  |  Z-Target: ", DoubleToString(entryZ, 2), "\n",
           "Volatility Ratio: ", DoubleToString(volRatio, 2),
           (volRatio > 1.5 ? "  [HIGH - Z raised +0.5]" : "  [normal]"), "\n",
           "ADX: ", DoubleToString(adxVal, 1), " / Max: ", DoubleToString(InpADXMax, 1),
           " ", (adxOk ? "OK" : "BLOCKED [trending]"), "\n",
           "H1 Trend: ", h1Status, "\n",
           "Spread: ", DoubleToString(currentSpread, 1),
           " / MaxAllowed: ", DoubleToString(maxAllowedSpread, 1),
           " (Avg20: ", DoubleToString(spreadMA, 1), ") ", (spreadOk ? "OK" : "BLOCKED"), "\n",
           "News: ", (nearNews ? "BLOCKED" : "clear"),
           (redNewsImminent ? " [CLOSING NOW]" : ""), "\n",
           "Velocity: ", (TimeCurrent() < glVelBlockUntil ? "BLOCKED (" + IntegerToString((int)(glVelBlockUntil - TimeCurrent())) + "s)" : "ok"), "\n",
           "Loss Cooldown: ", (cooldownOk ? "none" : IntegerToString((int)((glLossCooldownUntil - TimeCurrent()) / 60)) + "m remaining"), "\n",
           "Trade Duration: ", tradeDurStr);
}

//+------------------------------------------------------------------+
//  CheckBreakeven — move SL to entry + 10 pts once (1.5*ATR + Buffer) in profit
//+------------------------------------------------------------------+
void CheckBreakeven(double atrVal) {
   if(glTicket == 0 || !PositionSelectByTicket(glTicket)) return;

   double entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL   = PositionGetDouble(POSITION_SL);
   double currentTP   = PositionGetDouble(POSITION_TP);
   long   posType     = PositionGetInteger(POSITION_TYPE);
   double bid         = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask         = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double point       = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   int    stopLevel   = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double bePts       = 10.0 * point;
   double triggerDist = 1.5 * atrVal + InpMinProfitBuffer * point;   // ATR threshold + buffer

   if(posType == POSITION_TYPE_BUY) {
      if(bid < entryPrice + triggerDist) return;   // not (1.5*ATR + buffer) in profit yet
      double beSL = NormalizeDouble(entryPrice + bePts, _Digits);
      if(beSL <= currentSL) return;                // already at or beyond breakeven
      if(bid - beSL < stopLevel * point)
         beSL = NormalizeDouble(bid - stopLevel * point, _Digits);
      if(beSL > currentSL) {
         Print("Breakeven triggered (BUY): SL -> ", DoubleToString(beSL, _Digits));
         ModifySL(beSL, currentTP);
      }
   } else {
      if(ask > entryPrice - triggerDist) return;   // not (1.5*ATR + buffer) in profit yet
      double beSL = NormalizeDouble(entryPrice - bePts, _Digits);
      if(currentSL != 0 && beSL >= currentSL) return; // already at or beyond breakeven
      if(beSL - ask < stopLevel * point)
         beSL = NormalizeDouble(ask + stopLevel * point, _Digits);
      if(currentSL == 0 || beSL < currentSL) {
         Print("Breakeven triggered (SELL): SL -> ", DoubleToString(beSL, _Digits));
         ModifySL(beSL, currentTP);
      }
   }
}

//+------------------------------------------------------------------+
void HandleTrailingStop(double atrVal) {
   if(glTicket == 0 || !PositionSelectByTicket(glTicket)) return;

   // Time-decay: tighten trail by 50% after 50% of InpMaxHoldMinutes has elapsed
   long openTimeSec  = PositionGetInteger(POSITION_TIME);
   long durationSec  = TimeCurrent() - openTimeSec;
   long halfMaxSec   = (long)InpMaxHoldMinutes * 30;   // 50% of max hold in seconds
   double trailMult  = (durationSec > halfMaxSec) ? InpTrailingATR * 0.5 : InpTrailingATR;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   long type = PositionGetInteger(POSITION_TYPE);
   double trailDist = atrVal * trailMult;
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   int stopLevel = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL);

   double minMove = atrVal * 0.3;   // only modify if new SL is at least 0.3*ATR from current

   if(type == POSITION_TYPE_BUY) {
      double newSL = NormalizeDouble(bid - trailDist, _Digits);
      if(bid - newSL < stopLevel * point) newSL = NormalizeDouble(bid - stopLevel * point, _Digits);
      if(newSL > currentSL + minMove) ModifySL(newSL, currentTP);
   } else {
      double newSL = NormalizeDouble(ask + trailDist, _Digits);
      if(newSL - ask < stopLevel * point) newSL = NormalizeDouble(ask + stopLevel * point, _Digits);
      if(newSL < currentSL - minMove || currentSL == 0) ModifySL(newSL, currentTP);
   }
}

//+------------------------------------------------------------------+
void ModifySL(double nSL, double currentTP) {
   MqlTradeRequest r = {}; MqlTradeResult rs = {};
   r.action   = TRADE_ACTION_SLTP;
   r.position = glTicket;
   r.symbol   = TradeSymbol;
   r.sl       = NormalizeDouble(nSL, _Digits);
   r.tp       = NormalizeDouble(currentTP, _Digits);
   if(!OrderSend(r, rs) || rs.retcode != TRADE_RETCODE_DONE) {
      Print("TrailSL modify failed: retcode=", rs.retcode);
   }
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double p, double a, double zScore) {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double bid   = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   int stopLevel = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL);

   double slD = InpSLPoints * point;
   double tpD = InpHardTPPoints * point;

   // Apply SYMBOL_TRADE_STOPS_LEVEL safety
   if(slD < stopLevel * point) slD = stopLevel * point + 5 * point;
   if(tpD < stopLevel * point) tpD = stopLevel * point + 5 * point;

   double sl = (type == ORDER_TYPE_BUY) ? (p - slD) : (p + slD);
   double tp = (type == ORDER_TYPE_BUY) ? (p + tpD) : (p - tpD);
   double riskPct = GetRiskPct();
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * (riskPct / 100.0);
   double tickV = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickS = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickV <= 0 || tickS <= 0) {
      Print("Invalid tick value/size, skipping trade");
      return;
   }

   double lot = risk / (slD * (1.0 / tickS) * tickV);
   lot = NormalizeLot(lot);

   double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   if(lot < minLot) {
      Print("Calculated lot (", DoubleToString(lot, 3), ") below broker minimum (", DoubleToString(minLot, 3), "). Insufficient balance for this risk level.");
      return;
   }

   // Check sufficient margin before opening trade
   double marginRequired;
   if(!OrderCalcMargin(type, TradeSymbol, lot, p, marginRequired)) {
      Print("Failed to calculate margin, skipping trade");
      return;
   }
   if(marginRequired > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      Print("Insufficient margin: required=", marginRequired, " free=", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return;
   }

   string dir = (type == ORDER_TYPE_BUY) ? "B" : "S";
   string comment = TruncateComment("N30 " + dir
                   + "|Z" + DoubleToString(zScore, 2)
                   + "|R" + DoubleToString(a, 2));

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = TradeSymbol;
   req.volume       = lot;
   req.type         = type;
   req.price        = NormalizeDouble(p, _Digits);
   req.magic        = InpMagic;
   req.sl           = NormalizeDouble(sl, _Digits);
   req.tp           = NormalizeDouble(tp, _Digits);
   req.deviation    = InpSlippage;
   req.comment      = comment;
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   if(fill & SYMBOL_FILLING_FOK) req.type_filling = ORDER_FILLING_FOK;
   else if(fill & SYMBOL_FILLING_IOC) req.type_filling = ORDER_FILLING_IOC;
   else req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("Entry failed: retcode=", res.retcode, " comment=", res.comment);
   } else {
      // Capture position ticket: the deal's DEAL_POSITION_ID is the position
      // ticket on both netting and hedging accounts; fall back to res.order
      // then res.deal if the deal isn't in history yet.
      glTicket = 0;
      if(res.deal > 0 && HistoryDealSelect(res.deal))
         glTicket = (ulong)HistoryDealGetInteger(res.deal, DEAL_POSITION_ID);
      bool posSelected = (glTicket != 0) && PositionSelectByTicket(glTicket);
      if(!posSelected) {
         glTicket    = res.order;
         posSelected = PositionSelectByTicket(glTicket);
      }
      if(!posSelected) {
         glTicket    = res.deal;
         posSelected = PositionSelectByTicket(glTicket);
      }
      // Snapshot open-trade details for the trade log
      glTradeRecord.ticket        = glTicket;
      glTradeRecord.openTime      = posSelected ? (datetime)PositionGetInteger(POSITION_TIME) : TimeCurrent();
      glTradeRecord.openPrice     = p;
      glTradeRecord.lots          = lot;
      glTradeRecord.type          = (type == ORDER_TYPE_BUY) ? (int)POSITION_TYPE_BUY : (int)POSITION_TYPE_SELL;
      glTradeRecord.openBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      glTradeRecord.openEquity    = AccountInfoDouble(ACCOUNT_EQUITY);
      glTradeRecord.zScore        = zScore;
      glTradeRecord.atr           = a;
      glTradeRecord.spreadAtEntry = (ask - bid) / point;
      glTradeRecord.riskPct       = riskPct;
      glTradeRecord.sl            = NormalizeDouble(sl, _Digits);
      glTradeRecord.tp            = NormalizeDouble(tp, _Digits);
      string h1Stat = "OFF";
      if(InpFilterPeriodH1 > 0 && handleMA_H1 != INVALID_HANDLE) {
         double h1buf[1];
         if(CopyBuffer(handleMA_H1, 0, 0, 1, h1buf) >= 1)
            h1Stat = (bid > h1buf[0]) ? "BULL" : "BEAR";
      }
      glTradeRecord.h1Status      = h1Stat;
      glTradeRecord.comment       = comment;

      Print("Trade opened: ticket=", glTicket, " ", EnumToString(type), " ", lot,
            " lots, SL=", NormalizeDouble(sl, _Digits),
            " TP(hard)=", NormalizeDouble(tp, _Digits), " exitZ=", InpExitZ);
   }
}
//+------------------------------------------------------------------+
// OnTradeTransaction — kept for broker-side state sync only.
// All trade logging is handled in OnTick via LogPositionClose().
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result) {
}

//+------------------------------------------------------------------+
//  LogPositionClose — called from OnTick when position disappears.
//  Scans deal history for the closing deal so it works in both live
//  trading and the Strategy Tester (where OnTradeTransaction is unreliable).
//+------------------------------------------------------------------+
void LogPositionClose(string reason) {
   datetime from = (glTradeRecord.openTime > 0) ? glTradeRecord.openTime : TimeCurrent() - 86400;
   if(!HistorySelect(from, TimeCurrent() + 1)) {
      Print("LogPositionClose: HistorySelect failed");
      return;
   }

   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--) {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      // Match by position ID (= glTradeRecord.ticket on both netting and hedging accounts)
      if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != glTradeRecord.ticket) continue;

      datetime closeTime   = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      double   closePrice  = HistoryDealGetDouble(deal, DEAL_PRICE);
      double   grossProfit = HistoryDealGetDouble(deal, DEAL_PROFIT);
      double   swap        = HistoryDealGetDouble(deal, DEAL_SWAP);
      double   commission  = HistoryDealGetDouble(deal, DEAL_COMMISSION);
      string   closeReason = (reason != "") ? reason : HistoryDealGetString(deal, DEAL_COMMENT);

      WriteTradeResult(closeTime, closePrice, grossProfit, swap, commission, closeReason);
      return;
   }
   Print("LogPositionClose: no closing deal found in history for ticket=", glTradeRecord.ticket);
}

//+------------------------------------------------------------------+
//  InitTradeLog — count existing trades and write CSV header if new
//+------------------------------------------------------------------+
void InitTradeLog() {
   string filename = "N30_TradeLog_" + TradeSymbol + "_M" + IntegerToString(InpMagic) + ".csv";
   int handle = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(handle == INVALID_HANDLE) {
      Print("Trade log ERROR: cannot open '", filename, "' error=", GetLastError());
      return;
   }

   if(FileSize(handle) == 0) {
      // Brand-new file — write CSV header immediately so it's visible on attach
      FileWriteString(handle,
         "TradeNum,Ticket,OpenTime,CloseTime,Duration_mins,Type,Lots,"
         "OpenPrice,ClosePrice,SL,TP,"
         "ZScore,ATR,SpreadPts,RiskPct,"
         "EquityAtOpen,BalAtOpen,GrossProfit,Swap,Commission,NetPnL,BalAfter,"
         "H1Trend,CloseReason\n");
      FileClose(handle);
      Print("Trade log: new CSV created — '", filename,
            "' (Live: MQL5/Files/ | Tester: MQL5/Tester/Files/)");
      return;
   }

   // Count existing trade rows (data lines start with a digit, header starts with 'T')
   glTradeCount = 0;
   while(!FileIsEnding(handle)) {
      string line = FileReadString(handle);
      if(StringLen(line) > 0 && line[0] >= '0' && line[0] <= '9') glTradeCount++;
   }
   FileClose(handle);

   Print("Trade log: '", filename, "' — ", glTradeCount, " existing trades");
}

//+------------------------------------------------------------------+
//  WriteTradeResult — append one CSV row to the trade log
//+------------------------------------------------------------------+
void WriteTradeResult(datetime closeTime, double closePrice,
                      double grossProfit, double swap, double commission,
                      string closeReason) {
   glTradeCount++;
   double netPnL         = grossProfit + swap + commission;
   double closingBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Loss cooldown: the frozen closed-bar Z is often still extreme right after a
   // stop-out/time-exit, so an immediate re-entry walks straight back into the move
   if(netPnL < 0 && InpCooldownMins > 0) {
      glLossCooldownUntil = TimeCurrent() + (long)InpCooldownMins * 60;
      Print("Losing trade — entry cooldown until ", TimeToString(glLossCooldownUntil, TIME_DATE|TIME_MINUTES));
   }
   long   durationSec    = (long)closeTime - (long)glTradeRecord.openTime;
   int    durationMins   = (int)(durationSec / 60);

   string filename = "N30_TradeLog_" + TradeSymbol + "_M" + IntegerToString(InpMagic) + ".csv";
   int handle = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(handle == INVALID_HANDLE) {
      Print("WriteTradeResult: cannot open '", filename, "' error=", GetLastError());
      glTradeCount--;
      return;
   }

   if(FileSize(handle) == 0) {
      // Write CSV header on a brand-new file
      FileWriteString(handle,
         "TradeNum,Ticket,OpenTime,CloseTime,Duration_mins,Type,Lots,"
         "OpenPrice,ClosePrice,SL,TP,"
         "ZScore,ATR,SpreadPts,RiskPct,"
         "EquityAtOpen,BalAtOpen,GrossProfit,Swap,Commission,NetPnL,BalAfter,"
         "H1Trend,CloseReason\n");
   } else {
      FileSeek(handle, 0, SEEK_END);
   }

   string typeStr = (glTradeRecord.type == (int)POSITION_TYPE_BUY) ? "BUY" : "SELL";

   // Escape close reason for CSV (replace commas and quotes)
   string reasonEsc = closeReason;
   StringReplace(reasonEsc, "\"", "\"\"");
   if(StringFind(reasonEsc, ",") >= 0) reasonEsc = "\"" + reasonEsc + "\"";

   string line = StringFormat(
      "%d,%I64u,%s,%s,%d,%s,%.2f,"
      "%.5f,%.5f,%.5f,%.5f,"
      "%.4f,%.5f,%.1f,%.2f,"
      "%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,"
      "%s,%s\n",
      glTradeCount,
      glTradeRecord.ticket,
      TimeToString(glTradeRecord.openTime, TIME_DATE|TIME_SECONDS),
      TimeToString(closeTime,              TIME_DATE|TIME_SECONDS),
      durationMins,
      typeStr,
      glTradeRecord.lots,
      glTradeRecord.openPrice,
      closePrice,
      glTradeRecord.sl,
      glTradeRecord.tp,
      glTradeRecord.zScore,
      glTradeRecord.atr,
      glTradeRecord.spreadAtEntry,
      glTradeRecord.riskPct,
      glTradeRecord.openEquity,
      glTradeRecord.openBalance,
      grossProfit,
      swap,
      commission,
      netPnL,
      closingBalance,
      glTradeRecord.h1Status,
      reasonEsc);

   FileWriteString(handle, line);
   FileClose(handle);

   Print("Trade #", glTradeCount, " logged | ticket=", glTradeRecord.ticket,
         " | ", typeStr, " | NetPnL=", StringFormat("%+.2f", netPnL),
         " | Balance=", DoubleToString(closingBalance, 2),
         " | Reason: ", closeReason);
}
//+------------------------------------------------------------------+
// This work is my worship unto GOD