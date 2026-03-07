//+------------------------------------------------------------------+
//|                                      gold-quant-m5-scalper.mq5   |
//|                                  Copyright 2026, Gemini Quant Lab |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2026, Gemini Quant Lab"
#property link      ""
#property version   "7.10"
#property description "Gold Quant M5 Scalper - Mean Reversion Z-Score EA"

//--- Inputs: Strategy
input string   TradeSymbol    = "GOLD";
input double   InpEntryZ      = 2.5;      // Z-Score entry threshold (2.3–2.7 sweet spot)
input int      InpADXFilter   = 20;       // ADX range filter (below = ranging)
input double   InpRiskPct     = 10.0;     // Risk % per trade
input double   InpATRStop     = 2.0;      // ATR multiplier for SL (1.5–2.5)
input int      InpStartHour   = 9;        // Trade window start hour (London open)
input int      InpEndHour     = 18;       // Trade window end hour, exclusive (avoid late NY chop)
input int      InpMagic       = 777333;   // Magic number

//--- Inputs: Partial Profit & Trailing
input double   InpTP1_ATR        = 1.0;   // TP1: close 50% at this ATR profit
input double   InpTP2_ATR        = 2.0;   // TP2: close 25% at this ATR profit
input double   InpHardTP_ATR     = 3.0;   // Hard TP on order (safety net, 0 = disabled)
input double   InpTrailTightATR  = 0.8;   // Tight trail multiplier (after TP1, before TP2)
input double   InpTrailLooseATR  = 1.5;   // Loose trail multiplier (after TP2)
input double   InpTrailBuyATR    = 0.0;   // Buy trail override (0 = use standard)
input double   InpTrailSellATR   = 0.0;   // Sell trail override (0 = use standard)

//--- Inputs: Indicators
input int      InpMAPeriod    = 20;       // MA / StdDev period
input int      InpATRPeriod   = 14;       // ATR period
input int      InpADXPeriod   = 14;       // ADX period
input int      InpRSIPeriod   = 14;       // RSI period

//--- Inputs: RSI Confirmation
input bool     InpUseRSIFilter   = true;  // Enable RSI confirmation filter
input double   InpRSIOversold    = 30.0;  // RSI below this = oversold (allow BUY)
input double   InpRSIOverbought  = 70.0;  // RSI above this = overbought (allow SELL)

//--- Inputs: Execution
input int      InpSlippage    = 30;       // Max slippage in points
input double   InpMaxSpreadPts = 50.0;    // Max allowed spread in points

//--- Inputs: News Filter
input bool     InpUseNewsFilter      = true;  // Enable news time filter
input int      InpNewsMinsBefore     = 15;    // Minutes to pause BEFORE high-impact news
input int      InpNewsMinsAfter      = 15;    // Minutes to pause AFTER high-impact news
input int      InpVHINewsMinsBefore  = 60;    // Minutes to pause BEFORE very-high-impact (NFP etc)
input int      InpVHINewsMinsAfter   = 60;    // Minutes to pause AFTER very-high-impact
input bool     InpCloseBeforeVHINews = true;  // Close open trades before very-high-impact news

//--- Inputs: Capital Protection
input bool     InpUseDailyLossLimit  = true;  // Enable max daily loss stop
input double   InpMaxDailyLossPct    = 4.0;   // Max daily loss % of balance (stops trading)
input bool     InpUseWeeklyLossLimit = true;  // Enable max weekly loss stop
input double   InpMaxWeeklyLossPct   = 10.0;  // Max weekly loss % (stops trading until next week)
input bool     InpUseEquityStop      = true;  // Enable equity drawdown global stop
input double   InpMaxEquityDDPct     = 15.0;  // Max drawdown % from peak equity (halts EA)

//--- Inputs: Volatility Filter
input bool     InpUseVolFilter    = true;  // Enable volatility-adjusted entry
input double   InpATRMaxMultiple  = 1.7;   // Max ATR vs 50-period avg (skip near-breakouts)
input double   InpATRMinMultiple  = 0.5;   // Min ATR vs 50-period avg (skip if too quiet)

