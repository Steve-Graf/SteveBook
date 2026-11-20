#!/usr/bin/env python3
"""Print today's and upcoming NBA games as a SteveBook import block (SPEC section 7).

    python3 tools/nba_lines.py              # next 3 days
    python3 tools/nba_lines.py --days 1     # just today (US Eastern date used by ESPN)
    python3 tools/nba_lines.py --date 20261125

Paste the output into the bookie window's Import tab, press Preview, then Import.

Source: ESPN's public scoreboard feed (unofficial, no key). Lines are what it carries from its
odds provider, usually only for games within about a day of tip-off, so run this close to game
time. Only games that have not started are printed. Standard library only.
"""
import argparse, json, sys, urllib.request
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

EASTERN = ZoneInfo("America/New_York")   # the bookie's time zone; handles daylight saving

URL = "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates={}"
SPORT = "NBA"


def fetch(day):
    req = urllib.request.Request(URL.format(day), headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def odds(x):
    """'-114' -> '-114'; '+167' stays; 'EVEN' -> '+100'; None if missing."""
    if not x:
        return None
    x = str(x).strip().upper()
    if x in ("EVEN", "EV", "PK"):
        return "+100"
    return x if x[:1] in "+-" else "+" + x


def num(line):
    """'o222.5' / 'u222.5' / '+5.5' -> '222.5' / '5.5' without a leading plus."""
    s = str(line).strip().lstrip("ou")
    return s[1:] if s.startswith("+") else s


def close(side):
    return ((side or {}).get("close")) or {}


def game_lines(ev):
    comp = ev["competitions"][0]
    if comp["status"]["type"]["name"] != "STATUS_SCHEDULED":
        return []                                     # started or finished: not bettable
    teams = {c["homeAway"]: c["team"]["abbreviation"] for c in comp["competitors"]}
    away, home = teams["away"], teams["home"]
    name = f"{away} @ {home}"
    utc = datetime.strptime(ev["date"], "%Y-%m-%dT%H:%MZ").replace(tzinfo=timezone.utc)
    when = utc.astimezone(EASTERN).strftime("%Y-%m-%dT%H:%M%z")
    when = when[:-2] + ":" + when[-2:]                # -0500 -> -05:00
    o = (comp.get("odds") or [None])[0]
    if not o:
        return [f"# {name} {when}: no lines yet"]
    out, ok = [], False
    ml = o.get("moneyline") or {}
    a, h = odds(close(ml.get("away")).get("odds")), odds(close(ml.get("home")).get("odds"))
    if a and h:
        out.append(f"ML|{SPORT}|{name}|{when}|{away}:{a}|{home}:{h}")
    sp = o.get("pointSpread") or {}
    ac, hc = close(sp.get("away")), close(sp.get("home"))
    if ac.get("line") and odds(ac.get("odds")) and odds(hc.get("odds")):
        # the line applies to the first side listed (away); the other side is its opposite
        out.append(f"SPREAD|{SPORT}|{name}|{when}|{ac['line'].lstrip('+')}|{away}:{odds(ac['odds'])}|{home}:{odds(hc['odds'])}")
    tt = o.get("total") or {}
    oc, uc = close(tt.get("over")), close(tt.get("under"))
    if oc.get("line") and odds(oc.get("odds")) and odds(uc.get("odds")):
        out.append(f"TOTAL|{SPORT}|{name}|{when}|{num(oc['line'])}|Over:{odds(oc['odds'])}|Under:{odds(uc['odds'])}")
    return out or [f"# {name} {when}: no usable lines"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=3, help="how many days to fetch, starting today (default 3)")
    ap.add_argument("--date", help="one specific day, YYYYMMDD")
    args = ap.parse_args()
    if args.date:
        days = [args.date]
    else:
        # ESPN buckets games by US Eastern date; UTC-5 is close enough for picking days.
        start = datetime.now(timezone.utc) - timedelta(hours=5)
        days = [(start + timedelta(days=i)).strftime("%Y%m%d") for i in range(args.days)]
    seen, lines = set(), []
    for d in days:
        try:
            data = fetch(d)
        except Exception as e:
            print(f"# could not fetch {d}: {e}", file=sys.stderr)
            continue
        for ev in data.get("events", []):
            if ev["id"] in seen:
                continue
            seen.add(ev["id"])
            lines += game_lines(ev)
    print(f"# NBA lines from ESPN, fetched {datetime.now(EASTERN):%Y-%m-%d %I:%M %p} Eastern")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
