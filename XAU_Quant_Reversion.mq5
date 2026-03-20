//+------------------------------------------------------------------+
//|                                       XAU_Quant_Reversion.mq5    |
//|                                  Copyright 2026, Gemini Quant Lab |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2026, Gemini Quant Lab"
#property link      ""
#property version   "5.00"
#property description "XAU Quant Reversion - Mean Reversion Z-Score EA"

//--- Inputs: Strategy
input string   TradeSymbol    = "GOLD";
input double   InpEntryZ      = 2.4;      // Z-Score entry threshold (1.8–2.5)
input int      InpADXFilter   = 20;       // ADX range filter (below = ranging)
input double   InpRiskPct     = 10.0;     // Risk % per trade
input double   InpATRStop     = 2.0;      // ATR multiplier for SL (1.5–2.5)
input double   InpATRTP       = 4.0;      // ATR multiplier for hard TP (server-side safety net)
input double   InpTrailingATR = 1.5;      // ATR multiplier for trailing
input int      InpStartHour   = 10;       // Trade window start hour
input int      InpEndHour     = 20;       // Trade window end hour (exclusive)
input int      InpMagic       = 777333;   // Magic number

//--- Inputs: Indicators
input int      InpMAPeriod    = 20;       // MA / StdDev period
input int      InpATRPeriod   = 14;       // ATR period
input int      InpADXPeriod   = 14;       // ADX period

//--- Inputs: Execution
input int      InpSlippage    = 30;       // Max slippage in points
input double   InpMaxSpreadPts = 50.0;    // Max allowed spread in points

//--- Inputs: News Filter (red folder / CALENDAR_IMPORTANCE_HIGH only)
input bool     InpUseNewsFilter      = true;  // Enable news time filter
input int      InpNewsMinsBefore     = 60;    // Minutes to pause BEFORE red-folder news
input int      InpNewsMinsAfter      = 60;    // Minutes to pause AFTER red-folder news
input bool     InpCloseBeforeNews    = true;  // Close open trades before red-folder news

//--- Inputs: Daily Loss Limit
input bool     InpUseDailyLossLimit  = true;  // Enable max daily loss stop
input double   InpMaxDailyLossPct    = 20.0;  // Max daily loss % of balance (stops trading)

//--- Inputs: Volatility Filter
input bool     InpUseVolFilter    = true;  // Enable volatility-adjusted entry
input double   InpATRMaxMultiple  = 2.0;   // Max ATR vs 50-period avg (skip if exceeded)
input double   InpATRMinMultiple  = 0.5;   // Min ATR vs 50-period avg (skip if too quiet)

//--- Global Handles & State
int handleMA, handleSD, handleATR, handleADX, handleATR50;

//--- News schedule: red folder (CALENDAR_IMPORTANCE_HIGH) only
#define MAX_NEWS 40
datetime newsRed[MAX_NEWS];
int newsRedCount = 0;
datetime lastNewsLoad = 0;

//--- Daily loss tracking
double dailyStartBalance = 0;
int    dailyStartDay = -1;
bool   dailyLossHit = false;

//--- New-bar tracking for trailing
datetime lastTrailBar = 0;

