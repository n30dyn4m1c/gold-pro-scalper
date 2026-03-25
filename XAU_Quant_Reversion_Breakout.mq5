//+------------------------------------------------------------------+
//|                              XAU_Quant_Reversion_Breakout.mq5    |
//|                                  Copyright 2026, Gemini Quant Lab |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini Quant Lab"
#property link      ""
#property version   "1.00"
#property description "Gold Dual Strategy: Mean Reversion + Trend Breakout"
#property description "Reversion trades ranging markets (ADX<20), Breakout trades trending (ADX>25)"

//=== SHARED INPUTS ===
input string   _shared_         = "=== SHARED SETTINGS ===";
input string   InpTradeSymbol   = "GOLD";        // Trade symbol (GOLD, XAUUSD, etc.)
string         TradeSymbol;
input bool     InpUseDynamicRisk = true;    // Enable equity-based risk tiers
input double   InpRiskPct       = 10.0;     // Risk % per trade (Mean Reversion, when dynamic off)
input double   InpTBRiskPct     = 3.0;      // Risk % per trade (Trend Breakout, when dynamic off)
input int      InpStartHour     = 10;        // Trade window start hour
input int      InpEndHour       = 20;       // Trade window end hour (exclusive)
input int      InpSlippage      = 30;       // Max slippage in points
input double   InpMaxSpreadPts  = 50.0;     // Max allowed spread in points
input int      InpMaxMRPositions = 1;       // Max Mean Reversion positions
input int      InpMaxTBPositions = 1;       // Max Trend Breakout positions

//=== MEAN REVERSION INPUTS ===
input string   _reversion_      = "=== MEAN REVERSION ===";
input bool     InpUseReversion  = true;     // Enable Mean Reversion strategy
input double   InpEntryZ        = 2.4;      // Z-Score entry threshold
input double   InpExitZ         = 0.3;      // Z-Score exit threshold (close when Z returns near 0)
input int      InpMRAdxFilter   = 20;       // ADX below this = ranging
input double   InpMRSLPoints    = 800;      // Fixed SL in points (survives gold spikes)
input double   InpMRHardTPPoints = 1500;    // Hard TP in points (server-side safety net)
input double   InpMRTrailingATR = 1.5;      // ATR multiplier for trailing
input int      InpMAPeriod      = 20;       // MA / StdDev period
input int      InpMRMagic       = 777333;   // Magic number (Mean Reversion)

//=== TREND BREAKOUT INPUTS ===
input string   _breakout_       = "=== TREND BREAKOUT ===";
input bool     InpUseBreakout   = true;     // Enable Trend Breakout strategy
input int      InpDonchianPeriod = 30;      // Donchian Channel lookback (bars)
input int      InpTBAdxThreshold = 30;      // ADX above this = trending
input double   InpTBSLPoints    = 1000;     // Fixed SL in points (wider for trends)
input double   InpTBHardTPPoints = 2000;    // Hard TP in points (server-side safety net)
input double   InpTBTrailingATR = 2.0;      // ATR multiplier for trailing (wider for trends)
input int      InpEMAPeriod     = 50;       // EMA for trend direction confirmation
input int      InpCooldownBars  = 10;       // Bars to wait after loss before re-entry
input double   InpMinDISpread   = 5.0;      // Min DI+/DI- spread for entry
input int      InpTBMagic       = 777444;   // Magic number (Trend Breakout)

//=== SHARED INDICATOR INPUTS ===
input string   _indicators_     = "=== INDICATORS ===";
input int      InpATRPeriod     = 14;       // ATR period
input int      InpADXPeriod     = 14;       // ADX period

//=== NEWS FILTER (red folder / CALENDAR_IMPORTANCE_HIGH only) ===
input string   _news_           = "=== NEWS FILTER ===";
input bool     InpUseNewsFilter      = true;
input int      InpNewsMinsBefore     = 60;
input int      InpNewsMinsAfter      = 60;
input bool     InpCloseBeforeNews    = true;

//=== DAILY LOSS LIMIT ===
input string   _loss_           = "=== DAILY LOSS LIMIT ===";
input bool     InpUseDailyLossLimit  = true;
input double   InpMaxDailyLossPct    = 20.0;

//=== VOLATILITY FILTER ===
input string   _vol_            = "=== VOLATILITY FILTER ===";
input bool     InpUseVolFilter    = true;
input double   InpATRMaxMultiple  = 2.0;   // Max ATR ratio (MR: skip if too wild)
input double   InpATRMinMultiple  = 0.5;   // Min ATR ratio (both: skip if too quiet)

