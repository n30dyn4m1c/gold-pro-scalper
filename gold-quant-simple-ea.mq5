//+------------------------------------------------------------------+
//|                                      gold-quant-m5-scalper.mq5   |
//|                                  Copyright 2026, Gemini Quant Lab |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2026, Gemini Quant Lab"
#property link      ""
#property version   "4.00"
#property description "Gold Quant M5 Scalper - Mean Reversion Z-Score EA"

//--- Inputs: Strategy
input string   TradeSymbol    = "GOLD";
input double   InpEntryZ      = 2.2;      // Z-Score entry threshold (2.0–2.5 aggressive frequency)
input int      InpADXFilter   = 25;       // ADX range filter (allows mild trends)
input double   InpRiskPct     = 10.0;     // Risk % per trade
input double   InpATRStop     = 1.5;      // ATR multiplier for SL (1.2–1.8 for M5 gold)
input double   InpTP1_ATR     = 1.5;      // TP1: close 50% at this ATR profit
input double   InpHardTP_ATR  = 0.0;      // Hard TP safety net (ATR multiplier, 0 = disabled)
input double   InpTrailingATR = 2.0;      // ATR multiplier for trailing (loose for runners)
input int      InpStartHour   = 9;        // Trade window start hour (early London, GMT+2)
input int      InpEndHour     = 20;       // Trade window end hour, exclusive (late NY, GMT+2)
input int      InpStallBars   = 6;        // Close stalled trade after this many bars
input double   InpStallMinATR = 0.15;    // Min ATR profit required within stall window
input int      InpLoserBars   = 3;       // Close if profit < 0 after this many bars (0 = disabled)
input int      InpMagic       = 777333;   // Magic number

//--- Inputs: Indicators
input int      InpMAPeriod    = 20;       // MA / StdDev period
input int      InpATRPeriod   = 14;       // ATR period
input int      InpADXPeriod   = 14;       // ADX period
input int      InpRSIPeriod   = 14;       // RSI period

//--- Inputs: RSI Confirmation
input bool     InpUseRSIFilter   = false; // Enable RSI confirmation filter (disabled for max aggression)
input double   InpRSIOversold    = 35.0;  // RSI below this = oversold (allow BUY)
input double   InpRSIOverbought  = 65.0;  // RSI above this = overbought (allow SELL)

//--- Inputs: Execution
input int      InpSlippage    = 30;       // Max slippage in points
input double   InpMaxSpreadPts = 80.0;    // Max allowed spread in points (gold spikes normal)

//--- Inputs: Daily Loss Limit
input bool     InpUseDailyLossLimit  = true;  // Enable max daily loss stop
input double   InpMaxDailyLossPct    = 40.0;   // Max daily loss % (hot limit, monitor manually)

