//+------------------------------------------------------------------+
//|                                        bot4algo_scalping.mq5     |
//|                                       Copyright 2026, Bot4Algo   |
//|                                                                  |
//|  STRADDLE SCALPER.  No indicator, no bias, no direction call.    |
//|                                                                  |
//|  The EA never decides which way the market is going. It puts a   |
//|  stop order on BOTH sides of the current price and lets the      |
//|  market choose. Whichever side is hit becomes the trade; the     |
//|  other is cancelled the same instant.                            |
//|                                                                  |
//|  THE CYCLE                                                       |
//|    1. flat  ->  buy stop  = ASK + InpDistance                    |
//|                 sell stop = BID - InpDistance                    |
//|                 both at InpLot, both with NO stop loss on them   |
//|    2. one fills  ->  the other is deleted (OCO) and the stop     |
//|                      loss is attached to the new position        |
//|    3. the position runs on its stop loss alone. There is NO      |
//|       take profit - the trailing stop is the only exit.          |
//|    4. it closes  ->  a new straddle goes up on the next tick,    |
//|       measured from the price right then                         |
//|                                                                  |
//|  THE TRAIL  (this is the whole edge - everything else is plumbing)|
//|    initial stop  =  entry -/+ InpStopLoss                        |
//|    while profit  <  InpTrailStart   the stop does not move       |
//|    once profit  >=  InpTrailStart   stop = peak -/+ InpTrailStop |
//|                                     and it never moves back      |
//|                                                                  |
//|    "peak" is the best price the position has SEEN, not the price |
//|    now: highest BID for a long, lowest ASK for a short. Measuring |
//|    from the current price instead would let the stop walk back    |
//|    down on a pullback, which is the one thing a trailing stop     |
//|    must never do.                                                |
//|                                                                  |
//|    With the defaults (start 50, trail 20) the stop's first jump   |
//|    lands 30 points IN PROFIT. That is why a trade can only ever   |
//|    end at -InpStopLoss or at +30 points or better: there is no    |
//|    such thing as a small loser here, and no such thing as a       |
//|    breakeven scratch.                                             |
//|                                                                  |
//|  LOT is FIXED. No martingale, no recovery ladder, no doubling.    |
//|                                                                  |
//|  WHAT THIS COSTS YOU                                              |
//|    Losers are a full InpStopLoss; winners are usually smaller     |
//|    than that. The system therefore lives or dies on its WIN RATE  |
//|    alone. It is a breakout bet: it pays in a market that keeps    |
//|    going, and it pays the spread twice on every fake-out in a     |
//|    market that does not.                                          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Bot4Algo"
#property link      ""
//--- ONE place for the build number. The panel prints it, so which .ex5 is
//    actually loaded is readable off the chart.
#define  EA_VER "1.00"
#property version   EA_VER
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| LICENCE - set these before compiling FOR EACH CLIENT              |
//|                                                                   |
//|  Hand the client the .ex5 ONLY.                                   |
//|                                                                   |
//|  Currently DISABLED so the EA runs on any account while it is     |
//|  being tested. Set LICENSE_ENABLED to true and put the client's   |
//|  login in LICENSE_LOGIN before shipping.                          |
//|                                                                   |
//|  The clock is TimeCurrent() - the BROKER's time. TimeLocal() is   |
//|  the client's own PC clock and they can wind it back.             |
//+------------------------------------------------------------------+
#define LICENSE_ENABLED   false
#define LICENSE_LOGIN     25953819                  // allowed MT5 account
#define LICENSE_EXPIRY    D'2026.12.31 23:59:00'    // last valid moment
#define LICENSE_WARN_DAYS 1                         // warn this many days ahead

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//|                                                                   |
//|  Everything is in POINTS, so the same numbers move with the       |
//|  symbol's own digits. On a 2-digit gold feed 1 point = 0.01, so   |
//|  100 points = $1.00 of price. OnInit prints both, because a       |
//|  distance that is right on gold is nonsense on a 5-digit FX pair  |
//|  and the print is what makes that obvious before it trades.       |
//+------------------------------------------------------------------+
input group "=== Straddle ==="
input int    InpDistance     = 100;   // stop orders this far EACH SIDE of price
input double InpLot          = 0.01;  // fixed lot - no progression

input group "=== Exit  (there is no take profit) ==="
input int    InpStopLoss     = 100;   // initial stop, from the fill price
input int    InpTrailStart   = 50;    // profit needed before the stop moves at all
input int    InpTrailStop    = 20;    // stop follows this far behind the PEAK
input int    InpTrailStep    = 1;     // ignore improvements smaller than this