//--- Global Handles
int handleMA, handleSD, handleATR, handleADX, handleATR50, handleEMA;

//--- Mean Reversion state
datetime lastMRTrailBar = 0;
ulong partialClosedTicket = 0;  // Tracks MR position that has been partially closed

//--- Trend Breakout state
datetime lastBarTime = 0;
datetime lastTBTrailBar = 0;
int barsSinceClose = 999;

//--- Track last position counts for cooldown detection
int lastMRCount = 0;
int lastTBCount = 0;

//--- News schedule: red folder (CALENDAR_IMPORTANCE_HIGH) only
#define MAX_NEWS 40
datetime newsRed[MAX_NEWS];
int newsRedCount = 0;
datetime lastNewsLoad = 0;


//--- Daily loss tracking
double dailyStartBalance = 0;
int    dailyStartDay = -1;
bool   dailyLossHit = false;

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

   handleMA    = iMA(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleSD    = iStdDev(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleATR   = iATR(TradeSymbol, _Period, InpATRPeriod);
   handleADX   = iADX(TradeSymbol, _Period, InpADXPeriod);
   handleATR50 = iATR(TradeSymbol, _Period, 50);
   handleEMA   = iMA(TradeSymbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(handleMA == INVALID_HANDLE || handleSD == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE || handleADX == INVALID_HANDLE ||
      handleATR50 == INVALID_HANDLE || handleEMA == INVALID_HANDLE) {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   if(InpUseNewsFilter) LoadNewsEvents();

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dailyStartDay = dt.day_of_year;
   dailyLossHit = false;

   Print("Dual Strategy EA initialized. Reversion=", InpUseReversion, " Breakout=", InpUseBreakout);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(handleMA    != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleSD    != INVALID_HANDLE) IndicatorRelease(handleSD);
   if(handleATR   != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleADX   != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleATR50 != INVALID_HANDLE) IndicatorRelease(handleATR50);
   if(handleEMA   != INVALID_HANDLE) IndicatorRelease(handleEMA);
}

//+------------------------------------------------------------------+
//  SHARED UTILITIES
//+------------------------------------------------------------------+
string TruncateComment(string comment, int maxLen = 31) {
   if(StringLen(comment) <= maxLen) return comment;
   return StringSubstr(comment, 0, maxLen);
}

//+------------------------------------------------------------------+
//  Dynamic Risk Tiers — scales risk down as equity grows
//+------------------------------------------------------------------+
double GetRiskPct(bool isTrendBreakout = false) {
   if(!InpUseDynamicRisk) return isTrendBreakout ? InpTBRiskPct : InpRiskPct;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double baseRisk;
   if(equity < 500)        baseRisk = 10.0;
   else if(equity < 2000)  baseRisk = 7.0;
   else if(equity < 5000)  baseRisk = 5.0;
   else if(equity < 20000) baseRisk = 3.0;
   else                    baseRisk = 1.5;

   // Trend breakout uses ~30% of MR risk (more conservative for trends)
   return isTrendBreakout ? baseRisk * 0.3 : baseRisk;
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

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = ((dailyStartBalance - equity) / dailyStartBalance) * 100.0;

   double dailyLimit = GetDailyLossLimitPct();
   if(lossPercent >= dailyLimit) {
      dailyLossHit = true;
      Print("DAILY LOSS LIMIT HIT: ", DoubleToString(lossPercent, 2), "% lost (limit ", DoubleToString(dailyLimit, 1), "%). Trading stopped.");
      return true;
   }
   return false;
}

double NormalizeLot(double lot) {
   double minLot  = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, lot);
   lot = MathMin(maxLot, lot);
   lot = MathFloor(lot / stepLot) * stepLot;
   lot = NormalizeDouble(lot, 2);
   return lot;
}

//+------------------------------------------------------------------+
//  NEWS FILTER
//+------------------------------------------------------------------+
void LoadNewsEvents() {
   newsRedCount = 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   datetime dayStart = TimeCurrent() - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   datetime dayEnd   = dayStart + 86400;

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
//  VOLATILITY FILTER
//+------------------------------------------------------------------+
bool IsVolOkForReversion(double atrFast) {
   if(!InpUseVolFilter) return true;
   double atrSlow[1];
   if(CopyBuffer(handleATR50, 0, 0, 1, atrSlow) < 1) return true;
   if(atrSlow[0] <= 0) return true;
   double ratio = atrFast / atrSlow[0];
   return (ratio >= InpATRMinMultiple && ratio <= InpATRMaxMultiple);
}

bool IsVolOkForBreakout(double atrFast) {
   if(!InpUseVolFilter) return true;
   double atrSlow[1];
   if(CopyBuffer(handleATR50, 0, 0, 1, atrSlow) < 1) return true;
   if(atrSlow[0] <= 0) return true;
   double ratio = atrFast / atrSlow[0];
   // Breakout needs above-average vol, no upper cap
   return (ratio >= InpATRMinMultiple);
}

//+------------------------------------------------------------------+
//  POSITION HELPERS
//+------------------------------------------------------------------+
bool SelectPositionByMagic(long magic) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol &&
         PositionGetInteger(POSITION_MAGIC) == magic) {
         return true;
      }
   }
   return false;
}

