//+------------------------------------------------------------------+
//|                                  MS_LondonNY_SessionEA.mq5       |
//|  MS Trading London + NY liquidity-sweep (Phase 2: live trades)   |
//+------------------------------------------------------------------+
#property copyright "CentricTech"
#property version   "1.14"
#property description "MS Trading LN/NY — entry inside POI only + session TP"

#include <Trade/Trade.mqh>

enum ENUM_MANUAL_BIAS
{
   BIAS_BUY  = 0,  // Buy   (0 = default; sticky tester inputs with 0 still trade)
   BIAS_SELL = 1,  // Sell
   BIAS_NONE = 2   // None  — strategy waits
};

enum ENUM_SETUP_STATE
{
   ST_IDLE = 0,
   ST_SWEPT,
   ST_MSS,
   ST_WAIT_POI,
   ST_READY,
   ST_INVALID
};

enum ENUM_KILLZONE
{
   KZ_NONE = 0,
   KZ_LONDON,
   KZ_NY
};

input group "=== Bias (locked manual) ==="
input ENUM_MANUAL_BIAS InpBias = BIAS_BUY;

input group "=== Sessions (GMT-5 / NY) ==="
input int InpAsiaStartHour   = 20;
input int InpAsiaEndHour     = 0;
input int InpLondonStartHour = 2;
input int InpLondonEndHour   = 5;
input int InpNYStartHour     = 7;
input int InpNYEndHour       = 10;
input int InpServerGmtOffset = 2;    // hours; 999 = auto
input int InpPreSweepMinutes = 60;   // sweep allowed before killzone open

input group "=== Structure ==="
input int    InpSwingStrength = 2;
input int    InpScanBars      = 120;
input double InpMinFvgPoints  = 20;   // gold points (_Point units)
input double InpFallbackRR    = 0.0;  // IGNORED — session TP only (kept for old .set compat)

input group "=== Visual ==="
input bool  InpDrawSessions = true;
input bool  InpDrawPOI      = true;
input bool  InpShowStatus   = true;
input color InpAsiaColor    = C'90,20,20';
input color InpLondonColor  = C'90,70,20';
input color InpNYColor      = C'20,40,90';

input group "=== Trade (Phase 2) ==="
input bool   InpEnableTrade   = true;
input double InpLot           = 0.1;
input int    InpMagic         = 261123;
input int    InpSlippage      = 30;
input int    InpMaxTradesDay  = 2;
input bool   InpUseSafeSL     = true;   // beyond sweep extreme when available
input int    InpSLBufferPts   = 50;     // points beyond POI/sweep
input double InpBE_RR         = 2.0;    // move SL to entry at this R
input bool   InpOnePosition   = true;   // max 1 open EA position

CTrade trade;
datetime g_lastBar = 0;
int      g_dayKey  = -1;
int      g_tradesToday = 0;
bool     g_beDone = false;
bool     g_setupTraded = false; // block re-entry on same setup
ulong    g_lastTicket = 0;

double g_asiaH=0, g_asiaL=0, g_lonH=0, g_lonL=0, g_nyH=0, g_nyL=0;
bool   g_asiaReady=false, g_lonReady=false, g_nyReady=false;

ENUM_SETUP_STATE g_state = ST_IDLE;
ENUM_KILLZONE    g_kz    = KZ_NONE;
bool     g_sweepHigh = false;
double   g_sweepLevel=0, g_sweepExt=0, g_mssLevel=0;
datetime g_sweepTime=0, g_mssTime=0, g_poiTime=0;
double   g_poiTop=0, g_poiBot=0;
bool     g_poiBull=false;
bool     g_contMode=false;
bool     g_lonPoiValid=false;
double   g_lonPoiTop=0, g_lonPoiBot=0;
datetime g_lonPoiTime=0;

string PREFIX = "MSLN_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   string biasName = (InpBias==BIAS_BUY?"BUY":(InpBias==BIAS_SELL?"SELL":"NONE"));
   double nlot = NormalizeLot(InpLot);
   PrintFormat("MS_LondonNY_SessionEA v1.14 | bias=%s trade=%s lot=%.2f (norm=%.2f min=%.2f step=%.2f) entry=insidePOI sessionTP=strict",
               biasName, (InpEnableTrade?"ON":"OFF"), InpLot, nlot,
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
   if(InpBias == BIAS_NONE)
      Print("WARNING: Bias=None — strategy idle until Buy/Sell is set");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PREFIX);
   Comment("");
}

