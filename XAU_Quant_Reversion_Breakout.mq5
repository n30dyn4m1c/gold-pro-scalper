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
input string   TradeSymbol      = "GOLD";
input double   InpRiskPct       = 10.0;     // Risk % per trade (Mean Reversion)
input double   InpTBRiskPct     = 3.0;      // Risk % per trade (Trend Breakout)
input int      InpStartHour     = 1;        // Trade window start hour
input int      InpEndHour       = 22;       // Trade window end hour (exclusive)
input int      InpSlippage      = 30;       // Max slippage in points
input double   InpMaxSpreadPts  = 50.0;     // Max allowed spread in points

//=== MEAN REVERSION INPUTS ===
input string   _reversion_      = "=== MEAN REVERSION ===";
input bool     InpUseReversion  = true;     // Enable Mean Reversion strategy
input double   InpEntryZ        = 2.5;      // Z-Score entry threshold
input int      InpMRAdxFilter   = 20;       // ADX below this = ranging
input double   InpMRATRStop     = 2.0;      // ATR multiplier for SL
input double   InpMRTrailingATR = 1.5;      // ATR multiplier for trailing
input int      InpMAPeriod      = 20;       // MA / StdDev period
input int      InpMRMagic       = 777333;   // Magic number (Mean Reversion)

//=== TREND BREAKOUT INPUTS ===
input string   _breakout_       = "=== TREND BREAKOUT ===";
input bool     InpUseBreakout   = true;     // Enable Trend Breakout strategy
input int      InpDonchianPeriod = 30;      // Donchian Channel lookback (bars)
input int      InpTBAdxThreshold = 30;      // ADX above this = trending
input double   InpTBATRStop     = 2.5;      // ATR multiplier for SL (wider stop, smaller size)
input double   InpTBTrailingATR = 2.0;      // ATR multiplier for trailing (wider for trends)
input int      InpEMAPeriod     = 50;       // EMA for trend direction confirmation
input int      InpCooldownBars  = 10;       // Bars to wait after loss before re-entry
input double   InpMinDISpread   = 5.0;      // Min DI+/DI- spread for entry
input int      InpTBMagic       = 777444;   // Magic number (Trend Breakout)

//=== SHARED INDICATOR INPUTS ===
input string   _indicators_     = "=== INDICATORS ===";
input int      InpATRPeriod     = 14;       // ATR period
input int      InpADXPeriod     = 14;       // ADX period

//=== NEWS FILTER ===
input string   _news_           = "=== NEWS FILTER ===";
input bool     InpUseNewsFilter      = true;
input int      InpNewsMinsBefore     = 15;
input int      InpNewsMinsAfter      = 15;
input int      InpVHINewsMinsBefore  = 60;
input int      InpVHINewsMinsAfter   = 60;
input bool     InpCloseBeforeVHINews = true;

//=== DAILY LOSS LIMIT ===
input string   _loss_           = "=== DAILY LOSS LIMIT ===";
input bool     InpUseDailyLossLimit  = true;
input double   InpMaxDailyLossPct    = 10.0;

//=== VOLATILITY FILTER ===
input string   _vol_            = "=== VOLATILITY FILTER ===";
input bool     InpUseVolFilter    = true;
input double   InpATRMaxMultiple  = 2.0;   // Max ATR ratio (MR: skip if too wild)
input double   InpATRMinMultiple  = 0.5;   // Min ATR ratio (both: skip if too quiet)

//--- Global Handles
int handleMA, handleSD, handleATR, handleADX, handleATR50, handleEMA;

//--- Mean Reversion state
string partialTag = "_P1";

//--- Trend Breakout state
datetime lastBarTime = 0;
int barsSinceClose = 999;

//--- News schedule
#define MAX_NEWS 40
datetime newsHigh[MAX_NEWS];
int newsHighCount = 0;
datetime newsVHI[MAX_NEWS];
int newsVHICount = 0;
datetime lastNewsLoad = 0;

string vhiKeywords[] = {"Nonfarm Payrolls", "NFP", "Non-Farm",
                         "CPI ", "Consumer Price Index",
                         "FOMC", "Federal Funds Rate", "Interest Rate Decision",
                         "GDP ", "Gross Domestic Product",
                         "PCE ", "Core PCE",
                         "Unemployment Rate",
                         "Retail Sales"};

//--- Daily loss tracking
double dailyStartBalance = 0;
int    dailyStartDay = -1;
bool   dailyLossHit = false;