int CountPositionsByMagic(long magic) {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol &&
         PositionGetInteger(POSITION_MAGIC) == magic) {
         count++;
      }
   }
   return count;
}

bool IsPartialClosed() {
   ulong currentTicket = (ulong)PositionGetInteger(POSITION_TICKET);
   return (currentTicket == partialClosedTicket);
}

void ClosePositionsByMagic(long magic, string reason) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action   = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol   = TradeSymbol;
      req.volume   = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      req.type     = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price    = (req.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(TradeSymbol, SYMBOL_BID)
                                                   : SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
      req.deviation = InpSlippage;
      req.comment  = reason;
      uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
      if(fill & SYMBOL_FILLING_FOK) req.type_filling = ORDER_FILLING_FOK;
      else if(fill & SYMBOL_FILLING_IOC) req.type_filling = ORDER_FILLING_IOC;
      else req.type_filling = ORDER_FILLING_RETURN;

      if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
         Print("Close failed (", reason, "): ticket=", ticket, " retcode=", res.retcode);
      } else {
         Print("Position closed (", reason, "): ticket=", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//  DONCHIAN CHANNEL
//+------------------------------------------------------------------+
double DonchianHigh(int period) {
   double highs[];
   if(CopyHigh(TradeSymbol, _Period, 1, period, highs) < period) return 0;
   double highest = highs[0];
   for(int i = 1; i < period; i++)
      if(highs[i] > highest) highest = highs[i];
   return highest;
}

double DonchianLow(int period) {
   double lows[];
   if(CopyLow(TradeSymbol, _Period, 1, period, lows) < period) return 0;
   double lowest = lows[0];
   for(int i = 1; i < period; i++)
      if(lows[i] < lowest) lowest = lows[i];
   return lowest;
}

//+------------------------------------------------------------------+
//  TRAILING STOP (shared logic, parameterized)
//+------------------------------------------------------------------+
void TrailStop(double atrVal, double trailMult) {
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double trailDist = atrVal * trailMult;
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   if(type == POSITION_TYPE_BUY) {
      double newSL = NormalizeDouble(bid - trailDist, digits);
      if(newSL > currentSL + (atrVal * 0.2)) ModifySL(newSL, currentTP);
   } else {
      double newSL = NormalizeDouble(ask + trailDist, digits);
      if(newSL < currentSL - (atrVal * 0.2) || currentSL == 0) ModifySL(newSL, currentTP);
   }
}

void ModifySL(double nSL, double currentTP) {
   MqlTradeRequest r = {}; MqlTradeResult rs = {};
   r.action   = TRADE_ACTION_SLTP;
   r.position = (ulong)PositionGetInteger(POSITION_TICKET);
   r.symbol   = TradeSymbol;
   r.sl       = nSL;
   r.tp       = currentTP;
   if(!OrderSend(r, rs) || rs.retcode != TRADE_RETCODE_DONE) {
      Print("TrailSL modify failed: retcode=", rs.retcode);
   }
}

//+------------------------------------------------------------------+
//  MEAN REVERSION: Scale Out 50% at Mean
//+------------------------------------------------------------------+
void ScaleOutHalf() {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double vol = PositionGetDouble(POSITION_VOLUME);
   double halfVol = NormalizeLot(vol * 0.5);
   ulong posTicket = (ulong)PositionGetInteger(POSITION_TICKET);

   if(halfVol >= vol) {
      Print("MR: Cannot scale out: volume too small to split");
      return;
   }

   req.action = TRADE_ACTION_DEAL;
   req.position = posTicket;
   req.symbol = TradeSymbol;
   req.volume = halfVol;
   req.type = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   req.price = (req.type==ORDER_TYPE_SELL)?SymbolInfoDouble(TradeSymbol, SYMBOL_BID):SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   req.deviation = InpSlippage;
   req.comment = "MR TP1 50%";
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   if(fill & SYMBOL_FILLING_FOK) req.type_filling = ORDER_FILLING_FOK;
   else if(fill & SYMBOL_FILLING_IOC) req.type_filling = ORDER_FILLING_IOC;
   else req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("MR: ScaleOut failed: retcode=", res.retcode);
      return;
   }

   // Mark this position as partially closed
   partialClosedTicket = posTicket;

   // Move SL to breakeven
   if(!SelectPositionByMagic(InpMRMagic)) return;

   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentTP  = PositionGetDouble(POSITION_TP);
   string origComment = PositionGetString(POSITION_COMMENT);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double spread     = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK) - SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   int    digits     = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   double beSL;
   if(posType == POSITION_TYPE_BUY)
      beSL = NormalizeDouble(entryPrice + spread, digits);
   else
      beSL = NormalizeDouble(entryPrice - spread, digits);

   // Modify SL to breakeven - note: MQL5 doesn't allow comment change via SLTP
   // We'll track partial close state via a global variable instead
   MqlTradeRequest beReq = {}; MqlTradeResult beRes = {};
   beReq.action   = TRADE_ACTION_SLTP;
   beReq.position = (ulong)PositionGetInteger(POSITION_TICKET);
   beReq.symbol   = TradeSymbol;
   beReq.sl       = beSL;
   beReq.tp       = currentTP;

   if(!OrderSend(beReq, beRes) || beRes.retcode != TRADE_RETCODE_DONE) {
      Print("MR: Breakeven modify failed: retcode=", beRes.retcode);
   }
}