void OnTick()
{
   datetime t = iTime(_Symbol, PERIOD_M5, 0);
   if(t == 0) return;

   bool newBar = (t != g_lastBar);
   if(newBar) g_lastBar = t;

   datetime ny = NowNY();
   int day = DayKeyNY(ny);
   if(day != g_dayKey)
   {
      ResetDay();
      g_dayKey = day;
      g_tradesToday = 0;
   }

   UpdateSessionRanges(ny);
   if(InpDrawSessions) DrawSessions();

   ManageBreakEven(); // every tick

   if(InpBias == BIAS_NONE)
   {
      g_state = ST_IDLE;
      UpdateStatus("Bias=None — waiting");
      return;
   }

   if(newBar)
   {
      ENUM_KILLZONE kzEntry = CurrentKillzone(ny);
      ENUM_KILLZONE kzLogic = ActiveOrUpcomingKillzone(ny);
      ProcessStrategy(ny, kzLogic, kzEntry);

      // Killzone closed without fill → skip session (video patience)
      if((g_state == ST_WAIT_POI || g_state == ST_READY || g_state == ST_SWEPT || g_state == ST_MSS) &&
         CurrentKillzone(ny) == KZ_NONE &&
         !InSweepWindowFor(g_kz, ny) &&
         g_kz != KZ_NONE)
      {
         PrintFormat("Session skip %s — no live POI tap/fill",
                     (g_kz==KZ_LONDON?"London":"NY"));
         // Keep London POI for possible NY continuation; clear active setup
         if(g_kz == KZ_LONDON && g_lonPoiValid) { /* keep stored POI */ }
         g_state = ST_IDLE;
         g_contMode = false;
      }
   }

   // Video: mark READY only on live tap inside London/NY (every tick)
   if(g_state == ST_WAIT_POI)
   {
      ENUM_KILLZONE kzNow = CurrentKillzone(ny);
      if(kzNow != KZ_NONE && kzNow == g_kz)
         TryMarkReady(kzNow);
   }

   // Leave READY if price left inside-POI or session ended before fill
   if(g_state == ST_READY)
   {
      ENUM_KILLZONE kzNow = CurrentKillzone(ny);
      if(kzNow != g_kz || !EntryPriceInsidePOI(g_poiBull))
         g_state = ST_WAIT_POI;
      else
         TryOpenTrade();
   }

   DrawSetupObjects();
   UpdateStatus(StateText());
}

//+------------------------------------------------------------------+
int ServerGmtOffsetSec()
{
   if(InpServerGmtOffset != 999)
      return InpServerGmtOffset * 3600;
   return (int)(TimeTradeServer() - TimeGMT());
}

datetime ServerToNY(datetime serverTime)
{
   return serverTime - ServerGmtOffsetSec() - 5*3600;
}

datetime NowNY() { return ServerToNY(TimeTradeServer()); }

int NYHour(datetime ny)   { MqlDateTime d; TimeToStruct(ny,d); return d.hour; }
int NYMinute(datetime ny) { MqlDateTime d; TimeToStruct(ny,d); return d.min; }
int NYMins(datetime ny)   { return NYHour(ny)*60 + NYMinute(ny); }

int DayKeyNY(datetime ny)
{
   MqlDateTime d; TimeToStruct(ny,d);
   return d.year*10000 + d.mon*100 + d.day;
}

bool InHourRange(datetime ny, int startH, int endH)
{
   int mins = NYMins(ny);
   int a = startH*60, b = endH*60;
   if(a < b) return (mins >= a && mins < b);
   return (mins >= a || mins < b);
}

ENUM_KILLZONE CurrentKillzone(datetime ny)
{
   if(InHourRange(ny, InpLondonStartHour, InpLondonEndHour)) return KZ_LONDON;
   if(InHourRange(ny, InpNYStartHour, InpNYEndHour))         return KZ_NY;
   return KZ_NONE;
}

bool IsLondonClose(datetime ny)
{
   int mins = NYMins(ny);
   int nyEnd = InpNYEndHour*60;
   int asiaStart = InpAsiaStartHour*60;
   if(asiaStart > nyEnd)
      return (mins >= nyEnd && mins < asiaStart);
   return (mins >= nyEnd);
}

bool InSweepWindowFor(ENUM_KILLZONE kz, datetime ny)
{
   int m = NYMins(ny);
   int pre = MathMax(0, InpPreSweepMinutes);
   int startH = (kz==KZ_LONDON ? InpLondonStartHour : InpNYStartHour);
   int endH   = (kz==KZ_LONDON ? InpLondonEndHour   : InpNYEndHour);
   if(kz!=KZ_LONDON && kz!=KZ_NY) return false;
   int start = startH*60 - pre;
   int end   = endH*60;
   if(start < 0) start += 24*60;
   if(start < end) return (m >= start && m < end);
   return (m >= start || m < end);
}

ENUM_KILLZONE ActiveOrUpcomingKillzone(datetime ny)
{
   ENUM_KILLZONE cur = CurrentKillzone(ny);
   if(cur != KZ_NONE) return cur;
   if(InSweepWindowFor(KZ_LONDON, ny)) return KZ_LONDON;
   if(InSweepWindowFor(KZ_NY, ny)) return KZ_NY;
   return KZ_NONE;
}