//+------------------------------------------------------------------+
int OnInit() {
   handleMA    = iMA(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleSD    = iStdDev(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleATR   = iATR(TradeSymbol, _Period, InpATRPeriod);
   handleADX   = iADX(TradeSymbol, _Period, InpADXPeriod);
   handleATR50 = iATR(TradeSymbol, _Period, 50);

   if(handleMA == INVALID_HANDLE || handleSD == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE || handleADX == INVALID_HANDLE ||
      handleATR50 == INVALID_HANDLE) {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   if(InpUseNewsFilter) LoadNewsEvents();

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dailyStartDay = dt.day_of_year;
   dailyLossHit = false;

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(handleMA    != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleSD    != INVALID_HANDLE) IndicatorRelease(handleSD);
   if(handleATR   != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleADX   != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleATR50 != INVALID_HANDLE) IndicatorRelease(handleATR50);
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

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = ((dailyStartBalance - equity) / dailyStartBalance) * 100.0;

   if(lossPercent >= InpMaxDailyLossPct) {
      dailyLossHit = true;
      Print("DAILY LOSS LIMIT HIT: ", DoubleToString(lossPercent, 2), "% lost. Trading stopped for today.");
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
   datetime dayEnd   = dayStart + 86400;

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, dayStart, dayEnd);

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
   if(dtNow.day != dtLast.day) LoadNewsEvents();

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
//  Volatility Filter
//+------------------------------------------------------------------+
bool IsVolatilityOk(double atrFast) {
   if(!InpUseVolFilter) return true;

   double atrSlow[1];
   if(CopyBuffer(handleATR50, 0, 0, 1, atrSlow) < 1) return true;
   if(atrSlow[0] <= 0) return true;

   double ratio = atrFast / atrSlow[0];
   if(ratio > InpATRMaxMultiple || ratio < InpATRMinMultiple) return false;

   return true;
}

//+------------------------------------------------------------------+
bool SelectOwnPosition() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic) {
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
int CountOwnPositions() {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic) {
         count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
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
void CloseAllOwnPositions(string reason) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action   = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol   = TradeSymbol;
      req.volume   = PositionGetDouble(POSITION_VOLUME);
      long posType = PositionGetInteger(POSITION_TYPE);
      req.type     = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price    = (req.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(TradeSymbol, SYMBOL_BID)
                                                   : SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
      req.deviation = InpSlippage;
      req.comment  = "GQS " + reason;
      uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
      req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

      if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
         Print("Close position failed (", reason, "): ticket=", ticket, " retcode=", res.retcode);
      } else {
         Print("Position closed (", reason, "): ticket=", ticket);
      }
   }
}

//+------------------------------------------------------------------+
void OnTick() {
   CheckDailyReset();

   double ma[1], sd[1], atr[1], adx[1];
   if(CopyBuffer(handleMA,0,0,1,ma)<1 || CopyBuffer(handleSD,0,0,1,sd)<1 ||
      CopyBuffer(handleATR,0,0,1,atr)<1 || CopyBuffer(handleADX,0,0,1,adx)<1) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);

   if(sd[0] <= 0.0) return;

   double zScore = (bid - ma[0]) / sd[0];
   bool nearNews = IsNearNews();
   bool lossLimitHit = IsDailyLossLimitHit();
   bool redNewsImminent = IsRedNewsImminent();
   bool volOk = IsVolatilityOk(atr[0]);

   // --- DAILY LOSS: close everything and stop ---
   if(lossLimitHit) {
      if(SelectOwnPosition()) CloseAllOwnPositions("daily loss limit");
      Comment("--- XAU QUANT REVERSION v5 ---\n",
              "DAILY LOSS LIMIT REACHED - TRADING STOPPED\n",
              "Loss: ", DoubleToString(((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0, 2), "%");
      return;
   }

   // --- CLOSE BEFORE (RED FOLDER) HIGH-IMPACT NEWS ---
   if(redNewsImminent && SelectOwnPosition()) {
      CloseAllOwnPositions("(red folder) high-impact news imminent");
   }

   // --- POSITION MANAGEMENT: trail on new bar only ---
   if(SelectOwnPosition()) {
      datetime curBar = iTime(TradeSymbol, _Period, 0);
      if(curBar != lastTrailBar) {
         lastTrailBar = curBar;
         HandleTrailingStop(atr[0]);
      }
   } else {
      // --- ENTRY LOGIC ---
      if(CountOwnPositions() > 0) return;  // guard against race condition

      bool inWindow  = (dt.hour >= InpStartHour && dt.hour < InpEndHour);
      bool isRanging = (adx[0] < InpADXFilter);
      double spreadPts = (ask - bid) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      bool spreadOk  = (spreadPts <= InpMaxSpreadPts);

      if(inWindow && isRanging && spreadOk && volOk && !nearNews && MathAbs(zScore) > InpEntryZ) {
         if(zScore < 0) ExecuteTrade(ORDER_TYPE_BUY, ask, atr[0], zScore, adx[0]);
         else           ExecuteTrade(ORDER_TYPE_SELL, bid, atr[0], zScore, adx[0]);
      }
   }

   double dailyLossPct = ((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0;

   Comment("--- XAU QUANT REVERSION v5 ---\n",
           "Z-Score: ", DoubleToString(zScore, 2), "\n",
           "ADX: ", DoubleToString(adx[0], 1), "\n",
           "ATR: ", DoubleToString(atr[0], 2), "\n",
           "Spread: ", DoubleToString((ask-bid)/SymbolInfoDouble(TradeSymbol,SYMBOL_POINT), 1), " pts\n",
           "News Block: ", (nearNews ? "YES" : "no"),
           (redNewsImminent ? " [RED FOLDER CLOSE]" : ""), "\n",
           "Vol Filter: ", (volOk ? "OK" : "BLOCKED"), "\n",
           "Daily P/L: ", DoubleToString(-dailyLossPct, 2), "% / -", DoubleToString(InpMaxDailyLossPct, 1), "% limit");
}

//+------------------------------------------------------------------+
void HandleTrailingStop(double atrVal) {
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   long type = PositionGetInteger(POSITION_TYPE);
   double trailDist = atrVal * InpTrailingATR;
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   if(type == POSITION_TYPE_BUY) {
      double newSL = NormalizeDouble(bid - trailDist, digits);
      if(newSL > currentSL + (atrVal * 0.2)) ModifySL(newSL, currentTP);
   } else {
      double newSL = NormalizeDouble(ask + trailDist, digits);
      if(newSL < currentSL - (atrVal * 0.2) || currentSL == 0) ModifySL(newSL, currentTP);
   }
}

//+------------------------------------------------------------------+
void ModifySL(double nSL, double currentTP) {
   MqlTradeRequest r = {}; MqlTradeResult rs = {};
   r.action   = TRADE_ACTION_SLTP;
   r.position = PositionGetInteger(POSITION_TICKET);
   r.symbol   = TradeSymbol;
   r.sl       = nSL;
   r.tp       = currentTP;
   if(!OrderSend(r, rs) || rs.retcode != TRADE_RETCODE_DONE) {
      Print("TrailSL modify failed: retcode=", rs.retcode);
   }
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double p, double a, double zScore, double adxVal) {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double slD = a * InpATRStop;
   double tpD = a * InpATRTP;
   double sl = (type == ORDER_TYPE_BUY) ? (p - slD) : (p + slD);
   double tp = (type == ORDER_TYPE_BUY) ? (p + tpD) : (p - tpD);
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPct / 100.0);
   double tickV = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickS = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickV <= 0 || tickS <= 0) {
      Print("Invalid tick value/size, skipping trade");
      return;
   }

   double lot = risk / (slD * (1.0 / tickS) * tickV);
   lot = NormalizeLot(lot);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   string dir = (type == ORDER_TYPE_BUY) ? "B" : "S";
   string comment = "GQS " + dir
                   + "|Z" + DoubleToString(zScore, 2)
                   + "|A" + DoubleToString(adxVal, 0)
                   + "|R" + DoubleToString(a, 2);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = TradeSymbol;
   req.volume       = lot;
   req.type         = type;
   req.price        = p;
   req.magic        = InpMagic;
   req.sl           = NormalizeDouble(sl, digits);
   req.tp           = NormalizeDouble(tp, digits);
   req.deviation    = InpSlippage;
   req.comment      = comment;
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("Entry failed: retcode=", res.retcode, " comment=", res.comment);
   } else {
      Print("Trade opened: ", EnumToString(type), " ", lot, " lots, SL=", NormalizeDouble(sl, digits), " TP=", NormalizeDouble(tp, digits));
   }
}
//+------------------------------------------------------------------+
