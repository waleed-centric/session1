# PRD — MS Trading London & New York Session EA (MT5)

**Product:** `MS_LondonNY_SessionEA.mq5`  
**Source:** MS Trading — *High Accuracy Strategy | London and New York Session Strategy Explained* (YouTube `oljg7vh22u4`, ~40:39)  
**Instrument (locked):** XAUUSD  
**Chart TF (locked):** M5 (video: “aapko bhi wahi use karna hai”)  
**Bias (locked):** Manual (`None` / `Buy` / `Sell`) — bias method is from his other videos  
**Existing EA:** Do **not** modify `GoldLondonSessionEA.mq5` (different video/model)

**Audit:** Re-checked full transcript (299 segments) on 23 Nov 2026 — see §9 Video Audit.

---

## 1. Goal

Rule-based MT5 EA for the MS Trading London + New York **liquidity-sweep** model on Gold: detect setups, draw on chart, later execute.

**Phase 1 (now):** Strategy detection + visuals only — **no order placement**.  
**Phase 2 (later):** Order send / SL / TP / BE — only when requested.  

**Build status:** EA `v1.10` compiled (Phase 2 trades ON). Path: `MQL5\Experts\MSTradingSession\MS_LondonNY_SessionEA.ex5`  
Defaults: `InpEnableTrade=true`, lot `0.01`, max 2 trades/day, BE at `1:2`, safe SL on.

---

## 2. Strategy Rules (from video)

### 2.1 Four sessions

| Session | Role |
|---------|------|
| Asia | Builds H/L liquidity for London |
| London | Killzone — **entries allowed** |
| New York | Killzone — **entries allowed** |
| London Close | **No new entries** (may hold an open NY trade) |

**Rule 2:** Enter **only inside** London or New York.  
Never enter:

- Asia ↔ London gap  
- London ↔ NY gap  
- London Close  
- Any “nice” FVG/OB between sessions (video: traps)

**Timezone note:** Exact clock times are **not spoken** in the video (TradingView session indicator). EA uses editable GMT-5 defaults (ICT-style); user must align boxes to their chart.

### 2.2 Rule 1 — Bias (hard gate)

- Bias must be clear **before** looking for sweeps.
- **Buy bias:** only **session low** sweeps count (not highs).
- **Sell bias:** only **session high** sweeps count (not lows).
- Wrong-side sweep (e.g. bias up + Asia/London **high** swept with displacement + OB) → **AVOID** even if 1:3 would hit. Wait next session for correct-side sweep.

### 2.3 Hard filters (easy to miss)

| # | Rule | Video emphasis |
|---|------|----------------|
| A | **No sweep → no trade** | Even inside session, POI without prior aligned liquidity sweep = avoid (“advanced entry” deferred) |
| B | **No direct entry on sweep** | After sweep wait **MSS**, then last POI tap |
| C | **POI tap must be inside London/NY** | First FVGs tapped before session open = trap |
| D | **Pre-session sweep is valid** | Sweep may happen **just before** London/NY open; entry still only **inside** the session |
| E | **MSS in London Close → no entry** | Structure shift only in London Close does not authorize a trade |
| F | **M5 only for this model** | Do not drop to lower TF for Phase 1 logic |

### 2.4 Entry sequence

1. Manual bias set (Buy/Sell).  
2. Bias-aligned **liquidity sweep** of prior session H/L  
   - **London** setup: sweep **Asia** H or L (may print just before London open)  
   - **NY fresh** setup: sweep **London** H or L (may print just before NY open)  
   - **NY continuation** (scenario 1): if London already made an aligned sweep + MSS + last POI, NY may **retest that same POI** with **no new London sweep**  
3. **MSS on M5** after the sweep leg  
   - Locked: break the **most recent (last) swing**, not the first swing of the leg  
   - Bullish: after lows, close breaks that last swing high  
   - Bearish: after highs, close breaks that last swing low  
4. Mark **last POI** on the displacement leg after MSS:  
   - **FVG + Order Block** (video: “last FVG plus order block”)  
   - Also **Breakaway Gap + OB** when that is the last POI  
5. **SetupReady** only when price **taps that last POI inside** London or NY.  
6. If no tap in session → no trade that session (patience / skip day is normal).

### 2.5 Scenarios

| Scenario | Behavior | Setup location |
|----------|----------|----------------|
| 1 — Asia ranges | London sweeps Asia (bias-aligned) → MSS → last POI | London entry; **NY continuation = retest of that same POI, no new sweep** |
| 2 — Asia already expanded | London often ranges / traps retailers | Prefer **NY** sweeping London range (bias-aligned) → MSS → POI |
| 3 — Expansion day | Runs all sessions, may not take session liquidity | **Out of scope** (other video) |
| 4 — Wrong-side sweep | Bias up but high swept (or inverse) | Avoid; wait next session correct sweep (often NY) |

### 2.6 Risk / targets (Phase 2 — document now)

**Stop loss**

- Default: beyond the POI (under bullish POI / above bearish POI).  
- **Safe SL:** beyond the swing extreme of the sweep leg (video: “safe SL”).

**Take profit (first target)**

- Longs: **highest session high of the day so far** among Asia / London / NY (whichever printed the extreme).  
- Shorts: **lowest session low of the day so far**.  
- Optional extension: HTF POI if bias is “clear” — not required for first target.

**Trade management (video)**

- If price reaches about **1:2 RR**, move SL to **entry** (“entry SL” / break-even). Do this even if aiming for larger TP.  
- Missing BE can turn a winner into a full SL (example in video ~10 pip SL then later +100 pip NY trade).