void ResetDay()
{
   g_asiaH=g_asiaL=g_lonH=g_lonL=g_nyH=g_nyL=0;
   g_asiaReady=g_lonReady=g_nyReady=false;
   g_state = ST_IDLE;
   g_kz = KZ_NONE;
   g_sweepLevel=g_sweepExt=g_mssLevel=0;
   g_poiTop=g_poiBot=0;
   g_sweepTime=g_mssTime=g_poiTime=0;
   g_contMode=false;
   g_lonPoiValid=false;
   g_lonPoiTop=g_lonPoiBot=0;
   g_lonPoiTime=0;
   g_setupTraded=false;
   g_beDone=false;
   ObjectsDeleteAll(0, PREFIX + "SIG_");
}

//+------------------------------------------------------------------+
void UpdateSessionRanges(datetime nyNow)
{
   int bars = Bars(_Symbol, PERIOD_M5);
   if(bars < 50) return;

   double asiaH=-DBL_MAX, asiaL=DBL_MAX;
   double lonH=-DBL_MAX,  lonL=DBL_MAX;
   double nyH=-DBL_MAX,   nyL=DBL_MAX;
   bool aOk=false, lOk=false, nOk=false;
   int today = DayKeyNY(nyNow);

   for(int i=0; i<MathMin(bars, 500); i++)
   {
      datetime st = iTime(_Symbol, PERIOD_M5, i);
      if(st==0) break;
      datetime ny = ServerToNY(st);
      int dk = DayKeyNY(ny);
      int h = NYHour(ny);
      double hi=iHigh(_Symbol,PERIOD_M5,i), lo=iLow(_Symbol,PERIOD_M5,i);

      if(InHourRange(ny, InpAsiaStartHour, InpAsiaEndHour))
      {
         int asiaDay = dk;
         if(InpAsiaStartHour > InpAsiaEndHour && h >= InpAsiaStartHour)
            asiaDay = DayKeyNY(ny + 24*3600);
         if(asiaDay == today)
         {
            if(hi>asiaH) asiaH=hi;
            if(lo<asiaL) asiaL=lo;
            aOk=true;
         }
      }
      if(dk == today && InHourRange(ny, InpLondonStartHour, InpLondonEndHour))
      {
         if(hi>lonH) lonH=hi;
         if(lo<lonL) lonL=lo;
         lOk=true;
      }
      if(dk == today && InHourRange(ny, InpNYStartHour, InpNYEndHour))
      {
         if(hi>nyH) nyH=hi;
         if(lo<nyL) nyL=lo;
         nOk=true;
      }
   }

   if(aOk){ g_asiaH=asiaH; g_asiaL=asiaL; g_asiaReady=true; }
   if(lOk){ g_lonH=lonH;   g_lonL=lonL;   g_lonReady=true; }
   if(nOk){ g_nyH=nyH;     g_nyL=nyL;     g_nyReady=true; }
}