input group "=== Safety ==="
input int    InpMaxSpread    = 0;     // skip re-arming above this spread. 0 = off
input int    InpSlippage     = 30;    // deviation, points

input group "=== Display / log ==="
input bool   InpShowPanel    = true;
input int    InpPanelFont    = 7;
input bool   InpLogTrades    = true;
input bool   InpVerbose      = false; // log every straddle and every trail step
input long   InpMagic        = 990909; // MUST differ from any other EA here

//+------------------------------------------------------------------+
//| GLOBALS                                                           |
//+------------------------------------------------------------------+
CTrade   g_trade;
string   g_symbol;
int      g_digits;
double   g_point;
double   g_eps;

//--- inputs converted to price once, so nothing multiplies by g_point twice
double   g_dist, g_sl, g_trailStart, g_trailStop, g_trailStep;

//--- the live position (ours)
bool     g_havePos     = false;
ulong    g_posTicket   = 0;
long     g_posId       = 0;
int      g_posDir      = 0;
double   g_posLot      = 0;
double   g_posEntry    = 0;
datetime g_posOpenTime = 0;

//--- best price this position has SEEN. Highest bid for a long, lowest ask
//    for a short. The trail is measured from here, never from the price now.
double   g_peak        = 0;
bool     g_trailOn     = false;

//--- the two pendings we currently have on the book
ulong    g_buyStop  = 0;
ulong    g_sellStop = 0;

//--- day counters for the panel
datetime g_dayStart  = 0;
int      g_dayTrades = 0;
double   g_dayProfit = 0;

string   g_tradeFile;
string   g_pfx  = "SCP_";
string   g_ppfx = "SCPP_";
string   g_lastAction = "init";
bool     g_licOK = true;

//--- two positions must never exist; this throttles the alert if they do
datetime g_lastTwoAlert = 0;
datetime g_lastFailAlert = 0;

//+------------------------------------------------------------------+
//| LICENCE                                                           |
//+------------------------------------------------------------------+
//  WRONG ACCOUNT  -> refuses to load, unless one of our positions is already
//                    open (it would be left with nothing watching its trail).
//  EXPIRED        -> loads and winds down: no new straddle, but the open
//                    position keeps its trailing stop until it exits.
bool CheckExpiry(bool announce)
{
   if(!LICENSE_ENABLED) return true;
   datetime now = TimeCurrent();          // BROKER time, not the client's PC
   if(now <= 0) return true;              // no quote yet on a cold boot
   if(now >= LICENSE_EXPIRY) return false;

   if(announce)
   {
      int daysLeft = (int)((LICENSE_EXPIRY - now) / 86400);
      Print("[SCP] licence valid, ", daysLeft, " day(s) remaining (expires ",
            TimeToString(LICENSE_EXPIRY, TIME_DATE | TIME_MINUTES), ")");
      if(daysLeft <= LICENSE_WARN_DAYS)
         Alert("Bot4Algo Scalping licence expires ",
               TimeToString(LICENSE_EXPIRY, TIME_DATE | TIME_MINUTES),
               " - ", daysLeft, " day(s) left.");
   }
   return true;
}

bool ValidateLicence()
{
   if(!LICENSE_ENABLED)
   { Print("[SCP] LICENCE CHECK DISABLED (testing build)"); g_licOK = true; return true; }

   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(login != LICENSE_LOGIN)
   {
      Print("[SCP] LICENCE: account ", login, " is not licensed (this build is "
            "for ", (long)LICENSE_LOGIN, ")");
      Alert("Bot4Algo Scalping is not licensed for account ", login);
      return false;
   }

   g_licOK = CheckExpiry(true);
   if(!g_licOK)
   {
      Print("[SCP] LICENCE EXPIRED - winding down: no new straddle, the open "
            "position keeps its trailing stop");
      Alert("Bot4Algo Scalping licence expired. No new trades.");
   }
   return true;
}

void RecheckLicence()
{
   if(!g_licOK) return;
   if(CheckExpiry(false)) return;
   g_licOK = false;
   Print("[SCP] LICENCE EXPIRED while running - winding down");
   Alert("Bot4Algo Scalping licence expired. No new trades from now on.");
   g_lastAction = "licence expired";
}

//+------------------------------------------------------------------+
//| SMALL HELPERS                                                     |
//+------------------------------------------------------------------+
double Bid() { return SymbolInfoDouble(g_symbol, SYMBOL_BID); }
double Ask() { return SymbolInfoDouble(g_symbol, SYMBOL_ASK); }
double Spread() { return Ask() - Bid(); }
double Nz(double p) { return NormalizeDouble(p, g_digits); }