---

## 3. Phase 1 Scope

### In scope

- Session boxes: Asia, London, New York (+ H/L lines)  
- Manual bias  
- Sweep detection including **pre-killzone** sweep for that day’s prior session  
- MSS on M5  
- Last FVG+OB (and breakaway gap+OB when detected as last)  
- State machine + chart markers + Comment/Journal  
- Preview SL/TP lines when SetupReady (visual only)

### Out of scope (Phase 1)

- `OrderSend` / positions / BE automation  
- Auto bias / HTF bias engine  
- Asia-session entry model (separate video)  
- Expansion-candle model (separate video)  
- “Advanced” session entries without liquidity sweep  
- Multi-symbol  
- Modifying `GoldLondonSessionEA`

---

## 4. State machine

```
Idle → Swept → MSS_Confirmed → WaitingPOI → SetupReady → (Invalidated | Consumed)
```

| State | Meaning |
|-------|---------|
| Idle | Bias None, or waiting for aligned sweep |
| Swept | Aligned prior-session H/L swept (in or just before killzone) |
| MSS_Confirmed | M5 MSS after sweep (not only in London Close) |
| WaitingPOI | Last FVG+OB defined; waiting for tap **inside** London/NY |
| SetupReady | POI tapped inside killzone — visual only |
| Invalidated | Bias cleared, wrong-side path, MSS only in London Close, session ended without tap |

---

## 5. Inputs (Phase 1)

| Input | Default | Notes |
|-------|---------|-------|
| InpBias | None | None / Buy / Sell |
| InpAsiaStartHour | 20 | GMT-5 — **adjust to match chart** |
| InpAsiaEndHour | 0 | wraps midnight |
| InpLondonStartHour | 2 | GMT-5 — adjust |
| InpLondonEndHour | 5 | |
| InpNYStartHour | 7 | GMT-5 — adjust |
| InpNYEndHour | 10 | |
| InpServerGmtOffset | 2 | XM often GMT+2; 999=auto |
| InpPreSweepMinutes | 60 | allow sweep detection this many minutes before killzone |
| InpSwingStrength | 2 | |
| InpMinFvgPoints | 50 | |
| InpDrawSessions | true | |
| InpDrawPOI | true | |
| InpShowStatus | true | |

Phase 2 placeholders (inactive): lot, magic, max trades/day, `InpEnableTrade=false`, BE at 1:2.

---

## 6. Acceptance criteria (Phase 1)

- [ ] Asia / London / NY boxes align after offset tweak  
- [ ] Bias None → never SetupReady  
- [ ] Wrong-side sweep never → SetupReady  
- [ ] Sweep without MSS → never SetupReady  
- [ ] MSS + POI without aligned sweep → never SetupReady  
- [ ] POI tap outside London/NY → never SetupReady  
- [ ] Pre-London / pre-NY aligned sweep can arm state; entry still only in session  
- [ ] MSS only in London Close → no SetupReady  
- [ ] No orders placed  
- [ ] `GoldLondonSessionEA` untouched  

---

## 7. Build location

- Workspace: `C:\Users\CentricTech\OneDrive\Desktop\session\PRD.md`  
- EA: `...\MQL5\Experts\MSTradingSession\MS_LondonNY_SessionEA.mq5`  
- Transcript extract (audit): `session\video_transcript_audit.txt`

---

## 8. Later phases

**Phase 2 — Execution:** entry on SetupReady; SL (POI / safe swing); TP = session extreme; BE at ~1:2; magic; max trades/day.  
**Phase 3 — Validation:** Strategy Tester on XAUUSD M5; verify avoid rules and pre-session sweep cases.

---

## 9. Video Audit (re-watch checklist)

### Covered correctly in PRD (OK)

- Rule 1 bias + correct-side sweep only  
- Rule 2 session-only entries + London Close no new trades  
- Scenarios: Asia range / Asia expansion→NY / wrong-side avoid / expansion day out of scope  
- Sequence: Sweep → MSS → last FVG+OB → tap in session  
- No direct entry on sweep  
- M5 + Gold examples  
- TP = most extreme session high/low of day  
- Safe SL vs tight POI SL  
- Patience / no-trade days  

### Gaps found on re-audit (fixed in this PRD revision)

1. **Pre-session sweep** — video repeatedly shows Asia swept **before** London open and London swept **before** NY open. Old PRD/EA wording implied sweep only *inside* killzone → **miss**. Added §2.3-D + `InpPreSweepMinutes`.  
2. **Hard “no sweep = no trade”** even with POI in session — called out as “advanced entry” to avoid for now → §2.3-A.  
3. **Breakaway Gap + OB** as valid last POI (not only classic FVG) → §2.4.  
4. **MSS completing only in London Close** → no trade → §2.3-E.  
5. **1:2 → move SL to entry** stated clearly as Phase 2 management rule → §2.6.  
6. **Session clock times not in video** — documented as user-aligned inputs, not video-hardcoded → §2.1.  

### Intentionally still out of scope

- Asia session trading model  
- Expansion candle trading  
- Advanced non-sweep session entries  
- Auto bias from HTF  

### Decision lock (23 Nov 2026)

1. **NY continuation = ON** (video scenario 1). If London already has aligned sweep + MSS + last POI, NY may tap that POI again without a new London sweep. A fresh bias-aligned London sweep during NY still starts a **new** NY model and replaces continuation.  
2. **MSS = last swing** (most recent swing), not the first swing of the leg.