//+------------------------------------------------------------------+
void ProcessStrategy(datetime ny, ENUM_KILLZONE kzLogic, ENUM_KILLZONE kzEntry)
{
   if(kzLogic == KZ_NONE)
      return;

   bool wantHigh = (InpBias == BIAS_SELL);
   bool wantLow  = (InpBias == BIAS_BUY);

   double priorH=0, priorL=0;
   bool priorOk=false;
   if(kzLogic == KZ_LONDON && g_asiaReady)
   { priorH=g_asiaH; priorL=g_asiaL; priorOk=true; }
   else if(kzLogic == KZ_NY && g_lonReady)
   { priorH=g_lonH; priorL=g_lonL; priorOk=true; }

   // --- NY continuation first (scenario 1): retest London POI, no new sweep required ---
   if(kzLogic == KZ_NY && g_lonPoiValid && priorOk)
   {
      bool alreadyNyReady = (g_state == ST_READY && g_kz == KZ_NY);
      if(!alreadyNyReady)
      {
         // Fresh NY London-sweep model preferred when available; else continuation
         bool freshSweep = DetectAlignedSweep(ny, kzLogic, priorH, priorL, wantHigh, wantLow, false);
         if(!freshSweep && (g_state == ST_IDLE || g_kz == KZ_LONDON || g_contMode ||
                            g_state == ST_WAIT_POI || g_state == ST_READY || g_state == ST_INVALID))
         {
            ArmContinuation(wantLow);
         }
      }
   }

   if(!priorOk) return;
   if(g_state == ST_READY && g_kz == kzLogic) return;

   // --- Fresh sweep model (latch: do NOT re-arm every bar) ---
   bool alreadyInModel = (!g_contMode && g_kz == kzLogic &&
                          (g_state == ST_SWEPT || g_state == ST_MSS ||
                           g_state == ST_WAIT_POI || g_state == ST_READY));

   double prevExt = g_sweepExt;
   bool swept = DetectAlignedSweep(ny, kzLogic, priorH, priorL, wantHigh, wantLow, true);
   if(swept)
   {
      bool deeper = (wantLow  && g_sweepExt < prevExt - _Point) ||
                    (wantHigh && g_sweepExt > prevExt + _Point) ||
                    (prevExt <= 0);
      // First arm, or deeper sweep on same kz → restart. Same sweep while in model → keep state.
      if(!alreadyInModel || deeper)
      {
         g_state = ST_SWEPT;
         g_kz = kzLogic;
         g_sweepHigh = wantHigh;
         g_sweepLevel = wantHigh ? priorH : priorL;
         g_contMode = false;
         g_setupTraded = false;
         g_poiTop=g_poiBot=0;
         g_mssLevel=0;
         g_mssTime=0;
         PrintFormat("Sweep armed %s level=%.2f ext=%.2f",
                     (kzLogic==KZ_LONDON?"London":"NY"), g_sweepLevel, g_sweepExt);
      }
   }

   if(g_state != ST_SWEPT && g_state != ST_MSS && g_state != ST_WAIT_POI)
      return;

   if(!g_contMode && (g_state == ST_SWEPT || g_state == ST_MSS || g_state == ST_WAIT_POI))
   {
      if(DetectMSS(wantLow))
      {
         datetime mssNy = ServerToNY(g_mssTime);
         if(IsLondonClose(mssNy) && CurrentKillzone(mssNy) == KZ_NONE)
         {
            g_state = ST_INVALID;
            Print("Setup invalid: MSS only in London Close");
            return;
         }
         if(g_state == ST_SWEPT)
         {
            g_state = ST_MSS;
            PrintFormat("MSS confirmed level=%.2f", g_mssLevel);
         }
         if(g_state != ST_WAIT_POI && BuildLastPOI(wantLow))
         {
            g_state = ST_WAIT_POI;
            if(kzLogic == KZ_LONDON)
               StoreLondonPoi();
            PrintFormat("POI built %.2f-%.2f", g_poiBot, g_poiTop);
         }
      }
   }

   // POI tap only inside real London/NY window
   if(g_state == ST_WAIT_POI && kzEntry == kzLogic && kzEntry != KZ_NONE)
      TryMarkReady(kzEntry);
}

bool DetectAlignedSweep(datetime ny, ENUM_KILLZONE kz, double priorH, double priorL,
                        bool wantHigh, bool wantLow, bool writeGlobals)
{
   bool swept=false;
   double ext=0;
   datetime stime=0;
   int lim = (int)MathMin(InpScanBars, Bars(_Symbol,PERIOD_M5)-2);

   for(int i=1; i<lim; i++)
   {
      datetime st = iTime(_Symbol, PERIOD_M5, i);
      datetime n = ServerToNY(st);
      if(DayKeyNY(n) != DayKeyNY(ny)) break;
      if(!InSweepWindowFor(kz, n)) continue;

      double hi=iHigh(_Symbol,PERIOD_M5,i);
      double lo=iLow(_Symbol,PERIOD_M5,i);

      if(wantLow && lo < priorL)
      {
         swept=true; ext=lo; stime=st;
         for(int j=i; j>=1; j--)
         {
            datetime nj = ServerToNY(iTime(_Symbol,PERIOD_M5,j));
            if(!InSweepWindowFor(kz, nj)) break;
            double lj=iLow(_Symbol,PERIOD_M5,j);
            if(lj < ext){ ext=lj; stime=iTime(_Symbol,PERIOD_M5,j); }
         }
         break;
      }
      if(wantHigh && hi > priorH)
      {
         swept=true; ext=hi; stime=st;
         for(int j=i; j>=1; j--)
         {
            datetime nj = ServerToNY(iTime(_Symbol,PERIOD_M5,j));
            if(!InSweepWindowFor(kz, nj)) break;
            double hj=iHigh(_Symbol,PERIOD_M5,j);
            if(hj > ext){ ext=hj; stime=iTime(_Symbol,PERIOD_M5,j); }
         }
         break;
      }
   }

   if(swept && writeGlobals)
   {
      g_sweepExt = ext;
      g_sweepTime = stime;
   }
   return swept;
}

void ArmContinuation(bool wantLow)
{
   if(g_setupTraded && g_kz == KZ_NY && g_contMode) return;
   g_poiTop = g_lonPoiTop;
   g_poiBot = g_lonPoiBot;
   g_poiTime = g_lonPoiTime;
   g_poiBull = wantLow;
   g_state = ST_WAIT_POI;
   g_kz = KZ_NY;
   g_contMode = true;
   g_setupTraded = false;
}