//--- Global Handles & State
int handleMA, handleSD, handleATR, handleADX, handleRSI;
ulong partialClosedTicket = 0;  // Tracks which position has had TP1 taken
datetime entryTime = 0;          // Tracks when current trade was opened

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
   handleRSI   = iRSI(TradeSymbol, _Period, InpRSIPeriod, PRICE_CLOSE);

   if(handleMA == INVALID_HANDLE || handleSD == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE || handleADX == INVALID_HANDLE ||
      handleRSI == INVALID_HANDLE) {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   // Initialize daily loss tracker
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
   if(handleRSI   != INVALID_HANDLE) IndicatorRelease(handleRSI);
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
bool IsPartialClosed() {
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   return (ticket == partialClosedTicket && partialClosedTicket != 0);
}

//+------------------------------------------------------------------+
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
   // Daily loss reset check
   CheckDailyReset();

   double ma[1], sd[1], atr[1], adx[1], rsi[1];
   if(CopyBuffer(handleMA,0,0,1,ma)<1 || CopyBuffer(handleSD,0,0,1,sd)<1 ||
      CopyBuffer(handleATR,0,0,1,atr)<1 || CopyBuffer(handleADX,0,0,1,adx)<1 ||
      CopyBuffer(handleRSI,0,0,1,rsi)<1) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);

   if(sd[0] <= 0.0) return;

   double zScore = (bid - ma[0]) / sd[0];
   bool lossLimitHit = IsDailyLossLimitHit();

   // --- DAILY LOSS: close everything and stop ---
   if(lossLimitHit) {
      if(SelectOwnPosition()) CloseAllOwnPositions("daily loss limit");
      Comment("--- GOLD QUANT M5 SCALPER v4 ---\n",
              "DAILY LOSS LIMIT REACHED - TRADING STOPPED\n",
              "Loss: ", DoubleToString(((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0, 2), "%");
      return;
   }

   // --- POSITION MANAGEMENT ---
   if(SelectOwnPosition()) {
      // 0. Stall/loser timeout
      if(entryTime > 0) {
         int barsSinceEntry = iBarShift(TradeSymbol, _Period, entryTime);
         double profitATR = GetPositionProfitATR(atr[0]);

         // Fast cut: close underwater trades after 5 bars
         if(InpLoserBars > 0 && barsSinceEntry >= InpLoserBars && profitATR < 0) {
            Print("Loser cut: ", barsSinceEntry, " bars, ", DoubleToString(profitATR, 2), " ATR (underwater). Closing.");
            CloseAllOwnPositions("underwater trade");
         }
         // Stall cut: close stagnant trades after 8 bars
         else if(barsSinceEntry >= InpStallBars && profitATR < InpStallMinATR) {
            Print("Stall timeout: ", barsSinceEntry, " bars, ", DoubleToString(profitATR, 2), " ATR profit. Closing.");
            CloseAllOwnPositions("stalled trade");
         }
      }

      // Re-check position still exists after potential stall close
      if(SelectOwnPosition()) {
         bool alreadyPartial = IsPartialClosed();
         double profitATR = GetPositionProfitATR(atr[0]);

         // 1. TP1: Close 50% at +InpTP1_ATR profit
         if(!alreadyPartial && profitATR >= InpTP1_ATR) {
            ScaleOutHalf();
            Print("TP1 Hit at ", DoubleToString(profitATR, 2), " ATR: 50% Closed. SL moved to Breakeven.");
         }

         // 3. TRAILING
         HandleTrailingStop(atr[0]);
      }
   } else {
      // Reset state for next trade
      partialClosedTicket = 0;
      entryTime = 0;

      // --- ENTRY LOGIC ---
      bool inWindow  = (dt.hour >= InpStartHour && dt.hour < InpEndHour);
      bool isRanging = (adx[0] < InpADXFilter);
      double spreadPts = (ask - bid) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      bool spreadOk  = (spreadPts <= InpMaxSpreadPts);

      // RSI confirmation: buy only if oversold, sell only if overbought
      bool rsiBuyOk  = (!InpUseRSIFilter || rsi[0] < InpRSIOversold);
      bool rsiSellOk = (!InpUseRSIFilter || rsi[0] > InpRSIOverbought);

      if(inWindow && isRanging && spreadOk && MathAbs(zScore) > InpEntryZ) {
         if(zScore < 0 && rsiBuyOk)       ExecuteTrade(ORDER_TYPE_BUY, ask, atr[0]);
         else if(zScore > 0 && rsiSellOk) ExecuteTrade(ORDER_TYPE_SELL, bid, atr[0]);
      }
   }

   double dailyLossPct = ((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0;

   Comment("--- GOLD QUANT M5 SCALPER v4 ---\n",
           "Z-Score: ", DoubleToString(zScore, 2), "\n",
           "ADX: ", DoubleToString(adx[0], 1), "\n",
           "ATR: ", DoubleToString(atr[0], 2), "\n",
           "Spread: ", DoubleToString((ask-bid)/SymbolInfoDouble(TradeSymbol,SYMBOL_POINT), 1), " pts\n",
           "Daily P/L: ", DoubleToString(-dailyLossPct, 2), "% / -", DoubleToString(InpMaxDailyLossPct, 1), "% limit");
}

//+------------------------------------------------------------------+
void ScaleOutHalf() {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double vol = PositionGetDouble(POSITION_VOLUME);
   double halfVol = NormalizeLot(vol * 0.5);

   if(halfVol >= vol) {
      Print("Cannot scale out: volume too small to split");
      return;
   }

   req.action = TRADE_ACTION_DEAL;
   req.position = PositionGetInteger(POSITION_TICKET);
   req.symbol = TradeSymbol;
   req.volume = halfVol;
   req.type = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   req.price = (req.type==ORDER_TYPE_SELL)?SymbolInfoDouble(TradeSymbol, SYMBOL_BID):SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   req.deviation = InpSlippage;
   uint fill = (uint)SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   req.type_filling = (fill & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;

   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE) {
      Print("ScaleOut failed: retcode=", res.retcode, " comment=", res.comment);
      return;
   }

   // Mark this position as partially closed
   partialClosedTicket = req.position;

   // Move SL to breakeven (entry + spread cost)
   if(!SelectOwnPosition()) return;

   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentTP  = PositionGetDouble(POSITION_TP);
   long   posType    = PositionGetInteger(POSITION_TYPE);
   double spread     = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK) - SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   int    digits     = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   double beSL;
   if(posType == POSITION_TYPE_BUY)
      beSL = NormalizeDouble(entryPrice + spread, digits);
   else
      beSL = NormalizeDouble(entryPrice - spread, digits);

   MqlTradeRequest beReq = {}; MqlTradeResult beRes = {};
   beReq.action   = TRADE_ACTION_SLTP;
   beReq.position = PositionGetInteger(POSITION_TICKET);
   beReq.symbol   = TradeSymbol;
   beReq.sl       = beSL;
   beReq.tp       = currentTP;

   if(!OrderSend(beReq, beRes) || beRes.retcode != TRADE_RETCODE_DONE) {
      Print("Breakeven modify failed: retcode=", beRes.retcode);
   }
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

   // Hard TP as safety net (protects against disconnects)
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
      entryTime = TimeCurrent();
   }
}
//+------------------------------------------------------------------+
