//+------------------------------------------------------------------+
//|                                  bitcoin-quant-simple-ea.mq5     |
//|                                  Copyright 2026, Gemini Quant Lab |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2026, Gemini Quant Lab"
#property link      ""
#property version   "3.00"
#property description "Bitcoin Quant M15 Scalper - Mean Reversion Z-Score EA"

//--- Inputs: Strategy
input string   TradeSymbol    = "BTCUSD";
input double   InpEntryZ      = 2.2;      // Z-Score entry (back to proven gold threshold)
input int      InpADXFilter   = 22;       // ADX range filter (moderate — filters strong trends only)
input double   InpRiskPct     = 10.0;     // Risk % per trade
input double   InpATRStop     = 1.5;      // ATR multiplier for SL (wider — BTC whipsaws more)
input double   InpHardTP_ATR  = 1.5;      // Hard TP (ATR multiplier) — take profit fast, BTC snaps back quick
input int      InpStartHour   = 0;        // Trade window start hour (24/7 market)
input int      InpEndHour     = 24;       // Trade window end hour (spread filter gates quality)
input int      InpStallBars   = 6;        // Close stalled trade after this many bars (6x15m = 90min)
input double   InpStallMinATR = 0.2;      // Min ATR profit required within stall window
input int      InpLoserBars   = 3;        // Close if profit < 0 after this many bars (3x15m = 45min)
input int      InpMagic       = 777444;   // Magic number (different from gold EA)

//--- Inputs: Indicators
input int      InpMAPeriod    = 20;       // MA / StdDev period (5h on M15)
input int      InpATRPeriod   = 14;       // ATR period
input int      InpADXPeriod   = 14;       // ADX period
input int      InpRSIPeriod   = 14;       // RSI period

//--- Inputs: RSI Confirmation
input bool     InpUseRSIFilter   = true;  // RSI confirmation ON (prevents fading momentum)
input double   InpRSIOversold    = 38.0;  // RSI below this = oversold (allow BUY)
input double   InpRSIOverbought  = 62.0;  // RSI above this = overbought (allow SELL)

//--- Inputs: Execution
input int      InpSlippage    = 50;       // Max slippage in points (crypto slips more)
input double   InpMaxSpreadPts = 5000.0;  // Max spread in points (~$50 if point=0.01)

//--- Inputs: Daily Loss Limit
input bool     InpUseDailyLossLimit  = true;  // Enable max daily loss stop
input double   InpMaxDailyLossPct    = 25.0;  // Max daily loss % (survive to trade tomorrow)

//--- Global Handles & State
int handleMA, handleSD, handleATR, handleADX, handleRSI;
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
      Comment("--- BTC QUANT M15 v1 ---\n",
              "DAILY LOSS LIMIT REACHED - TRADING STOPPED\n",
              "Loss: ", DoubleToString(((dailyStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyStartBalance) * 100.0, 2), "%");
      return;
   }

   // --- POSITION MANAGEMENT ---
   if(SelectOwnPosition()) {
      if(entryTime > 0) {
         int barsSinceEntry = iBarShift(TradeSymbol, _Period, entryTime);
         double profitATR = GetPositionProfitATR(atr[0]);

         // Fast cut: close underwater trades
         if(InpLoserBars > 0 && barsSinceEntry >= InpLoserBars && profitATR < 0) {
            Print("Loser cut: ", barsSinceEntry, " bars, ", DoubleToString(profitATR, 2), " ATR. Closing.");
            CloseAllOwnPositions("underwater trade");
         }
         // Stall cut: close stagnant trades
         else if(barsSinceEntry >= InpStallBars && profitATR < InpStallMinATR) {
            Print("Stall timeout: ", barsSinceEntry, " bars, ", DoubleToString(profitATR, 2), " ATR. Closing.");
            CloseAllOwnPositions("stalled trade");
         }
      }
   } else {
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

   Comment("--- BTC QUANT M15 v1 ---\n",
           "Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), "\n",
           "Z-Score: ", DoubleToString(zScore, 2), "\n",
           "ADX: ", DoubleToString(adx[0], 1), "\n",
           "ATR: ", DoubleToString(atr[0], 2), "\n",
           "Spread: ", DoubleToString((ask-bid)/SymbolInfoDouble(TradeSymbol,SYMBOL_POINT), 1), " pts\n",
           "Daily P/L: ", DoubleToString(-dailyLossPct, 2), "% / -", DoubleToString(InpMaxDailyLossPct, 1), "% limit");
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

   double tpD = a * InpHardTP_ATR;
   double tp = (type == ORDER_TYPE_BUY) ? (p + tpD) : (p - tpD);
   tp = NormalizeDouble(tp, digits);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = TradeSymbol;
   req.volume       = lot;
   req.type         = type;
   req.price        = p;
   req.magic        = InpMagic;
   req.sl           = NormalizeDouble(sl, digits);
   req.tp           = tp;
   req.deviation    = InpSlippage;
   req.comment      = "BQS";
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