//--- how close to the market the broker will let a stop or a pending sit.
//    Ignoring this is why "modify rejected" loops happen: the EA asks for the
//    same illegal price on every tick and the server refuses it every time.
double StopsLevel()
{
   double lvl = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   double frz = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * g_point;
   return MathMax(lvl, frz);
}

double NormalizeLot(double lot)
{
   double mn = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0) st = 0.01;
   lot = MathRound(lot / st) * st;
   if(lot < mn) lot = mn;
   if(lot > mx) lot = mx;
   return NormalizeDouble(lot, 2);
}

//--- a retcode the server ACCEPTED. PLACED means the request was taken and the
//    deal is on its way - calling that a failure is how an EA ends up sending
//    the same order twice.
bool Accepted(uint rc)
{
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED ||
           rc == TRADE_RETCODE_DONE_PARTIAL);
}

//+------------------------------------------------------------------+
//| POSITION / ORDER DISCOVERY                                        |
//+------------------------------------------------------------------+
bool FindOurPosition(ulong &ticket, long &id, int &dir, double &lot,
                     double &entry, datetime &opened, double &sl, int &count)
{
   count = 0;
   bool got = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;

      count++;
      if(got) continue;                 // keep the first, but finish counting
      ticket = t;
      id     = PositionGetInteger(POSITION_IDENTIFIER);
      dir    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      lot    = PositionGetDouble(POSITION_VOLUME);
      entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      opened = (datetime)PositionGetInteger(POSITION_TIME);
      sl     = PositionGetDouble(POSITION_SL);
      got    = true;
   }
   return got;
}

//--- every pending of ours, newest first
int OurPendings(ulong &tickets[], int &types[])
{
   int n = 0;
   ArrayResize(tickets, 0);
   ArrayResize(types, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      long ty = OrderGetInteger(ORDER_TYPE);
      if(ty != ORDER_TYPE_BUY_STOP && ty != ORDER_TYPE_SELL_STOP) continue;

      ArrayResize(tickets, n + 1);
      ArrayResize(types, n + 1);
      tickets[n] = t;
      types[n]   = (int)ty;
      n++;
   }
   return n;
}

//--- returns true when NO pending of ours is left. A false return means one is
//    mid-fill or the delete was refused - the caller must not assume a clean
//    book and must not place a fresh straddle on top.
bool DeletePendings(string why)
{
   ulong tk[]; int ty[];
   int n = OurPendings(tk, ty);
   if(n == 0) return true;

   for(int i = 0; i < n; i++)
   {
      if(g_trade.OrderDelete(tk[i]))
      {
         if(InpVerbose) Print("[SCP] pending ", tk[i], " deleted (", why, ")");
      }
      else
         Print("[SCP] delete of ", tk[i], " refused (", g_trade.ResultRetcode(),
               ") - it may be filling; retry next tick");
   }
   ulong tk2[]; int ty2[];
   return (OurPendings(tk2, ty2) == 0);
}

