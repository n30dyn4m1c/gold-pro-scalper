//+------------------------------------------------------------------+
//|                            XAU_Quant_Reversion_TickRobust.mq5    |
//|                                     Copyright 2026, n30dyn4m1c   |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2026, n30dyn4m1c"
#property link      ""
#property version   "1.00"
#property description "N30 Gold Reversion TickRobust - closed-bar mean reversion built to survive Every Tick modelling"

//+------------------------------------------------------------------+
//| WHY THIS EA EXISTS                                               |
//|                                                                  |
//| The earlier Z-Score EAs test profitable on M1 OHLC but fail on  |
//| Every Tick. The gap comes from intra-bar behaviour that OHLC     |
//| modelling cannot see:                                            |
//|   - tick-level Z entries/exits fire on noise at the worst price  |
//|   - market-order exits pay the spread twice per round trip       |
//|   - no minimum-edge check, so quiet-market trades where the      |
//|     expected snap-back barely covers the spread still fire       |
//|   - real ticks tag stops that OHLC interpolation never touches   |
//|                                                                  |
//| This EA closes that gap with five rules:                         |
//|   1. Every decision (entry, exit, trail, breakeven) is made      |
//|      exactly once per bar, from CLOSED-bar indicator values.     |
//|      Tick noise cannot trigger anything, so Every Tick and OHLC  |
//|      backtests converge by construction.                         |
//|   2. Cost gate: a trade is only taken when the StdDev (the fuel  |
//|      of the reversion) and the distance to the mean are both a   |
//|      multiple of the full round-trip cost (spread + commission). |
//|   3. The take-profit is a SERVER-SIDE limit at the mean (SMA).   |
//|      Limit fills don't pay spread on exit and behave the same    |
//|      in the tester and live.                                     |
//|   4. Turn confirmation: entry waits for the first bar that stops |
//|      making new extremes, instead of catching the falling knife  |
//|      the moment Z crosses the threshold.                         |
//|   5. Wide, volatility-aware SL (max of fixed points and ATR      |
//|      multiple) so intra-bar spikes that OHLC hides don't become  |
//|      surprise stop-outs under real ticks.                        |
//+------------------------------------------------------------------+

//--- Inputs: Strategy
input string   InpTradeSymbol    = "GOLD";   // Trade symbol (GOLD, XAUUSD, etc.)
string         TradeSymbol;
input double   InpEntryZ         = 2.2;      // Z-Score entry threshold (closed bar)
input bool     InpRequireTurn    = true;     // Require momentum turn bar before entry (no knife-catching)
input double   InpExitZ          = 0.2;      // Backup exit: close when closed-bar Z reverts inside this
input int      InpMaxHoldBars    = 40;       // Max trade duration in bars (M1 = minutes)
input double   InpSLPoints       = 800;      // Minimum fixed SL in points
input double   InpSLATRMult      = 2.5;      // SL = max(fixed points, this x ATR)
input double   InpBreakevenATR   = 1.0;      // Move SL to breakeven after this x ATR in profit (0 = off)
input int      InpStartHour      = 10;       // Trade window start hour (broker time)
input int      InpEndHour        = 20;       // Trade window end hour (exclusive)
input int      InpFridayCloseHour = 20;      // Friday hour to close and stop
input int      InpCooldownMins   = 15;       // Pause after a losing trade, minutes (0 = disabled)
input int      InpMagic          = 777555;   // Magic number

//--- Inputs: Cost gates (the core Every-Tick defence)
input double   InpExtraCostPts   = 0.0;      // Round-trip commission expressed in points (add on top of spread)
input double   InpMinSDCostMult  = 3.0;      // StdDev must be >= this x round-trip cost
input double   InpMinTPCostMult  = 4.0;      // Distance to mean (TP) must be >= this x round-trip cost
input double   InpMaxSpreadPts   = 50.0;     // Absolute max allowed spread in points