//+------------------------------------------------------------------+
int OnInit() {
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

   if(lossPercent >= InpMaxDailyLossPct) {
      dailyLossHit = true;
      Print("DAILY LOSS LIMIT HIT: ", DoubleToString(lossPercent, 2), "% lost. Trading stopped.");
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
bool IsVHIEvent(string eventName) {
   for(int k = 0; k < ArraySize(vhiKeywords); k++) {
      if(StringFind(eventName, vhiKeywords[k]) >= 0) return true;
   }
   return false;
}

void LoadNewsEvents() {
   newsHighCount = 0;
   newsVHICount = 0;
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

      if(IsVHIEvent(event.name) && newsVHICount < MAX_NEWS) {
         newsVHI[newsVHICount] = values[i].time;
         newsVHICount++;
      } else if(newsHighCount < MAX_NEWS) {
         newsHigh[newsHighCount] = values[i].time;
         newsHighCount++;
      }
   }

   lastNewsLoad = TimeCurrent();
   Print("News loaded: ", newsHighCount, " high, ", newsVHICount, " VHI events");
}

bool IsNearNews() {
   if(!InpUseNewsFilter) return false;

   MqlDateTime dtNow, dtLast;
   TimeToStruct(TimeCurrent(), dtNow);
   TimeToStruct(lastNewsLoad, dtLast);
   if(dtNow.day != dtLast.day) LoadNewsEvents();

   datetime now = TimeCurrent();

   for(int i = 0; i < newsVHICount; i++) {
      long diff = (long)(newsVHI[i] - now);
      if(diff > -(InpVHINewsMinsAfter * 60) && diff < (InpVHINewsMinsBefore * 60))
         return true;
   }

   for(int i = 0; i < newsHighCount; i++) {
      long diff = (long)(newsHigh[i] - now);
      if(diff > -(InpNewsMinsAfter * 60) && diff < (InpNewsMinsBefore * 60))
         return true;
   }

   return false;
}

bool IsVHINewsImminent() {
   if(!InpUseNewsFilter || !InpCloseBeforeVHINews) return false;

   datetime now = TimeCurrent();
   for(int i = 0; i < newsVHICount; i++) {
      long diff = (long)(newsVHI[i] - now);
      if(diff > 0 && diff < (InpVHINewsMinsBefore * 60))
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
bool SelectPositionByMagic(int magic) {
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

bool IsPartialClosed() {
   string comment = PositionGetString(POSITION_COMMENT);
   return (StringFind(comment, partialTag) >= 0);
}

void ClosePositionsByMagic(int magic, string reason) {
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
      req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

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

   if(halfVol >= vol) {
      Print("MR: Cannot scale out: volume too small to split");
      return;
   }

   req.action = TRADE_ACTION_DEAL;
   req.position = (ulong)PositionGetInteger(POSITION_TICKET);
   req.symbol = TradeSymbol;
   req.volume = halfVol;
   req.type = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   req.price = (req.type==ORDER_TYPE_SELL)?SymbolInfoDouble(TradeSymbol, SYMBOL_BID):SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   req.deviation = InpSlippage;
   req.comment = "MR TP1 50%" + partialTag;
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("MR: ScaleOut failed: retcode=", res.retcode);
      return;
   }

   // Move SL to breakeven
   if(!SelectPositionByMagic(InpMRMagic)) return;

   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentTP  = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double spread     = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK) - SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   int    digits     = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   double beSL;
   if(posType == POSITION_TYPE_BUY)
      beSL = NormalizeDouble(entryPrice + spread, digits);
   else
      beSL = NormalizeDouble(entryPrice - spread, digits);

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
void OpenTrade(ENUM_ORDER_TYPE type, double p, double a, double atrStopMult, int magic, string comment, double riskPct = 0) {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double slD = a * atrStopMult;
   double sl = (type == ORDER_TYPE_BUY) ? (p - slD) : (p + slD);
   if(riskPct <= 0) riskPct = InpRiskPct;
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

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = TradeSymbol;
   req.volume       = lot;
   req.type         = type;
   req.price        = p;
   req.magic        = magic;
   req.sl           = NormalizeDouble(sl, digits);
   req.deviation    = InpSlippage;
   req.comment      = comment;
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("Entry failed: retcode=", res.retcode, " comment=", res.comment);
   } else {
      Print("Trade opened: ", comment, " ", lot, " lots, SL=", NormalizeDouble(sl, digits));
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
   bool vhiImminent = IsVHINewsImminent();

   // --- DAILY LOSS: close everything and stop ---
   if(lossLimitHit) {
      if(SelectPositionByMagic(InpMRMagic)) ClosePositionsByMagic(InpMRMagic, "MR daily loss");
      if(SelectPositionByMagic(InpTBMagic)) ClosePositionsByMagic(InpTBMagic, "TB daily loss");
      Comment("--- GOLD DUAL STRATEGY ---\n",
              "DAILY LOSS LIMIT REACHED - ALL TRADING STOPPED\n",
              "Loss: ", DoubleToString(((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0, 2), "%");
      return;
   }

   // --- CLOSE BEFORE VHI NEWS ---
   if(vhiImminent) {
      if(SelectPositionByMagic(InpMRMagic)) ClosePositionsByMagic(InpMRMagic, "MR VHI news");
      if(SelectPositionByMagic(InpTBMagic)) ClosePositionsByMagic(InpTBMagic, "TB VHI news");
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

         // Scale out 50% at mean (Z near 0)
         if(!alreadyPartial && MathAbs(zScore) < 0.2) {
            ScaleOutHalf();
            Print("MR: TP1 Hit: 50% Closed. SL to Breakeven.");
         }

         // Trailing stop
         TrailStop(atr[0], InpMRTrailingATR);
      } else {
         // Entry logic
         bool isRanging = (adx[0] < InpMRAdxFilter);
         bool volOk = IsVolOkForReversion(atr[0]);

         if(inWindow && isRanging && spreadOk && volOk && !nearNews && MathAbs(zScore) > InpEntryZ) {
            string dir = (zScore < 0) ? "B" : "S";
            string comment = "MR " + dir
                           + "|Z" + DoubleToString(zScore, 2)
                           + "|A" + DoubleToString(adx[0], 0)
                           + "|R" + DoubleToString(atr[0], 2);

            if(zScore < 0)
               OpenTrade(ORDER_TYPE_BUY, ask, atr[0], InpMRATRStop, InpMRMagic, comment);
            else
               OpenTrade(ORDER_TYPE_SELL, bid, atr[0], InpMRATRStop, InpMRMagic, comment);
         }
      }
   }

   //=================================================================
   // STRATEGY 2: TREND BREAKOUT
   //=================================================================
   if(InpUseBreakout) {
      if(SelectPositionByMagic(InpTBMagic)) {
         // Position management: trailing stop
         TrailStop(atr[0], InpTBTrailingATR);
      } else {
         // Entry only on new bar
         datetime currentBar[];
         if(CopyTime(TradeSymbol, _Period, 0, 1, currentBar) >= 1 && currentBar[0] != lastBarTime) {
            lastBarTime = currentBar[0];

            if(barsSinceClose < InpCooldownBars) {
               barsSinceClose++;
            } else {
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
                        OpenTrade(ORDER_TYPE_BUY, ask, atr[0], InpTBATRStop, InpTBMagic, comment, InpTBRiskPct);
                        barsSinceClose = 999;
                     }
                     // SHORT breakout: price below Donchian low, DI- > DI+, price below EMA
                     else if(bid < donchLow && diMinus[0] > diPlus[0] && ask < ema[0]) {
                        string comment = "TB S|ADX" + DoubleToString(adx[0], 0)
                                       + "|DI" + DoubleToString(diSpread, 1)
                                       + "|DL" + DoubleToString(donchLow, 1);
                        OpenTrade(ORDER_TYPE_SELL, bid, atr[0], InpTBATRStop, InpTBMagic, comment, InpTBRiskPct);
                        barsSinceClose = 999;
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
           "== Mean Reversion ", (InpUseReversion ? (hasMR ? "[IN TRADE]" : "[scanning]") : "[OFF]"), " ==\n",
           "  Z-Score: ", DoubleToString(zScore, 2), " (entry >", DoubleToString(InpEntryZ, 1), ")\n",
           "== Trend Breakout ", (InpUseBreakout ? (hasTB ? "[IN TRADE]" : "[scanning]") : "[OFF]"), " ==\n",
           "  Donch Hi: ", DoubleToString(donchH, 2), "  Lo: ", DoubleToString(donchL, 2), "\n",
           "  EMA50: ", DoubleToString(ema[0], 2), "\n",
           "  DI+: ", DoubleToString(diPlus[0], 1), "  DI-: ", DoubleToString(diMinus[0], 1), "\n",
           "== Shared ==\n",
           "  ADX: ", DoubleToString(adx[0], 1),
              (adx[0] < InpMRAdxFilter ? " [RANGING]" : (adx[0] >= InpTBAdxThreshold ? " [TRENDING]" : " [NEUTRAL]")), "\n",
           "  ATR: ", DoubleToString(atr[0], 2), "\n",
           "  Spread: ", DoubleToString(spreadPts, 1), " pts\n",
           "  News: ", (nearNews ? "BLOCKED" : "clear"), (vhiImminent ? " [VHI CLOSE]" : ""), "\n",
           "  Daily P/L: ", DoubleToString(-dailyLossPct, 2), "% / -", DoubleToString(InpMaxDailyLossPct, 1), "% limit");
}
//+------------------------------------------------------------------+