//--- Global Handles & State
int handleMA, handleSD, handleATR, handleADX, handleATR50, handleRSI;

//--- Partial close tags (embedded in trade comment)
string tagTP1 = "_T1";
string tagTP2 = "_T2";

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

//--- Capital protection tracking
double dailyStartBalance = 0;
int    dailyStartDay = -1;
bool   dailyLossHit = false;

double weeklyStartBalance = 0;
int    weeklyStartWeek = -1;
bool   weeklyLossHit = false;

double peakEquity = 0;
bool   equityStopHit = false;

//+------------------------------------------------------------------+
int OnInit() {
   handleMA    = iMA(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleSD    = iStdDev(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleATR   = iATR(TradeSymbol, _Period, InpATRPeriod);
   handleADX   = iADX(TradeSymbol, _Period, InpADXPeriod);
   handleATR50 = iATR(TradeSymbol, _Period, 50);
   handleRSI   = iRSI(TradeSymbol, _Period, InpRSIPeriod, PRICE_CLOSE);

   if(handleMA == INVALID_HANDLE || handleSD == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE || handleADX == INVALID_HANDLE ||
      handleATR50 == INVALID_HANDLE || handleRSI == INVALID_HANDLE) {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   if(InpUseNewsFilter) LoadNewsEvents();

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);

   dailyStartBalance = bal;
   dailyStartDay = dt.day_of_year;
   dailyLossHit = false;

   weeklyStartBalance = bal;
   weeklyStartWeek = dt.day_of_year / 7;
   weeklyLossHit = false;

   peakEquity = MathMax(bal, eq);
   equityStopHit = false;

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(handleMA    != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleSD    != INVALID_HANDLE) IndicatorRelease(handleSD);
   if(handleATR   != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleADX   != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleATR50 != INVALID_HANDLE) IndicatorRelease(handleATR50);
   if(handleRSI   != INVALID_HANDLE) IndicatorRelease(handleRSI);
}

//+------------------------------------------------------------------+
//  Capital Protection — Daily / Weekly / Equity Drawdown
//+------------------------------------------------------------------+
void CheckProtectionResets() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int currentWeek = dt.day_of_year / 7;

   // Daily reset
   if(dt.day_of_year != dailyStartDay) {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyStartDay = dt.day_of_year;
      dailyLossHit = false;
      Print("Daily loss tracker reset. Starting balance: ", dailyStartBalance);
   }

   // Weekly reset (approximate: every 7 days)
   if(currentWeek != weeklyStartWeek) {
      weeklyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      weeklyStartWeek = currentWeek;
      weeklyLossHit = false;
      Print("Weekly loss tracker reset. Starting balance: ", weeklyStartBalance);
   }

   // Track peak equity (only update when not in drawdown stop)
   if(!equityStopHit) {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > peakEquity) peakEquity = eq;
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

bool IsWeeklyLossLimitHit() {
   if(!InpUseWeeklyLossLimit) return false;
   if(weeklyLossHit) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = ((weeklyStartBalance - equity) / weeklyStartBalance) * 100.0;

   if(lossPercent >= InpMaxWeeklyLossPct) {
      weeklyLossHit = true;
      Print("WEEKLY LOSS LIMIT HIT: ", DoubleToString(lossPercent, 2), "% lost. Trading stopped until next week.");
      return true;
   }
   return false;
}

bool IsEquityStopHit() {
   if(!InpUseEquityStop) return false;
   if(equityStopHit) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(peakEquity <= 0) return false;

   double ddPercent = ((peakEquity - equity) / peakEquity) * 100.0;

   if(ddPercent >= InpMaxEquityDDPct) {
      equityStopHit = true;
      Print("EQUITY DRAWDOWN STOP: ", DoubleToString(ddPercent, 2), "% from peak (",
            DoubleToString(peakEquity, 2), "). EA HALTED — manual review required.");
      return true;
   }
   return false;
}

string GetProtectionStatus() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLoss  = ((dailyStartBalance - equity) / dailyStartBalance) * 100.0;
   double weeklyLoss = ((weeklyStartBalance - equity) / weeklyStartBalance) * 100.0;
   double eqDD = (peakEquity > 0) ? ((peakEquity - equity) / peakEquity) * 100.0 : 0;

   string status = "";
   status += "Day: "  + DoubleToString(-dailyLoss, 2)  + "% / -" + DoubleToString(InpMaxDailyLossPct, 1)  + "%";
   status += " | Wk: " + DoubleToString(-weeklyLoss, 2) + "% / -" + DoubleToString(InpMaxWeeklyLossPct, 1) + "%";
   status += " | DD: "  + DoubleToString(eqDD, 2)       + "% / "  + DoubleToString(InpMaxEquityDDPct, 1)   + "%";
   return status;
}

//+------------------------------------------------------------------+
//  News Filter
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
   int total = CalendarValueHistory(values, dayStart, dayEnd);

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
   Print("News loaded: ", newsHighCount, " high-impact, ", newsVHICount, " very-high-impact USD events today");
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
//  Position helpers
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

bool HasTag(string tag) {
   string comment = PositionGetString(POSITION_COMMENT);
   return (StringFind(comment, tag) >= 0);
}

double GetPositionProfitATR(double atrVal) {
   if(atrVal <= 0) return 0;
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double bid   = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   long   type  = PositionGetInteger(POSITION_TYPE);

   double dist;
   if(type == POSITION_TYPE_BUY)
      dist = bid - entry;
   else
      dist = entry - ask;

   return dist / atrVal;
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
//  Close helpers
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
      uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
      req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

      if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
         Print("Close position failed (", reason, "): ticket=", ticket, " retcode=", res.retcode);
      } else {
         Print("Position closed (", reason, "): ticket=", ticket);
      }
   }
}