void StoreLondonPoi()
{
   if(g_poiTop<=0 || g_poiBot<=0) return;
   g_lonPoiTop = g_poiTop;
   g_lonPoiBot = g_poiBot;
   g_lonPoiTime = g_poiTime;
   g_lonPoiValid = true;
}

bool PriceTouchingPOI()
{
   if(g_poiTop <= 0 || g_poiBot <= 0) return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // Bid/ask range overlaps POI band
   return !(ask < g_poiBot || bid > g_poiTop);
}

// Do not chase: executable price must sit inside the POI box
bool EntryPriceInsidePOI(bool isBuy)
{
   if(g_poiTop <= 0 || g_poiBot <= 0) return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(isBuy)
      return (ask >= g_poiBot && ask <= g_poiTop);
   return (bid >= g_poiBot && bid <= g_poiTop);
}

void TryMarkReady(ENUM_KILLZONE kzEntry)
{
   if(g_setupTraded) return;
   if(g_state == ST_READY && g_kz == kzEntry) return;
   if(g_poiTop <= 0 || g_poiBot <= 0) return;

   // Video: must be inside killzone NOW
   if(CurrentKillzone(NowNY()) != kzEntry) return;

   // Live tap only — current + just-closed M5 bar (no full-session history)
   bool barTap = false;
   for(int i=0; i<=1; i++)
   {
      datetime st = iTime(_Symbol, PERIOD_M5, i);
      if(st == 0) continue;
      datetime n = ServerToNY(st);
      if(CurrentKillzone(n) != kzEntry) continue;
      double hi=iHigh(_Symbol,PERIOD_M5,i);
      double lo=iLow(_Symbol,PERIOD_M5,i);
      if(hi >= g_poiBot && lo <= g_poiTop)
      {
         barTap = true;
         break;
      }
   }
   if(!barTap) return;
   if(!EntryPriceInsidePOI(g_poiBull)) return;

   // Session TP must still be valid at tap (video first target)
   double sl=0, tp=0;
   if(!ComputeSLTP(g_poiBull, sl, tp))
      return;

   g_state = ST_READY;
   g_kz = kzEntry;
   g_beDone = false;
   PrintFormat("SetupReady LIVE %s kz=%s cont=%d POI=%.2f-%.2f ask=%.2f bid=%.2f",
               _Symbol, (kzEntry==KZ_LONDON?"London":"NY"),
               (int)g_contMode, g_poiBot, g_poiTop,
               SymbolInfoDouble(_Symbol, SYMBOL_ASK),
               SymbolInfoDouble(_Symbol, SYMBOL_BID));
}

//+------------------------------------------------------------------+
// Phase 2 — execution
//+------------------------------------------------------------------+
bool ComputeSLTP(bool isBuy, double &sl, double &tp)
{
   double buf = InpSLBufferPts * _Point;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(isBuy)
   {
      sl = g_poiBot - buf;
      if(InpUseSafeSL && g_sweepExt > 0 && !g_contMode)
         sl = MathMin(sl, g_sweepExt - buf);
      if(sl >= ask) return false;

      tp = SessionTargetHigh();
      // Video: first target = session extreme only (no RR fallback)
      if(tp <= ask) return false;
   }
   else
   {
      sl = g_poiTop + buf;
      if(InpUseSafeSL && g_sweepExt > 0 && !g_contMode)
         sl = MathMax(sl, g_sweepExt + buf);
      if(sl <= bid) return false;

      tp = SessionTargetLow();
      if(tp <= 0 || tp >= bid) return false;
   }
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   return true;
}

int CountEAPositions()
{
   int n = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
   }
   return n;
}

double NormalizeLot(double lot)
{
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0) vstep = 0.01;
   if(vmin <= 0) vmin = vstep;
   if(vmax <= 0) vmax = 100.0;
   lot = MathMax(vmin, MathMin(vmax, lot));
   lot = MathFloor(lot / vstep + 1e-8) * vstep;
   int digs = 0;
   double s = vstep;
   while(digs < 8 && MathAbs(s - MathRound(s)) > 1e-8) { s *= 10.0; digs++; }
   return NormalizeDouble(lot, digs);
}