//+------------------------------------------------------------------+
//| THE STRADDLE                                                      |
//+------------------------------------------------------------------+
//  The legs go on the book with NO stop loss, exactly as the reference EA does
//  it: in its terminal the two pending rows show an empty S/L column, and the
//  stop only appears once a leg has become a position. AttachStop puts it on
//  the moment the fill is seen, on the same tick.
void PlaceStraddle()
{
   if(!g_licOK) return;

   double ask = Ask(), bid = Bid();
   if(ask <= 0 || bid <= 0) return;

   if(InpMaxSpread > 0 && Spread() > InpMaxSpread * g_point)
   {
      static datetime lastSprAlert = 0;
      if(InpVerbose && TimeCurrent() - lastSprAlert >= 60)
      {
         lastSprAlert = TimeCurrent();
         Print("[SCP] spread ", DoubleToString(Spread() / g_point, 0),
               " over the limit ", InpMaxSpread, " - not re-arming");
      }
      return;
   }

   double lot = NormalizeLot(InpLot);
   if(lot <= 0) return;

   double buyPx  = Nz(ask + g_dist);
   double sellPx = Nz(bid - g_dist);

   //--- a pending must sit at least the stops level away from the market. The
   //    straddle distance is normally far bigger, but a broker that widens the
   //    level during news would otherwise have every order rejected in a loop.
   double lvl = StopsLevel();
   if(buyPx - ask < lvl || bid - sellPx < lvl)
   {
      static datetime lastLvlAlert = 0;
      if(TimeCurrent() - lastLvlAlert >= 300)
      {
         lastLvlAlert = TimeCurrent();
         Print("[SCP] stops level ", DoubleToString(lvl / g_point, 0),
               " points is wider than the straddle distance ", InpDistance,
               " - cannot place. Increase InpDistance.");
      }
      return;
   }

   double need = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, g_symbol, lot, ask, need) &&
      need > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      static datetime lastMargin = 0;
      if(TimeCurrent() - lastMargin >= 300)
      {
         lastMargin = TimeCurrent();
         Print("[SCP] MARGIN SHORT: need ", DoubleToString(need, 2),
               " free ", DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
         Alert("Bot4Algo Scalping: margin short");
      }
      return;
   }

   //--- 0.0 stop loss, 0.0 take profit: the pending carries neither. The stop
   //    is attached to the POSITION the instant the leg fills.
   bool okB = g_trade.BuyStop(lot, buyPx, g_symbol, 0.0, 0.0,
                              ORDER_TIME_GTC, 0, "SCP BuyStop");
   uint rcB = g_trade.ResultRetcode();
   if(Accepted(rcB)) g_buyStop = g_trade.ResultOrder();

   bool okS = g_trade.SellStop(lot, sellPx, g_symbol, 0.0, 0.0,
                               ORDER_TIME_GTC, 0, "SCP SellStop");
   uint rcS = g_trade.ResultRetcode();
   if(Accepted(rcS)) g_sellStop = g_trade.ResultOrder();

   //--- HALF a straddle is a directional bet nobody asked for. If only one leg
   //    went on, take it straight back off and try the pair again next tick.
   if(Accepted(rcB) != Accepted(rcS))
   {
      Print("[SCP] only one leg was accepted (buy ", rcB, " / sell ", rcS,
            ") - removing it, the straddle is placed as a pair or not at all");
      DeletePendings("half straddle");
      g_buyStop = 0; g_sellStop = 0;
      return;
   }

   if(!Accepted(rcB))
   {
      if(TimeCurrent() - g_lastFailAlert >= 300)
      {
         g_lastFailAlert = TimeCurrent();
         Print("[SCP] straddle rejected: buy ", rcB, " / sell ", rcS, " ",
               g_trade.ResultRetcodeDescription());
      }
      g_buyStop = 0; g_sellStop = 0;
      return;
   }

   g_lastAction = StringFormat("straddle %s / %s",
                               DoubleToString(buyPx, g_digits),
                               DoubleToString(sellPx, g_digits));
   if(InpVerbose)
      Print("[SCP] straddle  buy stop ", DoubleToString(buyPx, g_digits),
            "  sell stop ", DoubleToString(sellPx, g_digits),
            "   (bid ", DoubleToString(bid, g_digits),
            " ask ", DoubleToString(ask, g_digits), ")");
   DrawStraddle(buyPx, sellPx);
}

//+------------------------------------------------------------------+
//| ADOPT / RELEASE                                                   |
//+------------------------------------------------------------------+
void AdoptPosition(ulong ticket, long id, int dir, double lot, double entry,
                   datetime opened, double sl, string how)
{
   g_havePos     = true;
   g_posTicket   = ticket;
   g_posId       = id;
   g_posDir      = dir;
   g_posLot      = lot;
   g_posEntry    = entry;
   g_posOpenTime = opened;

   //--- Rebuild the peak. On a fresh fill it is simply the entry. On a RESTART
   //    the position may already be trailing, and the only surviving record of
   //    how far it ran is the stop itself: peak = stop + the trail distance.
   //    Starting the peak at the entry instead would let the stop be dragged
   //    backwards on the first tick - a trailing stop that gives ground.
   g_trailOn = false;
   g_peak    = entry;
   if(sl > 0)
   {
      if(dir > 0 && sl > entry + g_eps) { g_trailOn = true; g_peak = sl + g_trailStop; }
      if(dir < 0 && sl < entry - g_eps) { g_trailOn = true; g_peak = sl - g_trailStop; }
   }

   Print("[SCP] ", how, " ", (dir > 0 ? "BUY " : "SELL "), DoubleToString(lot, 2),
         " @ ", DoubleToString(entry, g_digits),
         "   SL ", (sl > 0 ? DoubleToString(sl, g_digits) : "NONE"),
         (g_trailOn ? "  (already trailing, peak rebuilt "
                      + DoubleToString(g_peak, g_digits) + ")" : ""));
   g_lastAction = (dir > 0 ? "BUY " : "SELL ") + DoubleToString(lot, 2) +
                  " @ " + DoubleToString(entry, g_digits);
   AttachStop();
}