bool ClosePartial(double fraction, string tag) {
   double vol = PositionGetDouble(POSITION_VOLUME);
   double closeVol = NormalizeLot(vol * fraction);

   if(closeVol >= vol) {
      Print("Cannot partial close: volume too small to split (", tag, ")");
      return false;
   }

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action   = TRADE_ACTION_DEAL;
   req.position = PositionGetInteger(POSITION_TICKET);
   req.symbol   = TradeSymbol;
   req.volume   = closeVol;
   req.type     = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price    = (req.type==ORDER_TYPE_SELL) ? SymbolInfoDouble(TradeSymbol, SYMBOL_BID)
                                              : SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   req.deviation = InpSlippage;
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("Partial close failed (", tag, "): retcode=", res.retcode, " comment=", res.comment);
      return false;
   }

   Print("Partial close (", tag, "): closed ", closeVol, " of ", vol, " lots");
   return true;
}

//+------------------------------------------------------------------+
void MoveSLToBreakevenPlus(double atrVal) {
   if(!SelectOwnPosition()) return;

   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentTP  = PositionGetDouble(POSITION_TP);
   long   posType    = PositionGetInteger(POSITION_TYPE);
   double spread     = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK) - SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   int    digits     = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   // Lock in a small profit: entry + spread + 0.2×ATR
   // This ensures the remaining position nets positive even if stopped
   double lockIn = spread + (atrVal * 0.2);

   double beSL;
   if(posType == POSITION_TYPE_BUY)
      beSL = NormalizeDouble(entryPrice + lockIn, digits);
   else
      beSL = NormalizeDouble(entryPrice - lockIn, digits);

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action   = TRADE_ACTION_SLTP;
   req.position = PositionGetInteger(POSITION_TICKET);
   req.symbol   = TradeSymbol;
   req.sl       = beSL;
   req.tp       = currentTP;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("Breakeven+ modify failed: retcode=", res.retcode);
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
//  Stepped Trailing Stop — only active after TP1
//+------------------------------------------------------------------+
void HandleTrailingStop(double atrVal) {
   // Only trail after TP1 has been hit (before TP1, the initial SL protects)
   if(!HasTag(tagTP1)) return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   long type = PositionGetInteger(POSITION_TYPE);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   // Determine trail multiplier: tight before TP2, loose after
   double trailMult;
   bool pastTP2 = HasTag(tagTP2);
   if(pastTP2)
      trailMult = InpTrailLooseATR;
   else
      trailMult = InpTrailTightATR;

   // Asymmetric override: different trail for buys vs sells
   if(type == POSITION_TYPE_BUY && InpTrailBuyATR > 0)
      trailMult = InpTrailBuyATR;
   else if(type == POSITION_TYPE_SELL && InpTrailSellATR > 0)
      trailMult = InpTrailSellATR;

   double trailDist = atrVal * trailMult;

   if(type == POSITION_TYPE_BUY) {
      double newSL = NormalizeDouble(bid - trailDist, digits);
      if(newSL > currentSL + (atrVal * 0.1)) ModifySL(newSL, currentTP);
   } else {
      double newSL = NormalizeDouble(ask + trailDist, digits);
      if(newSL < currentSL - (atrVal * 0.1) || currentSL == 0) ModifySL(newSL, currentTP);
   }
}