bool TryOpenTrade()
{
   if(!InpEnableTrade) return false;
   if(g_state != ST_READY) return false;
   if(g_poiTop <= 0 || g_poiBot <= 0) return false;
   if(g_tradesToday >= InpMaxTradesDay) return false;
   if(InpOnePosition && CountEAPositions() > 0) return false;

   bool isBuy = g_poiBull; // bias buy → bullish POI → buy
   if(InpBias == BIAS_BUY && !isBuy) return false;
   if(InpBias == BIAS_SELL && isBuy) return false;

   double lot = NormalizeLot(InpLot);
   if(lot < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) - 1e-8)
   {
      PrintFormat("Skip: lot invalid req=%.2f norm=%.2f min=%.2f step=%.2f",
                  InpLot, lot,
                  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
      return false;
   }

   double sl=0, tp=0;
   // Video: only enter while inside killzone AND executable price inside POI
   if(CurrentKillzone(NowNY()) != g_kz || !EntryPriceInsidePOI(isBuy))
   {
      g_state = ST_WAIT_POI;
      return false;
   }

   if(!ComputeSLTP(isBuy, sl, tp))
   {
      PrintFormat("Skip: session TP/SL invalid at live tap (ask=%.2f poi=%.2f-%.2f)",
                  SymbolInfoDouble(_Symbol,SYMBOL_ASK), g_poiBot, g_poiTop);
      g_state = ST_WAIT_POI;
      return false;
   }

   // min stop level
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = stops * _Point;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(isBuy)
   {
      if(ask - sl < minDist) sl = NormalizeDouble(ask - minDist - _Point, digits);
      if(tp - ask < minDist) { Print("Skip: TP too close"); g_state=ST_WAIT_POI; return false; }
   }
   else
   {
      if(sl - bid < minDist) sl = NormalizeDouble(bid + minDist + _Point, digits);
      if(bid - tp < minDist) { Print("Skip: TP too close"); g_state=ST_WAIT_POI; return false; }
   }

   string cmt = StringFormat("MSLN %s%s", (g_kz==KZ_LONDON?"LON":"NY"), (g_contMode?" CONT":""));
   bool ok = false;
   if(isBuy)
      ok = trade.Buy(lot, _Symbol, 0, sl, tp, cmt);
   else
      ok = trade.Sell(lot, _Symbol, 0, sl, tp, cmt);

   if(ok)
   {
      g_tradesToday++;
      g_beDone = false;
      g_setupTraded = true;
      g_lastTicket = trade.ResultOrder();
      g_state = ST_IDLE;
      PrintFormat("Opened %s SL=%.2f TP=%.2f tradesToday=%d",
                  (isBuy?"BUY":"SELL"), sl, tp, g_tradesToday);
      return true;
   }
   uint rc = trade.ResultRetcode();
   PrintFormat("Order failed retcode=%d %s lot=%.2f", rc, trade.ResultRetcodeDescription(), lot);
   // permanent rejects — stop tick spam
   if(rc == 10014 || rc == 10016 || rc == 10019 || rc == 10030)
   {
      g_setupTraded = true;
      g_state = ST_IDLE;
   }
   return false;
}

void ManageBreakEven()
{
   if(!InpEnableTrade || InpBE_RR <= 0) return;
   if(g_beDone) return;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      long type   = PositionGetInteger(POSITION_TYPE);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double risk = MathAbs(open - sl);
      if(risk <= 0) continue;
      double targetMove = risk * InpBE_RR;

      bool hit = false;
      if(type == POSITION_TYPE_BUY)
         hit = (bid >= open + targetMove);
      else
         hit = (ask <= open - targetMove);

      if(!hit) continue;

      double newSL = open;
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      newSL = NormalizeDouble(newSL, digits);
      // only tighten
      if(type == POSITION_TYPE_BUY && sl >= newSL - _Point) { g_beDone=true; continue; }
      if(type == POSITION_TYPE_SELL && (sl<=0 || sl <= newSL + _Point)) { g_beDone=true; continue; }

      if(trade.PositionModify(ticket, newSL, tp))
      {
         g_beDone = true;
         PrintFormat("BE applied ticket=%d SL→%.2f (%.1fR)", ticket, newSL, InpBE_RR);
      }
   }
}

//+------------------------------------------------------------------+
bool DetectMSS(bool bullish)
{
   int strength = MathMax(1, InpSwingStrength);
   int bars = Bars(_Symbol, PERIOD_M5);
   if(bars < 30) return false;

   if(g_mssLevel > 0 && g_mssTime > 0 && g_state >= ST_MSS)
      return true;

   int sweepShift = iBarShift(_Symbol, PERIOD_M5, g_sweepTime, false);
   if(sweepShift < 0) sweepShift = 15;
   int maxSh = (int)MathMin(bars - strength - 1, sweepShift + 30);

   int swingSh = -1;
   double swingPx = 0.0;
   for(int i = strength; i <= maxSh; i++)
   {
      if(bullish && IsSwingHigh(i, strength))
      { swingSh=i; swingPx=iHigh(_Symbol,PERIOD_M5,i); break; }
      if(!bullish && IsSwingLow(i, strength))
      { swingSh=i; swingPx=iLow(_Symbol,PERIOD_M5,i); break; }
   }
   if(swingSh < 0) return false;

   for(int i=1; i<swingSh; i++)
   {
      double c = iClose(_Symbol, PERIOD_M5, i);
      if(bullish && c > swingPx)
      { g_mssLevel=swingPx; g_mssTime=iTime(_Symbol,PERIOD_M5,i); return true; }
      if(!bullish && c < swingPx)
      { g_mssLevel=swingPx; g_mssTime=iTime(_Symbol,PERIOD_M5,i); return true; }
   }
   return false;
}