//--- The pendings carry no stop, so THIS is what protects the trade. It runs on
//    the fill tick and again on every tick afterwards, because this EA has no
//    take profit: a position with no stop has no exit at all. Idempotent - it
//    does nothing once a stop is on.
void AttachStop()
{
   if(!g_havePos) return;
   if(!PositionSelectByTicket(g_posTicket)) return;
   if(PositionGetDouble(POSITION_SL) > 0) return;

   double want = (g_posDir > 0) ? Nz(g_posEntry - g_sl) : Nz(g_posEntry + g_sl);
   double lvl  = StopsLevel();
   double bid = Bid(), ask = Ask();
   if(g_posDir > 0 && bid - want < lvl) want = Nz(bid - lvl);
   if(g_posDir < 0 && want - ask < lvl) want = Nz(ask + lvl);

   if(g_trade.PositionModify(g_posTicket, want, 0.0))
      Print("[SCP] stop attached ", DoubleToString(want, g_digits), "  (",
            InpStopLoss, " pts from the fill)");
   else
      Print("[SCP] COULD NOT ATTACH A STOP (", g_trade.ResultRetcode(), " ",
            g_trade.ResultRetcodeDescription(),
            ") - the position is UNPROTECTED, retrying next tick");
}

//--- a position of ours disappeared: book it and let the next tick re-arm
void OnPositionGone()
{
   double profit = 0;
   if(g_posId > 0 && HistorySelectByPosition(g_posId))
   {
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         profit += HistoryDealGetDouble(d, DEAL_PROFIT)
                 + HistoryDealGetDouble(d, DEAL_SWAP)
                 + HistoryDealGetDouble(d, DEAL_COMMISSION);
      }
   }

   g_dayTrades++;
   g_dayProfit += profit;
   g_lastAction = StringFormat("%s closed %+.2f",
                               (g_posDir > 0 ? "BUY" : "SELL"), profit);
   Print("[SCP] closed ", (g_posDir > 0 ? "BUY " : "SELL "),
         DoubleToString(g_posLot, 2), " @ ", DoubleToString(g_posEntry, g_digits),
         "  profit ", DoubleToString(profit, 2),
         "   today ", g_dayTrades, " trades ", DoubleToString(g_dayProfit, 2));
   LogRow("close", g_posDir, g_posLot, g_posEntry, profit);

   g_havePos = false; g_posTicket = 0; g_posId = 0;
   g_peak = 0; g_trailOn = false;
   ObjectDelete(0, g_pfx + "sl");
}