//+------------------------------------------------------------------+
//  Position Management — 3-stage exit
//+------------------------------------------------------------------+
void ManagePosition(double atrVal) {
   double profitATR = GetPositionProfitATR(atrVal);
   bool hitTP1 = HasTag(tagTP1);
   bool hitTP2 = HasTag(tagTP2);

   // --- TP1: Close 50% at InpTP1_ATR profit, move SL to breakeven+ ---
   if(!hitTP1 && profitATR >= InpTP1_ATR) {
      if(ClosePartial(0.50, "TP1")) {
         MoveSLToBreakevenPlus(atrVal);
         Print("TP1 hit at ", DoubleToString(profitATR, 2), " ATR profit. 50% closed, SL to BE+.");
      }
   }

   // --- TP2: Close 25% (~50% of remaining) at InpTP2_ATR profit ---
   if(hitTP1 && !hitTP2 && profitATR >= InpTP2_ATR) {
      if(SelectOwnPosition()) {
         if(ClosePartial(0.50, "TP2")) {
            Print("TP2 hit at ", DoubleToString(profitATR, 2), " ATR profit. Another 25% closed. ~25% running with loose trail.");
         }
      }
   }

   // --- Stepped trailing on whatever remains ---
   if(SelectOwnPosition()) {
      HandleTrailingStop(atrVal);
   }
}