//--- Inputs: Indicators & regime filters
input int      InpMAPeriod       = 20;       // MA / StdDev period
input int      InpATRPeriod      = 14;       // ATR period
input int      InpADXPeriod      = 14;       // ADX period
input double   InpADXMax         = 22.0;     // Skip entries when closed-bar ADX above this (0 = disabled)
input int      InpFilterPeriodH1 = 50;       // H1 SMA period for trend filter (0 = disabled)
input int      InpATRAvgPeriod   = 50;       // Bars for average-ATR volatility regime
input double   InpMaxATRRatio    = 2.0;      // Skip if ATR > this x average (spike regime)
input double   InpMinATRRatio    = 0.4;      // Skip if ATR < this x average (dead market)

//--- Inputs: Risk
input bool     InpUseDynamicRisk = true;     // Enable equity-based risk tiers (overrides InpRiskPct)
input double   InpRiskPct        = 2.0;      // Risk % per trade (used when dynamic risk is off)
input int      InpSlippage       = 30;       // Max slippage in points

//--- Inputs: News Filter (red folder / CALENDAR_IMPORTANCE_HIGH only)
input bool     InpUseNewsFilter   = true;    // Enable news time filter
input int      InpNewsMinsBefore  = 60;      // Minutes to pause BEFORE red-folder news
input int      InpNewsMinsAfter   = 120;     // Minutes to pause AFTER red-folder news
input bool     InpCloseBeforeNews = true;    // Close open trades before red-folder news

//--- Inputs: Daily Loss Limit
input bool     InpUseDailyLossLimit = true;  // Enable max daily loss stop
input double   InpMaxDailyLossPct   = 15.0;  // Max daily loss % of balance (when dynamic risk is off)

//--- Global handles & state
int handleMA, handleSD, handleATR, handleADX, handleMA_H1;

ulong    glTicket            = 0;    // active position ticket (0 = flat)
double   glEntryPrice        = 0;    // entry price of the open trade
datetime glOpenTime          = 0;    // server time the trade opened
datetime glLossCooldownUntil = 0;    // no new entries until this time after a loss
datetime lastBarTime         = 0;    // new-bar detector

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
   TradeSymbol = InpTradeSymbol;
   if(!SymbolInfoInteger(TradeSymbol, SYMBOL_EXIST)) {
      Print("Symbol ", TradeSymbol, " not found - trying XAUUSD");
      TradeSymbol = "XAUUSD";
      if(!SymbolInfoInteger(TradeSymbol, SYMBOL_EXIST)) {
         Print("Neither GOLD nor XAUUSD found. Please set TradeSymbol manually.");
         return(INIT_FAILED);
      }
   }
   if(!SymbolSelect(TradeSymbol, true)) {
      Print("Failed to add ", TradeSymbol, " to Market Watch");
      return(INIT_FAILED);
   }

   handleMA  = iMA(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleSD  = iStdDev(TradeSymbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   handleATR = iATR(TradeSymbol, _Period, InpATRPeriod);

   handleADX   = (InpADXMax > 0)        ? iADX(TradeSymbol, _Period, InpADXPeriod) : INVALID_HANDLE;
   handleMA_H1 = (InpFilterPeriodH1 > 0) ? iMA(TradeSymbol, PERIOD_H1, InpFilterPeriodH1, 0, MODE_SMA, PRICE_CLOSE)
                                         : INVALID_HANDLE;

   if(handleMA == INVALID_HANDLE || handleSD == INVALID_HANDLE || handleATR == INVALID_HANDLE) {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }
   if(InpADXMax > 0 && handleADX == INVALID_HANDLE) {
      Print("Failed to create ADX handle");
      return(INIT_FAILED);
   }
   if(InpFilterPeriodH1 > 0 && handleMA_H1 == INVALID_HANDLE) {
      Print("Failed to create H1 MA handle");
      return(INIT_FAILED);
   }

   if(InpUseNewsFilter) LoadNewsEvents();

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dailyStartDay = dt.day_of_year;
   dailyLossHit = false;

   // Only act from the NEXT bar open: never make a mid-bar decision on attach
   lastBarTime = iTime(TradeSymbol, _Period, 0);

   // Recover an open position after restart so it keeps being managed
   glTicket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      glTicket     = ticket;
      glEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      glOpenTime   = (datetime)PositionGetInteger(POSITION_TIME);
      Print("Recovered open position after restart: ticket=", ticket);
      break;
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(handleMA    != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleSD    != INVALID_HANDLE) IndicatorRelease(handleSD);
   if(handleATR   != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleADX   != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleMA_H1 != INVALID_HANDLE) IndicatorRelease(handleMA_H1);
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
      Print("DAILY LOSS LIMIT HIT: ", DoubleToString(lossPercent, 2),
            "% lost (limit ", DoubleToString(dailyLimit, 1), "%). Trading stopped for today.");
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
   if(equity < 500)   return 10.0;
   if(equity < 2000)  return 7.0;
   if(equity < 5000)  return 5.0;
   if(equity < 20000) return 3.0;
   return 1.5;
}

double GetDailyLossLimitPct() {
   if(!InpUseDynamicRisk) return InpMaxDailyLossPct;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity < 500)   return 25.0;
   if(equity < 2000)  return 20.0;
   if(equity < 5000)  return 15.0;
   if(equity < 20000) return 10.0;
   return 7.0;
}