//+------------------------------------------------------------------+
//| THE TRAIL                                                         |
//+------------------------------------------------------------------+
void Trail()
{
   if(!g_havePos) return;
   if(!PositionSelectByTicket(g_posTicket)) return;

   double bid = Bid(), ask = Ask();
   if(bid <= 0 || ask <= 0) return;

   double curSL  = PositionGetDouble(POSITION_SL);
   double lvl    = StopsLevel();
   double want   = 0;
   double profit = 0;

   if(g_posDir > 0)
   {
      //--- a long is closed at the BID, so the bid is what the profit and the
      //    peak are measured on. Using the ask would overstate both by the
      //    spread and trail the stop a spread too tight.
      if(bid > g_peak) g_peak = bid;
      profit = g_peak - g_posEntry;
      if(profit < g_trailStart - g_eps) return;
      want = Nz(g_peak - g_trailStop);

      //--- never closer to the market than the broker allows
      if(bid - want < lvl) want = Nz(bid - lvl);
      //--- and never backwards
      if(curSL > 0 && want <= curSL + g_trailStep - g_eps) return;
      if(want >= bid) return;                      // would fire instantly
   }
   else
   {
      if(ask < g_peak || g_peak <= 0) g_peak = ask;
      profit = g_posEntry - g_peak;
      if(profit < g_trailStart - g_eps) return;
      want = Nz(g_peak + g_trailStop);

      if(want - ask < lvl) want = Nz(ask + lvl);
      if(curSL > 0 && want >= curSL - g_trailStep + g_eps) return;
      if(want <= ask) return;
   }

   if(g_trade.PositionModify(g_posTicket, want, 0.0))
   {
      if(!g_trailOn)
      {
         g_trailOn = true;
         Print("[SCP] trail ON at +", DoubleToString(profit / g_point, 0),
               " points - stop jumps to ", DoubleToString(want, g_digits),
               "  (locked +", DoubleToString(
                  (g_posDir > 0 ? want - g_posEntry : g_posEntry - want) / g_point, 0),
               " points)");
      }
      else if(InpVerbose)
         Print("[SCP] trail -> ", DoubleToString(want, g_digits),
               "  peak ", DoubleToString(g_peak, g_digits));
      g_lastAction = "trail " + DoubleToString(want, g_digits);
      DrawSL(want);
   }
   else
   {
      uint rc = g_trade.ResultRetcode();
      //--- INVALID_STOPS just means the market moved into it; the next tick
      //    recomputes. Anything else is worth seeing.
      if(rc != TRADE_RETCODE_INVALID_STOPS && InpVerbose)
         Print("[SCP] trail modify refused ", rc, " ",
               g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| THE CYCLE                                                         |
//+------------------------------------------------------------------+
void Cycle()
{
   ulong tk; long id; int dir; double lot, entry, sl; datetime opened; int count;
   bool found = FindOurPosition(tk, id, dir, lot, entry, opened, sl, count);

   //--- TWO positions. Both stop orders can fill inside one spike before the
   //    OCO cancel lands. Every fill carries its own stop, so neither is naked;
   //    the EA tracks one, leaves the other to its stop, and arms nothing new
   //    until the book is a single position again.
   if(count > 1)
   {
      if(TimeCurrent() - g_lastTwoAlert >= 300)
      {
         g_lastTwoAlert = TimeCurrent();
         Print("[SCP] ", count, " positions of ours are open - both straddle "
               "legs filled. Each has its own stop; no new straddle until one "
               "side is gone.");
         Alert("Bot4Algo Scalping: ", count, " positions open");
      }
      DeletePendings("two positions");
   }

   if(g_havePos && !found) { OnPositionGone(); return; }

   if(g_havePos && found && tk != g_posTicket)
   {
      //--- the one we tracked is gone and another of ours is on the book
      if(!PositionSelectByTicket(g_posTicket)) { OnPositionGone(); return; }
   }

   if(!g_havePos && found)
   {
      //--- a leg filled. Kill the other one FIRST: an EA holding a position
      //    with the opposite stop order still live is one spike away from
      //    being hedged into a pair it never meant to open.
      DeletePendings("filled - OCO");
      g_buyStop = 0; g_sellStop = 0;
      AdoptPosition(tk, id, dir, lot, entry, opened, sl, "FILLED");
      LogRow("open", dir, lot, entry, 0);
      ObjectDelete(0, g_pfx + "bs");
      ObjectDelete(0, g_pfx + "ss");
      UpdatePanel();
      return;
   }

   if(g_havePos)
   {
      //--- belt and braces: no pending may coexist with a position
      ulong t2[]; int y2[];
      if(OurPendings(t2, y2) > 0) DeletePendings("position open");
      AttachStop();
      Trail();
      return;
    }

   //--- flat. Re-arm as soon as the book is clean.
   if(count > 0) return;                       // the two-position case above
   ulong t3[]; int y3[];
   int pend = OurPendings(t3, y3);
   if(pend == 0)      PlaceStraddle();
   else if(pend == 1)
   {
      //--- one leg vanished on its own (expired, or deleted by hand). A lone
      //    stop order is a coin flip the strategy never asked for.
      Print("[SCP] only one leg left on the book - clearing and re-arming");
      DeletePendings("lone leg");
   }
}

//+------------------------------------------------------------------+
//| CSV                                                               |
//+------------------------------------------------------------------+
void EnsureLogHeader()
{
   if(!InpLogTrades || FileIsExist(g_tradeFile)) return;
   int h = FileOpen(g_tradeFile, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) { Print("[SCP] LOG HEADER FAILED err=", GetLastError()); return; }
   FileWrite(h, "time", "event", "dir", "lot", "price", "profit", "peak_pts",
                "day_trades", "day_profit", "equity");
   FileClose(h);
}

void LogRow(string ev, int dir, double lot, double price, double profit)
{
   if(!InpLogTrades) return;
   int h = FileOpen(g_tradeFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
   { Print("[SCP] LOG ROW LOST err=", GetLastError(), " (file open in Excel?)"); return; }
   FileSeek(h, 0, SEEK_END);

   double peakPts = 0;
   if(g_peak > 0 && price > 0)
      peakPts = (dir > 0 ? g_peak - price : price - g_peak) / g_point;

   FileWrite(h,
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
      ev, (dir > 0 ? "BUY" : "SELL"), DoubleToString(lot, 2),
      DoubleToString(price, g_digits), DoubleToString(profit, 2),
      DoubleToString(peakPts, 0), IntegerToString(g_dayTrades),
      DoubleToString(g_dayProfit, 2),
      DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   FileClose(h);
}

//+------------------------------------------------------------------+
//| DRAWING                                                           |
//+------------------------------------------------------------------+
void HLine(string name, double price, color clr, ENUM_LINE_STYLE style, string txt)
{
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectMove(0, name, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetString (0, name, OBJPROP_TEXT, txt);
}

void DrawStraddle(double buyPx, double sellPx)
{
   HLine(g_pfx + "bs", buyPx,  clrLime,   STYLE_DOT, "buy stop");
   HLine(g_pfx + "ss", sellPx, clrTomato, STYLE_DOT, "sell stop");
   ChartRedraw();
}

void DrawSL(double sl)
{
   HLine(g_pfx + "sl", sl, clrGold, STYLE_DASH, "trailing stop");
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| PANEL                                                             |
//+------------------------------------------------------------------+
void PanelRow(int idx, string text, color clr)
{
   string name = g_ppfx + IntegerToString(idx);
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, name, OBJPROP_FONT, "Consolas");
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 14);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 24 + idx * (InpPanelFont + 6));
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpPanelFont);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString (0, name, OBJPROP_TEXT, text);
}

string Row(string l, string v)
{
   string s = l;
   while(StringLen(s) < 10) s += " ";
   return s + v;
}

void UpdatePanel()
{
   if(!InpShowPanel) return;

   string bg = g_ppfx + "BG";
   if(ObjectFind(0, bg) < 0)
   {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 8);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'18,18,26');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_COLOR, clrDimGray);
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, InpPanelFont * 30);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, 8 * (InpPanelFont + 6) + 14);

   int r = 0;
   PanelRow(r++, "Bot4Algo SCALP  " + g_symbol + "  v" + EA_VER, clrWhite);
   PanelRow(r++, Row("straddle", "+/-" + IntegerToString(InpDistance) + " pts"), clrSilver);
   PanelRow(r++, Row("stop", IntegerToString(InpStopLoss) + " pts    trail " +
                     IntegerToString(InpTrailStart) + " -> " +
                     IntegerToString(InpTrailStop)), clrSilver);

   if(g_havePos)
   {
      PanelRow(r++, Row("pos", (g_posDir > 0 ? "BUY " : "SELL ") +
                        DoubleToString(g_posLot, 2) + " @ " +
                        DoubleToString(g_posEntry, g_digits)),
               g_posDir > 0 ? clrLime : clrTomato);

      double sl = 0;
      if(PositionSelectByTicket(g_posTicket)) sl = PositionGetDouble(POSITION_SL);
      double lockPts = (sl > 0)
                       ? (g_posDir > 0 ? sl - g_posEntry : g_posEntry - sl) / g_point
                       : 0;
      PanelRow(r++, Row("stop now", (sl > 0 ? DoubleToString(sl, g_digits) +
                        StringFormat("  (%+.0f pts)", lockPts) : "NONE")),
               (lockPts > 0) ? clrAqua : clrOrange);

      double pk = (g_posDir > 0 ? g_peak - g_posEntry : g_posEntry - g_peak) / g_point;
      PanelRow(r++, Row("peak", StringFormat("%+.0f pts   %s", pk,
                        g_trailOn ? "TRAILING" : "waiting " +
                        IntegerToString(InpTrailStart))),
               g_trailOn ? clrAqua : clrSilver);
   }
   else
   {
      ulong t[]; int y[];
      int pend = OurPendings(t, y);
      PanelRow(r++, Row("pos", pend == 2 ? "flat - straddle armed"
                                         : "flat - arming"),
               pend == 2 ? clrSilver : clrOrange);
      PanelRow(r++, "", clrWhite);
      PanelRow(r++, "", clrWhite);
   }

   PanelRow(r++, Row("today", IntegerToString(g_dayTrades) + " trades   " +
                     StringFormat("%+.2f", g_dayProfit)),
            g_dayProfit >= 0 ? clrLime : clrTomato);
   PanelRow(r++, Row("last", g_lastAction), clrSilver);
   PanelRow(r++, g_licOK ? "" : "LICENCE EXPIRED - exits only", clrRed);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| INIT / DEINIT / TICK                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = _Symbol;
   g_digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   g_point  = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(g_point <= 0) { Print("[SCP] symbol point is 0"); return INIT_FAILED; }
   g_eps    = g_point * 0.5;

   g_dist       = InpDistance   * g_point;
   g_sl         = InpStopLoss   * g_point;
   g_trailStart = InpTrailStart * g_point;
   g_trailStop  = InpTrailStop  * g_point;
   g_trailStep  = InpTrailStep  * g_point;

   //--- Wrong account: refuse to load, unless one of our positions is already
   //    open. The trailing stop is this system's only exit, so an EA that
   //    walks away from a live position leaves it with nothing managing it.
   if(!ValidateLicence())
   {
      ulong lt; long lid; int ld; double ll, le, lsl; datetime lo; int lc;
      if(!FindOurPosition(lt, lid, ld, ll, le, lo, lsl, lc)) return INIT_FAILED;
      g_licOK = false;
      Print("[SCP] unlicensed account, but one of our positions is open - "
            "loading in WIND-DOWN mode: the trail still runs, nothing new opens");
      Alert("Bot4Algo Scalping: unlicensed account, winding down.");
   }

   if(InpLot <= 0)
   { Print("[SCP] InpLot must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpDistance <= 0 || InpStopLoss <= 0)
   { Print("[SCP] InpDistance and InpStopLoss must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailStop >= InpTrailStart)
   {
      //--- the stop's first landing is InpTrailStart - InpTrailStop. If that is
      //    zero or negative the "trail" locks in a loss and the whole point of
      //    the rule is gone.
      Print("[SCP] InpTrailStop (", InpTrailStop, ") must be SMALLER than "
            "InpTrailStart (", InpTrailStart, ") - otherwise the first trail "
            "step locks in a loss instead of a profit");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- THE FOUR NUMBERS MOVE TOGETHER. InpDistance is not just a frequency
   //    knob: it selects WHICH MOVES get traded. A wider straddle only fills
   //    on a bigger break, and a bigger break pulls back further, so a stop
   //    left at its old size is now inside the ordinary noise of the move it
   //    just bought - it gets hit on the retrace that a smaller break would
   //    never have produced. Widen the distance and the exit has to widen with
   //    it, in the same proportion the live settings were built on:
   //         SL = 1.00 x D      TrailStart = 0.50 x D      TrailStop = 0.20 x D
   //    Warned, not enforced - a deliberate ratio is the user's to choose.
   double rSL = (double)InpStopLoss   / (double)InpDistance;
   double rTS = (double)InpTrailStart / (double)InpDistance;
   double rTT = (double)InpTrailStop  / (double)InpDistance;
   Print("[SCP] ratios to the straddle distance:  SL ",
         DoubleToString(rSL, 2), "x   trailStart ", DoubleToString(rTS, 2),
         "x   trailStop ", DoubleToString(rTT, 2),
         "x      (reference build: 1.00 / 0.50 / 0.20)");
   if(rSL < 0.5)
      Print("[SCP] WARNING: the stop is only ", DoubleToString(rSL, 2),
            "x the straddle distance. A ", InpDistance,
            "-point break normally retraces further than ", InpStopLoss,
            " points, so this stop will be hit by ordinary pullback. "
            "Suggested for this distance:  SL ", (int)(InpDistance * 1.0),
            "   TrailStart ", (int)(InpDistance * 0.5),
            "   TrailStop ", (int)(InpDistance * 0.2));

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(g_symbol);

   g_tradeFile = "SCP_Trades_" + g_symbol + ".csv";
   EnsureLogHeader();

   //--- adopt anything already ours
   ulong tk; long id; int dir; double lot, entry, sl; datetime opened; int count;
   if(FindOurPosition(tk, id, dir, lot, entry, opened, sl, count))
      AdoptPosition(tk, id, dir, lot, entry, opened, sl, "adopted at start");

   //--- pendings from a previous run are at stale prices; the next tick places
   //    a fresh pair measured from the market as it is now
   DeletePendings("startup");

   g_dayStart = 0;

   Print("[SCP] BUILD v", EA_VER, "  magic ", InpMagic, "  ", g_symbol,
         "  digits ", g_digits);
   Print("[SCP] straddle +/-", InpDistance, " pts (",
         DoubleToString(g_dist, g_digits), ")   lot ", DoubleToString(InpLot, 2),
         " FIXED");
   Print("[SCP] stop ", InpStopLoss, " pts (", DoubleToString(g_sl, g_digits),
         ")   trail starts at ", InpTrailStart, " pts, follows ", InpTrailStop,
         " pts behind the peak  ->  first lock +",
         (InpTrailStart - InpTrailStop), " pts");
   Print("[SCP] NO take profit. The trailing stop is the only exit.");
   UpdatePanel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   //--- A timeframe switch, an input change and a recompile all re-init on the
   //    SAME chart. Wiping the drawings there loses them until the next event
   //    redraws. Written as an EXCLUSION list: a whitelist misses
   //    REASON_INITFAILED and leaves a live-looking panel on a dead chart.
   if(reason != REASON_CHARTCHANGE && reason != REASON_PARAMETERS &&
      reason != REASON_RECOMPILE)
   {
      ObjectsDeleteAll(0, g_pfx);
      ObjectsDeleteAll(0, g_ppfx);
   }
   ChartRedraw();
}

void OnTick()
{
   //--- day counters
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);
   if(today != g_dayStart)
   {
      g_dayStart  = today;
      g_dayTrades = 0;
      g_dayProfit = 0;
      RecheckLicence();
   }

   Cycle();

   static datetime lastPanel = 0;
   if(TimeCurrent() != lastPanel) { lastPanel = TimeCurrent(); UpdatePanel(); }
}
//+------------------------------------------------------------------+
