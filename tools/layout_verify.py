#!/usr/bin/env python3
"""Offline visual verification: mirrors the Monkey C layout math of both fields
using per-device font metrics dumped from the simulator, over every native
slot size, both states, and both clock formats. Flags out-of-bounds drawing,
label/value overlap, and baseline misalignment of the unit/AM-PM."""
import json, glob, os, sys

METRICS = os.environ.get("METRICS_DIR", "metrics")
DEVDIR = os.path.expanduser("~/Library/Application Support/Garmin/ConnectIQ/Devices")

CELL_PAD, ICON_ZONE_W, ICON_SIZE, SPLIT_ICON = 2, 30, 18, 22

def load_metrics(dev):
    fonts, sw, sh = {}, None, None
    for line in open(f"{METRICS}/{dev}.txt"):
        p = line.strip().split("|")
        if p[0] == "DEV": sw, sh = int(p[1]), int(p[2])
        elif p[0] == "FONT": fonts[p[1]] = {"fh": int(p[2]), "asc": int(p[3]), "desc": int(p[4]), "w": {}}
        elif p[0] == "STR": fonts[p[1]]["w"][p[2]] = int(p[3])
    return fonts, sw, sh

def slots(dev):
    d = json.load(open(f"{DEVDIR}/{dev}/simulator.json"))
    out = set()
    for g in d["layouts"][0]["datafields"]["datafields"]:
        for f in g["fields"]:
            out.add((f["location"]["width"], f["location"]["height"]))
    return sorted(out)

def pick(fonts, ladder, s, maxw, maxh):
    best, bестsz = None, -1
    smallest = min(ladder, key=lambda n: fonts[n]["w"]["0"])
    for n in ladder:
        f = fonts[n]
        if f["w"]["0"] > bестsz and f["fh"] <= maxh and f["w"][s] <= maxw:
            best, bестsz = n, f["w"]["0"]
    return best if best else smallest

def lbl_frac(hf): return 0.29 if hf <= 0.45 else (0.35 if hf <= 0.70 else 0.42)
def val_frac(hf):
    for lim, v in [(0.28,0.87),(0.37,0.845),(0.45,0.78),(0.70,0.744)]:
        if hf <= lim: return v
    return 0.62

VAL_LADDER = [f"VAL{i}" for i in range(11)]
ROW_LADDER = [f"VAL{i}" for i in range(3, 11)]

issues = []
def flag(dev, view, slot, fmt, msg):
    issues.append(f"{dev} {slot[0]}x{slot[1]} {view} [{fmt}]: {msg}")