//+------------------------------------------------------------------+
//  EXECUTE TRADE (shared, parameterized)
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double p, double slPoints, double tpPoints, long magic, string comment, bool isTrendBreakout = false) {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double slD = slPoints * point;
   double tpD = tpPoints * point;
   double sl = (type == ORDER_TYPE_BUY) ? (p - slD) : (p + slD);
   double tp = (type == ORDER_TYPE_BUY) ? (p + tpD) : (p - tpD);

   double riskPct = GetRiskPct(isTrendBreakout);
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * (riskPct / 100.0);
   double tickV = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickS = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickV <= 0 || tickS <= 0) {
      Print("Invalid tick value/size, skipping trade");
      return;
   }

   double lot = risk / (slD * (1.0 / tickS) * tickV);
   lot = NormalizeLot(lot);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

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

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = TradeSymbol;
   req.volume       = lot;
   req.type         = type;
   req.price        = p;
   req.magic        = magic;
   req.sl           = NormalizeDouble(sl, digits);
   req.tp           = NormalizeDouble(tp, digits);
   req.deviation    = InpSlippage;
   req.comment      = TruncateComment(comment);
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   if(fill & SYMBOL_FILLING_FOK) req.type_filling = ORDER_FILLING_FOK;
   else if(fill & SYMBOL_FILLING_IOC) req.type_filling = ORDER_FILLING_IOC;
   else req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("Entry failed: retcode=", res.retcode, " comment=", res.comment);
   } else {
      Print("Trade opened: ", comment, " ", lot, " lots, SL=", NormalizeDouble(sl, digits), " TP(hard)=", NormalizeDouble(tp, digits));
   }
}