//+------------------------------------------------------------------+
int CountOwnPositions() {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         count++;
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

   int digits = (int)MathRound(-MathLog10(stepLot + 1e-10));
   if(digits < 0) digits = 0;

   return NormalizeDouble(lot, digits);
}

//+------------------------------------------------------------------+
void SetFillMode(MqlTradeRequest &req) {
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   if(fill & SYMBOL_FILLING_FOK)      req.type_filling = ORDER_FILLING_FOK;
   else if(fill & SYMBOL_FILLING_IOC) req.type_filling = ORDER_FILLING_IOC;
   else                               req.type_filling = ORDER_FILLING_RETURN;
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
      req.price     = NormalizeDouble(price, _Digits);
      req.deviation = InpSlippage;
      req.comment   = "N30 " + reason;
      SetFillMode(req);

      if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE)
         Print("Close position failed (", reason, "): ticket=", ticket, " retcode=", res.retcode);
      else
         Print("Position closed (", reason, "): ticket=", ticket);
   }
}

//+------------------------------------------------------------------+
//  IsWeekendRisk — block Friday late sessions and weekends
//+------------------------------------------------------------------+
bool IsWeekendRisk() {
   MqlDateTime dt;
   TimeCurrent(dt);
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
   // Closed H1 bar (shift 1): the value never repaints, so backtest and live agree
   if(CopyBuffer(handleMA_H1, 0, 1, 1, h1ma) < 1) return true;  // fail open

   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   if(isBuy) return bid > h1ma[0];
   return bid < h1ma[0];
}

//+------------------------------------------------------------------+
//  DetectPositionClosed — bookkeeping when SL/TP or a close fired.
//  Runs every tick so the loss cooldown starts immediately.
//+------------------------------------------------------------------+
void DetectPositionClosed() {
   if(glTicket == 0 || PositionSelectByTicket(glTicket)) return;

   double netPnL = 0;
   bool   found  = false;
   datetime from = (glOpenTime > 0) ? glOpenTime - 60 : TimeCurrent() - 86400;
   if(HistorySelect(from, TimeCurrent() + 1)) {
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--) {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0) continue;
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != glTicket) continue;
         netPnL = HistoryDealGetDouble(deal, DEAL_PROFIT)
                + HistoryDealGetDouble(deal, DEAL_SWAP)
                + HistoryDealGetDouble(deal, DEAL_COMMISSION);
         found = true;
         break;
      }
   }

   if(found && netPnL < 0 && InpCooldownMins > 0) {
      glLossCooldownUntil = TimeCurrent() + (long)InpCooldownMins * 60;
      Print("Losing trade (", DoubleToString(netPnL, 2), ") — entry cooldown until ",
            TimeToString(glLossCooldownUntil, TIME_DATE|TIME_MINUTES));
   }
   if(found)
      Print("Trade closed: ticket=", glTicket, " NetPnL=", DoubleToString(netPnL, 2));

   glTicket     = 0;
   glEntryPrice = 0;
   glOpenTime   = 0;
}