bool IsSwingHigh(int shift, int strength)
{
   double h = iHigh(_Symbol, PERIOD_M5, shift);
   for(int k=1; k<=strength; k++)
   {
      if(iHigh(_Symbol,PERIOD_M5,shift+k) >= h) return false;
      if(iHigh(_Symbol,PERIOD_M5,shift-k) >  h) return false;
   }
   return true;
}

bool IsSwingLow(int shift, int strength)
{
   double l = iLow(_Symbol, PERIOD_M5, shift);
   for(int k=1; k<=strength; k++)
   {
      if(iLow(_Symbol,PERIOD_M5,shift+k) <= l) return false;
      if(iLow(_Symbol,PERIOD_M5,shift-k) <  l) return false;
   }
   return true;
}

// Last FVG (+ OB body merge) between sweep and present; also covers breakaway-style gaps
bool BuildLastPOI(bool bullish)
{
   int mssSh = iBarShift(_Symbol, PERIOD_M5, g_mssTime, false);
   int swSh  = iBarShift(_Symbol, PERIOD_M5, g_sweepTime, false);
   if(mssSh < 0) mssSh = 1;
   if(swSh < 0) swSh = mssSh + 15;

   int from = MathMax(swSh, mssSh + 5);
   int to = 1;
   double minGap = InpMinFvgPoints * _Point;

   double bestTop=0, bestBot=0;
   datetime bestT=0;
   bool found=false;

   for(int i=to+2; i<=from; i++)
   {
      double high2 = iHigh(_Symbol, PERIOD_M5, i+2);
      double low2  = iLow(_Symbol, PERIOD_M5, i+2);
      double high0 = iHigh(_Symbol, PERIOD_M5, i);
      double low0  = iLow(_Symbol, PERIOD_M5, i);
      double obTop = MathMax(iOpen(_Symbol,PERIOD_M5,i+1), iClose(_Symbol,PERIOD_M5,i+1));
      double obBot = MathMin(iOpen(_Symbol,PERIOD_M5,i+1), iClose(_Symbol,PERIOD_M5,i+1));

      if(bullish && low0 > high2 && (low0-high2) >= minGap)
      {
         bestBot = MathMin(high2, obBot);
         bestTop = MathMax(low0, obTop);
         if(bestBot > bestTop){ bestBot=high2; bestTop=low0; }
         bestT = iTime(_Symbol, PERIOD_M5, i+1);
         found = true;
      }
      if(!bullish && high0 < low2 && (low2-high0) >= minGap)
      {
         bestBot = MathMin(high0, obBot);
         bestTop = MathMax(low2, obTop);
         if(bestBot > bestTop){ bestBot=high0; bestTop=low2; }
         bestT = iTime(_Symbol, PERIOD_M5, i+1);
         found = true;
      }
   }

   if(!found) return false;
   g_poiTop = bestTop;
   g_poiBot = bestBot;
   g_poiTime = bestT;
   g_poiBull = bullish;
   return true;
}

//+------------------------------------------------------------------+
void DrawSessions()
{
   datetime ny = NowNY();
   int day = DayKeyNY(ny);
   DrawOneSession("ASIA", day, InpAsiaStartHour, InpAsiaEndHour, g_asiaH, g_asiaL, g_asiaReady, InpAsiaColor);
   DrawOneSession("LON",  day, InpLondonStartHour, InpLondonEndHour, g_lonH, g_lonL, g_lonReady, InpLondonColor);
   DrawOneSession("NY",   day, InpNYStartHour, InpNYEndHour, g_nyH, g_nyL, g_nyReady, InpNYColor);

   if(g_asiaReady)
   {
      HLine(PREFIX+"ASIA_H", g_asiaH, InpAsiaColor);
      HLine(PREFIX+"ASIA_L", g_asiaL, InpAsiaColor);
   }
   if(g_lonReady)
   {
      HLine(PREFIX+"LON_H", g_lonH, InpLondonColor);
      HLine(PREFIX+"LON_L", g_lonL, InpLondonColor);
   }
}

void DrawOneSession(string tag, int dayKey, int startH, int endH, double hi, double lo, bool ready, color clr)
{
   if(!ready || hi<=0 || lo<=0 || hi<lo) return;
   datetime t1 = SessionStartServer(dayKey, startH);
   datetime t2 = SessionEndServer(dayKey, startH, endH);
   string name = PREFIX + "BOX_" + tag;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectMove(0, name, 0, t1, hi);
   ObjectMove(0, name, 1, t2, lo);
}