//+------------------------------------------------------------------+
void OnTick() {
   CheckProtectionResets();

   double ma[1], sd[1], atr[1], adx[1], rsi[1];
   if(CopyBuffer(handleMA,0,0,1,ma)<1 || CopyBuffer(handleSD,0,0,1,sd)<1 ||
      CopyBuffer(handleATR,0,0,1,atr)<1 || CopyBuffer(handleADX,0,0,1,adx)<1 ||
      CopyBuffer(handleRSI,0,0,1,rsi)<1) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);

   if(sd[0] <= 0.0) return;

   double zScore = (bid - ma[0]) / sd[0];
   bool nearNews = IsNearNews();
   bool vhiImminent = IsVHINewsImminent();

   // --- EQUITY DRAWDOWN GLOBAL STOP (requires manual review) ---
   if(IsEquityStopHit()) {
      if(SelectOwnPosition()) CloseAllOwnPositions("equity drawdown stop");
      Comment("--- GOLD QUANT M5 SCALPER v7 ---\n",
              "EQUITY DRAWDOWN STOP - EA HALTED\n",
              "Peak: ", DoubleToString(peakEquity, 2), "\n",
              "Drawdown: ", DoubleToString(((peakEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / peakEquity) * 100.0, 2), "%\n",
              "Remove EA and re-attach to reset after manual review.");
      return;
   }

   // --- WEEKLY LOSS: close everything and stop until next week ---
   if(IsWeeklyLossLimitHit()) {
      if(SelectOwnPosition()) CloseAllOwnPositions("weekly loss limit");
      Comment("--- GOLD QUANT M5 SCALPER v7 ---\n",
              "WEEKLY LOSS LIMIT REACHED - TRADING PAUSED\n",
              GetProtectionStatus());
      return;
   }

   // --- DAILY LOSS: close everything and stop for today ---
   if(IsDailyLossLimitHit()) {
      if(SelectOwnPosition()) CloseAllOwnPositions("daily loss limit");
      Comment("--- GOLD QUANT M5 SCALPER v7 ---\n",
              "DAILY LOSS LIMIT REACHED - TRADING STOPPED\n",
              GetProtectionStatus());
      return;
   }

   // --- CLOSE BEFORE VERY-HIGH-IMPACT NEWS ---
   if(vhiImminent && SelectOwnPosition()) {
      CloseAllOwnPositions("VHI news imminent");
   }

   // --- POSITION MANAGEMENT ---
   if(SelectOwnPosition()) {
      ManagePosition(atr[0]);
   } else {
      // --- ENTRY LOGIC ---
      bool inWindow  = (dt.hour >= InpStartHour && dt.hour < InpEndHour);
      bool isRanging = (adx[0] < InpADXFilter);
      double spreadPts = (ask - bid) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      bool spreadOk  = (spreadPts <= InpMaxSpreadPts);
      bool volOk     = IsVolatilityOk(atr[0]);

      // RSI confirmation: buy only if oversold, sell only if overbought
      bool rsiBuyOk  = (!InpUseRSIFilter || rsi[0] < InpRSIOversold);
      bool rsiSellOk = (!InpUseRSIFilter || rsi[0] > InpRSIOverbought);

      if(inWindow && isRanging && spreadOk && volOk && !nearNews && MathAbs(zScore) > InpEntryZ) {
         if(zScore < 0 && rsiBuyOk)       ExecuteTrade(ORDER_TYPE_BUY, ask, atr[0]);
         else if(zScore > 0 && rsiSellOk) ExecuteTrade(ORDER_TYPE_SELL, bid, atr[0]);
      }
   }

   double profitATR = 0;
   string exitStage = "---";
   if(SelectOwnPosition()) {
      profitATR = GetPositionProfitATR(atr[0]);
      if(HasTag(tagTP2))      exitStage = "TP2 done (~25% running, loose trail)";
      else if(HasTag(tagTP1)) exitStage = "TP1 done (50% running, tight trail)";
      else                    exitStage = "Full position (waiting TP1)";
   }

   Comment("--- GOLD QUANT M5 SCALPER v7 ---\n",
           "Z-Score: ", DoubleToString(zScore, 2),
           " | RSI: ", DoubleToString(rsi[0], 1), "\n",
           "ADX: ", DoubleToString(adx[0], 1), "\n",
           "ATR: ", DoubleToString(atr[0], 2), "\n",
           "Spread: ", DoubleToString((ask-bid)/SymbolInfoDouble(TradeSymbol,SYMBOL_POINT), 1), " pts\n",
           "News Block: ", (nearNews ? "YES" : "no"),
           (vhiImminent ? " [VHI CLOSE]" : ""), "\n",
           "Vol Filter: ", (IsVolatilityOk(atr[0]) ? "OK" : "BLOCKED"), "\n",
           "Profit: ", DoubleToString(profitATR, 2), " ATR | ", exitStage, "\n",
           GetProtectionStatus());
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double p, double a) {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double slD = a * InpATRStop;
   double sl = (type == ORDER_TYPE_BUY) ? (p - slD) : (p + slD);
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

   // Hard TP as safety net (EA manages exits, but this protects against disconnects)
   double tp = 0;
   if(InpHardTP_ATR > 0) {
      double tpD = a * InpHardTP_ATR;
      tp = (type == ORDER_TYPE_BUY) ? (p + tpD) : (p - tpD);
      tp = NormalizeDouble(tp, digits);
   }

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = TradeSymbol;
   req.volume       = lot;
   req.type         = type;
   req.price        = p;
   req.magic        = InpMagic;
   req.sl           = NormalizeDouble(sl, digits);
   req.tp           = tp;
   req.deviation    = InpSlippage;
   req.comment      = "GQS";
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("Entry failed: retcode=", res.retcode, " comment=", res.comment);
   } else {
      Print("Trade opened: ", EnumToString(type), " ", lot, " lots, SL=", sl);
   }
}
//+------------------------------------------------------------------+
// my work is worship unto GOD