//+------------------------------------------------------------------+
void OnTick() {
   CheckDailyReset();
   DetectPositionClosed();

   // --- Safety layer: runs every tick because these must not wait for a bar ---
   if(IsDailyLossLimitHit()) {
      if(glTicket != 0) CloseAllOwnPositions("daily loss limit");
      return;
   }
   if(IsWeekendRisk()) {
      if(glTicket != 0) CloseAllOwnPositions("Friday Exit");
      return;
   }
   if(IsRedNewsImminent() && glTicket != 0)
      CloseAllOwnPositions("(red folder) high-impact news imminent");

   // --- Decision layer: runs exactly once per bar, on closed-bar data ---
   datetime curBar = iTime(TradeSymbol, _Period, 0);
   if(curBar == lastBarTime) return;
   lastBarTime = curBar;

   if(glTicket != 0 && PositionSelectByTicket(glTicket))
      ManageOnBar(curBar);
   else
      TryEnterOnBar();
}

//+------------------------------------------------------------------+
//  ManageOnBar — once-per-bar position management
//+------------------------------------------------------------------+
void ManageOnBar(datetime curBar) {
   double ma1[1], sd1[1], atr1[1];
   if(CopyBuffer(handleMA, 0, 1, 1, ma1) < 1 ||
      CopyBuffer(handleSD, 0, 1, 1, sd1) < 1 ||
      CopyBuffer(handleATR, 0, 1, 1, atr1) < 1) return;
   if(sd1[0] <= 0.0) return;

   double close1 = iClose(TradeSymbol, _Period, 1);
   double z1     = (close1 - ma1[0]) / sd1[0];

   long   posType = PositionGetInteger(POSITION_TYPE);
   double point   = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double bid     = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   int    barsHeld = (glOpenTime > 0) ? (int)((curBar - glOpenTime) / PeriodSeconds()) : 0;

   // 1) Backup mean-reached exit on CLOSED-bar Z (the limit TP usually fires first)
   bool zReverted = (posType == POSITION_TYPE_BUY  && z1 >= -InpExitZ) ||
                    (posType == POSITION_TYPE_SELL && z1 <=  InpExitZ);
   if(zReverted) {
      CloseAllOwnPositions("Mean reached (Z=" + DoubleToString(z1, 2) + ")");
      return;
   }

   // 2) Time exit: reversion that hasn't happened in MaxHoldBars isn't coming
   if(barsHeld >= InpMaxHoldBars) {
      CloseAllOwnPositions("Time Exit (" + IntegerToString(barsHeld) + " bars)");
      return;
   }

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   int    stopLevel = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double spreadPts = (ask - bid) / point;
   double costPts   = spreadPts + InpExtraCostPts;

   double newSL = currentSL;
   double newTP = currentTP;

   // 3) Breakeven once InpBreakevenATR x ATR in profit
   if(InpBreakevenATR > 0) {
      double bePrice = 0;
      if(posType == POSITION_TYPE_BUY && bid - glEntryPrice >= InpBreakevenATR * atr1[0]) {
         bePrice = glEntryPrice + (spreadPts + 2) * point;      // cover the round-trip cost
         if(bid - bePrice < stopLevel * point) bePrice = 0;     // too close to move yet
         if(bePrice > 0 && bePrice > newSL + 10 * point) newSL = bePrice;
      }
      if(posType == POSITION_TYPE_SELL && glEntryPrice - ask >= InpBreakevenATR * atr1[0]) {
         bePrice = glEntryPrice - (spreadPts + 2) * point;
         if(bePrice - ask < stopLevel * point) bePrice = 0;
         if(bePrice > 0 && (newSL == 0 || bePrice < newSL - 10 * point)) newSL = bePrice;
      }
   }

   // 4) Gravity TP: the mean drifts toward price over time, so retarget the
   //    limit TP to the fresh SMA each bar — but never below a floor that
   //    still covers the round-trip cost
   if(posType == POSITION_TYPE_BUY) {
      double floorTP = glEntryPrice + (costPts + 5) * point;
      double target  = MathMax(ma1[0], floorTP);
      if(target < currentTP - 20 * point && target - bid > stopLevel * point)
         newTP = NormalizeDouble(target, _Digits);
   } else {
      double floorTP = glEntryPrice - (costPts + 5) * point;
      double target  = MathMin(ma1[0], floorTP);
      if(target > currentTP + 20 * point && ask - target > stopLevel * point)
         newTP = NormalizeDouble(target, _Digits);
   }

   if(newSL != currentSL || newTP != currentTP) {
      MqlTradeRequest r = {}; MqlTradeResult rs = {};
      r.action   = TRADE_ACTION_SLTP;
      r.position = glTicket;
      r.symbol   = TradeSymbol;
      r.sl       = NormalizeDouble(newSL, _Digits);
      r.tp       = NormalizeDouble(newTP, _Digits);
      if(!OrderSend(r, rs) || rs.retcode != TRADE_RETCODE_DONE)
         Print("SL/TP modify failed: retcode=", rs.retcode);
   }
}