datetime NYDayStart(int dayKey)
{
   MqlDateTime dt;
   dt.year=dayKey/10000; dt.mon=(dayKey/100)%100; dt.day=dayKey%100;
   dt.hour=0; dt.min=0; dt.sec=0;
   return StructToTime(dt);
}

datetime SessionStartServer(int dayKey, int startH)
{
   datetime nyStart = NYDayStart(dayKey) + startH*3600;
   if(startH >= 18)
      nyStart = NYDayStart(dayKey) - 24*3600 + startH*3600;
   return nyStart + 5*3600 + ServerGmtOffsetSec();
}

datetime SessionEndServer(int dayKey, int startH, int endH)
{
   datetime nyEnd = NYDayStart(dayKey) + endH*3600;
   if(startH >= 18)
      nyEnd = NYDayStart(dayKey) + endH*3600;
   return nyEnd + 5*3600 + ServerGmtOffsetSec();
}

void HLine(string name, double price, color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
}

void DrawSetupObjects()
{
   ObjectsDeleteAll(0, PREFIX+"SIG_");
   if(g_sweepLevel > 0 && !g_contMode)
   {
      HLine(PREFIX+"SIG_SWEEP", g_sweepLevel, clrOrange);
      if(g_sweepExt > 0)
         HLine(PREFIX+"SIG_EXT", g_sweepExt, clrDarkOrange);
   }
   if(g_mssLevel > 0 && !g_contMode)
      HLine(PREFIX+"SIG_MSS", g_mssLevel, clrDodgerBlue);

   if(InpDrawPOI && g_poiTop > 0 && g_poiBot > 0)
   {
      string name = PREFIX+"SIG_POI";
      datetime t1 = (g_poiTime>0 ? g_poiTime : TimeCurrent());
      datetime t2 = t1 + PeriodSeconds(PERIOD_M5)*16;
      if(ObjectFind(0,name)<0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, g_poiTop, t2, g_poiBot);
      ObjectSetInteger(0, name, OBJPROP_COLOR, g_poiBull ? clrLime : clrRed);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectMove(0, name, 0, t1, g_poiTop);
      ObjectMove(0, name, 1, t2, g_poiBot);
   }

   if(g_state == ST_READY && g_poiTop > 0)
   {
      double entry = (g_poiTop + g_poiBot)*0.5;
      double sl=0, tp=0;
      if(ComputeSLTP(g_poiBull, sl, tp))
      {
         HLine(PREFIX+"SIG_SL", sl, clrRed);
         HLine(PREFIX+"SIG_TP", tp, clrGreen);
         HLine(PREFIX+"SIG_EN", entry, clrWhite);
      }
   }
}

double SessionTargetHigh()
{
   double h = 0;
   if(g_asiaReady) h = MathMax(h, g_asiaH);
   if(g_lonReady)  h = MathMax(h, g_lonH);
   if(g_nyReady)   h = MathMax(h, g_nyH);
   return h;
}

double SessionTargetLow()
{
   double l = DBL_MAX;
   if(g_asiaReady) l = MathMin(l, g_asiaL);
   if(g_lonReady)  l = MathMin(l, g_lonL);
   if(g_nyReady)   l = MathMin(l, g_nyL);
   return (l==DBL_MAX ? 0 : l);
}

string StateText()
{
   string b = (InpBias==BIAS_BUY?"BUY":(InpBias==BIAS_SELL?"SELL":"NONE"));
   string kz = (g_kz==KZ_LONDON?"London":(g_kz==KZ_NY?"NY":"-"));
   string st;
   switch(g_state)
   {
      case ST_IDLE:     st="Idle"; break;
      case ST_SWEPT:    st="Swept"; break;
      case ST_MSS:      st="MSS"; break;
      case ST_WAIT_POI: st=g_contMode?"WaitPOI (NY cont)":"WaitPOI"; break;
      case ST_READY:    st=g_contMode?"READY NY-CONT":"READY"; break;
      case ST_INVALID:  st="Invalid"; break;
      default: st="?";
   }
   return StringFormat("MS LN/NY v1.14 | Bias:%s | KZ:%s | %s | Trade:%s\nAsia %.2f/%.2f | Lon %.2f/%.2f | LonPOI:%s | DayTrades:%d/%d | Open:%d",
                       b, kz, st, (InpEnableTrade?"ON":"OFF"),
                       g_asiaL, g_asiaH, g_lonL, g_lonH,
                       (g_lonPoiValid?"yes":"no"),
                       g_tradesToday, InpMaxTradesDay, CountEAPositions());
}

void UpdateStatus(string s)
{
   if(!InpShowStatus){ Comment(""); return; }
   Comment(s);
}
//+------------------------------------------------------------------+