def check_single(dev, fonts, sw, sh, w, h, valstr, sufstr, fmt, label):
    F = fonts
    lblB = int(h * lbl_frac(h / sh)); valB = int(h * val_frac(h / sh))
    lf = "XTINY" if F["LABEL"]["w"][label] > w - 2 * CELL_PAD else "LABEL"
    if F[lf]["asc"] + 1 > lblB:
        if F["XTINY"]["asc"] + 1 <= lblB:
            lf = "XTINY"
        else:
            lblB = F[lf]["asc"] + 1
    sufw = F["LABEL"]["w"][sufstr] if sufstr else 0
    maxvh = min(valB - lblB, h * 50 // 100, sh * 185 // 1000)
    vf = pick(F, VAL_LADDER, valstr, w - 2 * (w * 7 // 100) - sufw, maxvh)
    fh, asc = F[vf]["fh"], F[vf]["asc"]
    valw = F[vf]["w"][valstr]
    groupx = (w - valw - sufw) // 2
    bandtop = lblB + F[lf]["desc"]
    valtop = bandtop + (h - 2 - bandtop - fh) // 2
    baseline = valtop + asc
    suftop = baseline - F["LABEL"]["asc"]
    lbltop = lblB - F[lf]["asc"]
    # checks
    if lbltop < 0: flag(dev, "single", (w,h), fmt, f"label top {lbltop} above field")
    if valtop < bandtop - 1: flag(dev, "single", (w,h), fmt, f"value overlaps label band (valtop {valtop} < bandtop {bandtop})")
    if valtop + fh > h + 1: flag(dev, "single", (w,h), fmt, f"value bottom {valtop+fh} beyond h={h}")
    if groupx < 0: flag(dev, "single", (w,h), fmt, f"value+suffix wider than field (groupx {groupx})")
    if sufstr and suftop + F["LABEL"]["fh"] > h + 2: flag(dev, "single", (w,h), fmt, f"suffix bottom {suftop+F['LABEL']['fh']} beyond h={h}")
    if sufstr:
        sufbase = suftop + F["LABEL"]["asc"]
        if abs(sufbase - baseline) > 1: flag(dev, "single", (w,h), fmt, f"suffix baseline off by {sufbase-baseline}")

def drawvalue_suffix_misalign(F, vf, sufF="UNIT"):
    """fixed drawValue(): sufY = y + asc(font) - asc(unitFont) -> baseline aligned."""
    suf_top = F[vf]["asc"] - F[sufF]["asc"]
    suf_base = suf_top + F[sufF]["asc"]
    return suf_base - F[vf]["asc"]

def check_rows(dev, fonts, w, h, s1, s2, suf1, suf2, fmt):
    F = fonts
    midy = h // 2
    sufw = max(F["UNIT"]["w"].get(suf1, 0) if suf1 else 0, F["UNIT"]["w"].get(suf2, 0) if suf2 else 0)
    probe = s1 if F["VAL5"]["w"][s1] > F["VAL5"]["w"][s2] else s2
    rf = pick(F, ROW_LADDER, probe, w - 2 * CELL_PAD - ICON_ZONE_W - sufw, midy - 2)
    fh = F[rf]["fh"]
    topy = (midy - fh) // 2
    boty = midy + (h - midy - fh) // 2
    if topy < 0: flag(dev, "rows", (w,h), fmt, f"row value top {topy} above field (font {rf} fh={fh})")
    if boty + fh > h + 1: flag(dev, "rows", (w,h), fmt, f"bottom row exceeds field")
    # width: icon zone + value + suffix must fit
    vw = max(F[rf]["w"][s1], F[rf]["w"][s2])
    if CELL_PAD + ICON_ZONE_W + vw + sufw > w - CELL_PAD + 1:
        flag(dev, "rows", (w,h), fmt, f"row content overflows width (font {rf})")
    d = drawvalue_suffix_misalign(F, rf)
    if abs(d) > 2 and (suf1 or suf2):
        flag(dev, "rows", (w,h), fmt, f"suffix baseline off by {d}px (font {rf}, box-aligned)")

def check_split(dev, fonts, w, h, s1, s2, suf1, suf2, fmt):
    F = fonts
    halfw = w // 2
    icon = SPLIT_ICON if SPLIT_ICON <= h - 8 else h - 8
    zone = icon + 4 if icon >= 8 else 0
    sufw = max(F["UNIT"]["w"].get(suf1, 0) if suf1 else 0, F["UNIT"]["w"].get(suf2, 0) if suf2 else 0)
    probe = s1 if F["VAL5"]["w"][s1] > F["VAL5"]["w"][s2] else s2
    cf = pick(F, ROW_LADDER, probe, halfw - 2 * CELL_PAD - zone - sufw, h - 4)
    fh = F[cf]["fh"]
    valy = (h - fh) // 2
    if valy < -1: flag(dev, "split", (w,h), fmt, f"cell value taller than field (font {cf})")
    vw = max(F[cf]["w"][s1], F[cf]["w"][s2])
    if CELL_PAD + zone + vw + sufw > halfw - CELL_PAD + 1:
        flag(dev, "split", (w,h), fmt, f"cell content overflows half width (font {cf})")
    d = drawvalue_suffix_misalign(F, cf)
    if abs(d) > 2 and (suf1 or suf2):
        flag(dev, "split", (w,h), fmt, f"suffix baseline off by {d}px (font {cf}, box-aligned)")

devices = sorted(os.path.basename(f)[:-4] for f in glob.glob(f"{METRICS}/*.txt"))
for dev in devices:
    fonts, sw, sh = load_metrics(dev)
    for (w, h) in slots(dev):
        full = w >= sw
        # ---- TIME FIELD ----
        for fmt, tstr, per in [("24h", "23:59", ""), ("12h", "12:59", "PM"), ("12h-1dig", "9:55", "AM")]:
            check_single(dev, fonts, sw, sh, w, h, tstr, per, "time-" + fmt, "TIME OF DAY")
            if full: check_split(dev, fonts, w, h, tstr, "12:59" if fmt != "24h" else "23:59", per, per, "time-" + fmt)
            else:    check_rows(dev, fonts, w, h, tstr, "12:59" if fmt != "24h" else "23:59", per, per, "time-" + fmt)
        # ---- DISTANCE FIELD ----
        for fmt, dstr in [("dist", "27.3"), ("dist-big", "888.8"), ("dist-0", "0.0")]:
            check_single(dev, fonts, sw, sh, w, h, dstr, "km", fmt, "DISTANCE")
            if full: check_split(dev, fonts, w, h, dstr, "34.2", "km", "km", fmt)
            else:    check_rows(dev, fonts, w, h, dstr, "34.2", "km", "km", fmt)

seen = set()
for i in issues:
    if i not in seen:
        seen.add(i)
        print(i)
print(f"\n{len(seen)} unique issues across {len(devices)} devices")