//+------------------------------------------------------------------+
//  TryEnterOnBar — once-per-bar entry evaluation on closed-bar data
//+------------------------------------------------------------------+
void TryEnterOnBar() {
   if(CountOwnPositions() > 0) return;
   if(TimeCurrent() < glLossCooldownUntil) return;
   if(IsNearNews()) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;

   double ma1[1], sd1[1], atr1[1];
   if(CopyBuffer(handleMA, 0, 1, 1, ma1) < 1 ||
      CopyBuffer(handleSD, 0, 1, 1, sd1) < 1 ||
      CopyBuffer(handleATR, 0, 1, 1, atr1) < 1) return;
   if(sd1[0] <= 0.0 || atr1[0] <= 0.0) return;

   double close1 = iClose(TradeSymbol, _Period, 1);
   double close2 = iClose(TradeSymbol, _Period, 2);
   double z1     = (close1 - ma1[0]) / sd1[0];

   // Direction from closed-bar Z
   int dir = 0;
   if(z1 <= -InpEntryZ) dir = 1;        // stretched down -> buy the snap-back
   else if(z1 >= InpEntryZ) dir = -1;   // stretched up -> sell it
   if(dir == 0) return;

   // Turn confirmation: last bar must have stopped making progress in the
   // stretch direction. Entering while the knife is still falling is the
   // single biggest tick-mode killer.
   if(InpRequireTurn) {
      if(dir == 1  && close1 < close2) return;   // still making lower closes
      if(dir == -1 && close1 > close2) return;   // still making higher closes
   }

   // ADX regime: mean reversion only in ranging markets (closed bar value)
   if(InpADXMax > 0 && handleADX != INVALID_HANDLE) {
      double adx1[1];
      if(CopyBuffer(handleADX, 0, 1, 1, adx1) >= 1 && adx1[0] > InpADXMax) return;
   }

   // Volatility regime: skip spike bars and dead markets
   if(InpATRAvgPeriod > 1) {
      double atrAvgBuf[];
      ArrayResize(atrAvgBuf, InpATRAvgPeriod);
      if(CopyBuffer(handleATR, 0, 1, InpATRAvgPeriod, atrAvgBuf) >= InpATRAvgPeriod) {
         double sum = 0;
         for(int i = 0; i < InpATRAvgPeriod; i++) sum += atrAvgBuf[i];
         double atrAvg = sum / InpATRAvgPeriod;
         if(atrAvg > 0) {
            double ratio = atr1[0] / atrAvg;
            if(ratio > InpMaxATRRatio || ratio < InpMinATRRatio) return;
         }
      }
   }

   double bid   = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);

   // --- COST GATE: the core Every-Tick defence ---
   double spreadPts = (ask - bid) / point;
   double costPts   = spreadPts + InpExtraCostPts;
   if(spreadPts > InpMaxSpreadPts) return;

   // StdDev is the fuel of the trade — it must dwarf the cost of the round trip
   double sdPts = sd1[0] / point;
   if(sdPts < InpMinSDCostMult * costPts) return;

   // The take-profit target IS the mean. Its distance from our fill price
   // must also be a clear multiple of the round-trip cost.
   double entryPrice = (dir == 1) ? ask : bid;
   double tpDistPts  = (dir == 1) ? (ma1[0] - entryPrice) / point
                                  : (entryPrice - ma1[0]) / point;
   if(tpDistPts < InpMinTPCostMult * costPts) return;

   if(!IsAlignedWithH1Trend(dir == 1)) return;

   ExecuteTrade((dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                entryPrice, ma1[0], atr1[0], z1);
}