//+------------------------------------------------------------------+
//  MAIN TICK HANDLER
//+------------------------------------------------------------------+
void OnTick() {
   CheckDailyReset();

   // Read all indicators
   double ma[1], sd[1], atr[1], adx[1], ema[1];
   double diPlus[1], diMinus[1];

   if(CopyBuffer(handleMA, 0, 0, 1, ma) < 1 ||
      CopyBuffer(handleSD, 0, 0, 1, sd) < 1 ||
      CopyBuffer(handleATR, 0, 0, 1, atr) < 1 ||
      CopyBuffer(handleADX, 0, 0, 1, adx) < 1 ||
      CopyBuffer(handleADX, 1, 0, 1, diPlus) < 1 ||
      CopyBuffer(handleADX, 2, 0, 1, diMinus) < 1 ||
      CopyBuffer(handleEMA, 0, 0, 1, ema) < 1) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);

   if(sd[0] <= 0.0) return;

   double zScore = (bid - ma[0]) / sd[0];
   bool nearNews = IsNearNews();
   bool lossLimitHit = IsDailyLossLimitHit();
   bool redNewsImminent = IsRedNewsImminent();

   // --- DAILY LOSS: close everything and stop ---
   if(lossLimitHit) {
      if(SelectPositionByMagic(InpMRMagic)) ClosePositionsByMagic(InpMRMagic, "MR daily loss");
      if(SelectPositionByMagic(InpTBMagic)) ClosePositionsByMagic(InpTBMagic, "TB daily loss");
      Comment("--- GOLD DUAL STRATEGY ---\n",
              "DAILY LOSS LIMIT REACHED - ALL TRADING STOPPED\n",
              "Loss: ", DoubleToString(((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0, 2), "%");
      return;
   }

   // --- CLOSE BEFORE (RED FOLDER) VERY-HIGH-IMPACT NEWS ---
   if(redNewsImminent) {
      if(SelectPositionByMagic(InpMRMagic)) ClosePositionsByMagic(InpMRMagic, "MR (red folder) very-high-impact news");
      if(SelectPositionByMagic(InpTBMagic)) ClosePositionsByMagic(InpTBMagic, "TB (red folder) very-high-impact news");
   }

   // Shared entry filters
   bool inWindow  = (dt.hour >= InpStartHour && dt.hour < InpEndHour);
   double spreadPts = (ask - bid) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   bool spreadOk  = (spreadPts <= InpMaxSpreadPts);

   //=================================================================
   // STRATEGY 1: MEAN REVERSION
   //=================================================================
   if(InpUseReversion) {
      if(SelectPositionByMagic(InpMRMagic)) {
         // Position management
         bool alreadyPartial = IsPartialClosed();
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         // Scale out 50% at mean (Z near 0)
         if(!alreadyPartial && MathAbs(zScore) < 0.2) {
            ScaleOutHalf();
            Print("MR: TP1 Hit: 50% Closed. SL to Breakeven.");
         }

         // Z-Score TP: close remaining when price fully reverts to mean
         bool zRevert = false;
         if(posType == POSITION_TYPE_BUY && zScore >= -InpExitZ) zRevert = true;
         if(posType == POSITION_TYPE_SELL && zScore <= InpExitZ) zRevert = true;

         if(zRevert) {
            ClosePositionsByMagic(InpMRMagic, "MR Z-TP (Z=" + DoubleToString(zScore, 2) + ")");
         } else {
            // Trailing stop (new bar only)
            datetime curBar = iTime(TradeSymbol, _Period, 0);
            if(curBar != lastMRTrailBar) {
               lastMRTrailBar = curBar;
               TrailStop(atr[0], InpMRTrailingATR);
            }
         }
      } else {
         // Reset partial close tracking when no MR position exists
         partialClosedTicket = 0;

         // Entry logic
         bool isRanging = (adx[0] < InpMRAdxFilter);
         bool volOk = IsVolOkForReversion(atr[0]);

         if(CountPositionsByMagic(InpMRMagic) < InpMaxMRPositions) {
            if(inWindow && isRanging && spreadOk && volOk && !nearNews && MathAbs(zScore) > InpEntryZ) {
               string dir = (zScore < 0) ? "B" : "S";
               string comment = "MR " + dir
                              + "|Z" + DoubleToString(zScore, 2)
                              + "|A" + DoubleToString(adx[0], 0)
                              + "|R" + DoubleToString(atr[0], 2);

               if(zScore < 0)
                  OpenTrade(ORDER_TYPE_BUY, ask, InpMRSLPoints, InpMRHardTPPoints, InpMRMagic, comment, false);
               else
                  OpenTrade(ORDER_TYPE_SELL, bid, InpMRSLPoints, InpMRHardTPPoints, InpMRMagic, comment, false);
            }
         }
      }
   }

   //=================================================================
   // STRATEGY 2: TREND BREAKOUT
   //=================================================================
   if(InpUseBreakout) {
      // Track position count changes for cooldown trigger
      int currentTBCount = CountPositionsByMagic(InpTBMagic);
      if(lastTBCount > 0 && currentTBCount == 0) {
         // TB position just closed - start cooldown
         barsSinceClose = 0;
      }
      lastTBCount = currentTBCount;

      if(SelectPositionByMagic(InpTBMagic)) {
         // Position management: trailing stop (new bar only)
         datetime curBar = iTime(TradeSymbol, _Period, 0);
         if(curBar != lastTBTrailBar) {
            lastTBTrailBar = curBar;
            TrailStop(atr[0], InpTBTrailingATR);
         }
      } else {
         // Entry only on new bar
         datetime currentBar[];
         if(CopyTime(TradeSymbol, _Period, 0, 1, currentBar) >= 1 && currentBar[0] != lastBarTime) {
            lastBarTime = currentBar[0];

            if(barsSinceClose < InpCooldownBars) {
               barsSinceClose++;
            } else if(CountPositionsByMagic(InpTBMagic) < InpMaxTBPositions) {
               double donchHigh = DonchianHigh(InpDonchianPeriod);
               double donchLow  = DonchianLow(InpDonchianPeriod);

               if(donchHigh != 0 && donchLow != 0) {
                  bool isTrending = (adx[0] >= InpTBAdxThreshold);
                  bool volOk = IsVolOkForBreakout(atr[0]);

                  double diSpread = MathAbs(diPlus[0] - diMinus[0]);
                  if(inWindow && isTrending && spreadOk && volOk && !nearNews && diSpread >= InpMinDISpread) {
                     // LONG breakout: price above Donchian high, DI+ > DI-, price above EMA
                     if(ask > donchHigh && diPlus[0] > diMinus[0] && bid > ema[0]) {
                        string comment = "TB B|ADX" + DoubleToString(adx[0], 0)
                                       + "|DI" + DoubleToString(diSpread, 1)
                                       + "|DH" + DoubleToString(donchHigh, 1);
                        OpenTrade(ORDER_TYPE_BUY, ask, InpTBSLPoints, InpTBHardTPPoints, InpTBMagic, comment, true);
                     }
                     // SHORT breakout: price below Donchian low, DI- > DI+, price below EMA
                     else if(bid < donchLow && diMinus[0] > diPlus[0] && ask < ema[0]) {
                        string comment = "TB S|ADX" + DoubleToString(adx[0], 0)
                                       + "|DI" + DoubleToString(diSpread, 1)
                                       + "|DL" + DoubleToString(donchLow, 1);
                        OpenTrade(ORDER_TYPE_SELL, bid, InpTBSLPoints, InpTBHardTPPoints, InpTBMagic, comment, true);
                     }
                  }
               }
            }
         }
      }
   }

   // --- HUD ---
   double donchH = DonchianHigh(InpDonchianPeriod);
   double donchL = DonchianLow(InpDonchianPeriod);
   double dailyLossPct = ((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0;
   bool hasMR = SelectPositionByMagic(InpMRMagic);
   bool hasTB = SelectPositionByMagic(InpTBMagic);

   Comment("--- GOLD DUAL STRATEGY ---\n",
           "Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), "\n",
           "MR Risk: ", DoubleToString(GetRiskPct(false), 1), "% | TB Risk: ", DoubleToString(GetRiskPct(true), 1), "% | DLL: ", DoubleToString(GetDailyLossLimitPct(), 1), "%\n",
           "== Mean Reversion ", (InpUseReversion ? (hasMR ? "[IN TRADE]" : "[scanning]") : "[OFF]"), " ==\n",
           "  Z-Score: ", DoubleToString(zScore, 2), " (entry >", DoubleToString(InpEntryZ, 1), ", exit <", DoubleToString(InpExitZ, 1), ")\n",
           "== Trend Breakout ", (InpUseBreakout ? (hasTB ? "[IN TRADE]" : "[scanning]") : "[OFF]"), " ==\n",
           "  Donch Hi: ", DoubleToString(donchH, 2), "  Lo: ", DoubleToString(donchL, 2), "\n",
           "  EMA50: ", DoubleToString(ema[0], 2), "\n",
           "  DI+: ", DoubleToString(diPlus[0], 1), "  DI-: ", DoubleToString(diMinus[0], 1), "\n",
           "== Shared ==\n",
           "  ADX: ", DoubleToString(adx[0], 1),
              (adx[0] < InpMRAdxFilter ? " [RANGING]" : (adx[0] >= InpTBAdxThreshold ? " [TRENDING]" : " [NEUTRAL]")), "\n",
           "  ATR: ", DoubleToString(atr[0], 2), "\n",
           "  Spread: ", DoubleToString(spreadPts, 1), " pts\n",
           "  News: ", (nearNews ? "BLOCKED" : "clear"), (redNewsImminent ? " [RED FOLDER CLOSE]" : ""), "\n",
           "  Daily P/L: ", DoubleToString(-dailyLossPct, 2), "% / -", DoubleToString(GetDailyLossLimitPct(), 1), "% limit");
}
//+------------------------------------------------------------------+