//+------------------------------------------------------------------+
//  ExecuteTrade — market entry with server-side SL and limit TP at the mean
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double price, double meanPrice, double atrVal, double zScore) {
   double point     = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   int    stopLevel = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL);

   // SL: wide and volatility-aware, so real-tick spikes that OHLC modelling
   // hides don't turn into surprise stop-outs
   double slDist = MathMax(InpSLPoints * point, InpSLATRMult * atrVal);
   if(slDist < (stopLevel + 5) * point) slDist = (stopLevel + 5) * point;

   double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
   double tp = meanPrice;   // server-side limit at the mean: no spread paid on exit

   // Respect broker minimum stop distance for the TP
   if(type == ORDER_TYPE_BUY  && tp - price < stopLevel * point) tp = price + stopLevel * point;
   if(type == ORDER_TYPE_SELL && price - tp < stopLevel * point) tp = price - stopLevel * point;

   double riskPct = GetRiskPct();
   double risk    = AccountInfoDouble(ACCOUNT_BALANCE) * (riskPct / 100.0);
   double tickV   = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickS   = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickV <= 0 || tickS <= 0) {
      Print("Invalid tick value/size, skipping trade");
      return;
   }

   double lot = risk / (slDist * (tickV / tickS));
   lot = NormalizeLot(lot);

   double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   if(lot < minLot) {
      Print("Calculated lot below broker minimum — insufficient balance for this risk level.");
      return;
   }

   double marginRequired;
   if(!OrderCalcMargin(type, TradeSymbol, lot, price, marginRequired)) {
      Print("Failed to calculate margin, skipping trade");
      return;
   }
   if(marginRequired > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      Print("Insufficient margin: required=", marginRequired,
            " free=", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return;
   }

   string dir = (type == ORDER_TYPE_BUY) ? "B" : "S";
   string comment = "N30TR " + dir + "|Z" + DoubleToString(zScore, 2);
   if(StringLen(comment) > 31) comment = StringSubstr(comment, 0, 31);

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = TradeSymbol;
   req.volume    = lot;
   req.type      = type;
   req.price     = NormalizeDouble(price, _Digits);
   req.magic     = InpMagic;
   req.sl        = NormalizeDouble(sl, _Digits);
   req.tp        = NormalizeDouble(tp, _Digits);
   req.deviation = InpSlippage;
   req.comment   = comment;
   SetFillMode(req);

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("Entry failed: retcode=", res.retcode, " comment=", res.comment);
      return;
   }

   // Capture the position ticket (DEAL_POSITION_ID works on netting and hedging)
   glTicket = 0;
   if(res.deal > 0 && HistoryDealSelect(res.deal))
      glTicket = (ulong)HistoryDealGetInteger(res.deal, DEAL_POSITION_ID);
   if(glTicket == 0 || !PositionSelectByTicket(glTicket)) glTicket = res.order;
   if(!PositionSelectByTicket(glTicket)) glTicket = res.deal;

   glEntryPrice = (res.price > 0) ? res.price : price;
   glOpenTime   = TimeCurrent();

   Print("Trade opened: ticket=", glTicket, " ", EnumToString(type), " ", lot,
         " lots @ ", DoubleToString(glEntryPrice, _Digits),
         " SL=", DoubleToString(req.sl, _Digits),
         " TP(mean)=", DoubleToString(req.tp, _Digits),
         " Z=", DoubleToString(zScore, 2));
}
//+------------------------------------------------------------------+
// This work is my worship unto GOD
