import Toybox.Activity;
import Toybox.Application.Properties;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

// Blue used by the device to separate data fields.
const DIVIDER_COLOR = 0x007DC3;

const CELL_PAD    = 2;   // gap at left and right edges
const ICON_ZONE_W = 30;  // width reserved for the icon column
const ICON_SIZE   = 18;  // icon render size in pixels (stacked rows)
// Icon size in the side-by-side layout: full-height cells fit a larger icon
// than the stacked rows, but 22 is the ceiling on 282px-wide screens before
// the icon zone starts costing the value a font-size step.
const SPLIT_ICON_SIZE = 22;

// Minimum speed (m/s) below which an ETA is considered too noisy to show.
const MIN_ETA_SPEED = 0.1f;

// EMA smoothing factor for the recent-pace speed estimate used as an ETA fallback.
// Lower = smoother/slower to react, higher = tracks currentSpeed more closely.
const PACE_EMA_ALPHA = 0.15f;

// Speeds (m/s, ~3.6 km/h) below this aren't riding: a stop, or the first moments
// of pulling away. They are left out of the pace estimate, so a stop freezes it
// instead of dragging it toward 0 (which inflated the ETA, and kept it inflated
// for a while after setting off again).
const MIN_PACE_SAMPLE_SPEED = 1.0f;

// After a stop, adapt faster for a few samples so the pace catches up with the
// speed you actually set off at (a slow climb after a fast stretch, say) instead
// of lagging on the pre-stop pace.
const PACE_EMA_ALPHA_RESUME  = 0.35f;
const PACE_RESUME_SAMPLES    = 8;
const PACE_RESUME_STOP_TICKS = 3;  // consecutive slow ticks that count as a stop

// compute() runs at 1 Hz; re-read device settings only this often to avoid
// allocating a DeviceSettings object every tick. A time-format change is picked
// up within this many seconds (and immediately on layout changes).
const SETTINGS_REFRESH_TICKS = 30;

// SCREENSHOT MODE — forces fixed sample data, regardless of what's actually
// happening on the device. Set SCREENSHOT_SHOW_ROUTE to switch between the two
// display states, since a loaded route can't be emulated in the simulator.
// (:debug)-only: compiled out entirely for release/store builds (-r), so this
// can never accidentally ship — no need to remember to flip it back.
(:debug) const SCREENSHOT_MODE       = true;
(:debug) const SCREENSHOT_SHOW_ROUTE = true;  // true: dual-value (time + ETA) state, false: single-value (time only) state
(:debug) const SCREENSHOT_ETA_SECONDS = 92 * 60;

// Forces the "Remaining Duration" route-mode setting on in the simulator
// without going through the Connect IQ app / settings menu. (:debug)-only,
// same as SCREENSHOT_MODE above — stripped from release builds entirely.
(:debug) const DEBUG_FORCE_DURATION = true;

class DualTimeFieldView extends WatchUi.DataField {

    hidden var _timeStr    as String;
    hidden var _timePeriod as String;
    hidden var _etaStr     as String or Null;
    hidden var _etaPeriod  as String;
    hidden var _etaIsDuration as Boolean;  // _etaStr holds "H:MM" remaining duration, not a time of day
    hidden var _unitFont   as Graphics.FontType;
    hidden var _labelFont  as Graphics.FontType;
    hidden var _paceSpeed  as Float or Null;
    hidden var _stoppedTicks as Number;  // consecutive ticks below MIN_PACE_SAMPLE_SPEED
    hidden var _resumeTicks  as Number;  // fast-adapt samples left after a stop
    hidden var _timeLabel  as String;
    hidden var _durationUnit     as String;
    hidden var _durationUnitFont as Graphics.FontType;
    hidden var _is24Hour     as Boolean;
    hidden var _showDuration as Boolean;  // route-mode setting: remaining duration vs. arrival time (ETA)
    hidden var _settingsTick as Number;
    hidden var _screenH      as Number;
    hidden var _screenW      as Number;
    // Descending font ladders — the largest font that fits the available space
    // is picked at draw time, so small data fields degrade instead of clipping.
    // The width check drops oversized fonts automatically where "23:59" won't fit.
    hidden var _valueFonts as Array<Graphics.FontType>;  // single-value (no course) view
    hidden var _rowFonts   as Array<Graphics.FontType>;  // dual-row (course) view

    function initialize() {
        DataField.initialize();
        _timeStr    = "";
        _timePeriod = "";
        _etaStr     = null;
        _etaPeriod  = "";
        _etaIsDuration = false;
        _unitFont   = Graphics.FONT_TINY;
        // Native header font differs by generation (per the device layout specs):
        // x40-era devices use the Roboto glance font, while the CIQ 3.x era
        // (530/830/1030/820/...) uses the condensed DejaVu FONT_SMALL. Key off an
        // API 4.0 symbol to tell the generations apart.
        _labelFont  = ((Graphics has :createBufferedBitmap) && (Graphics has :FONT_GLANCE))
            ? Graphics.FONT_GLANCE : Graphics.FONT_SMALL;
        _paceSpeed  = null;
        _stoppedTicks = 0;
        _resumeTicks  = 0;
        _timeLabel  = WatchUi.loadResource(Rez.Strings.TimeLabel) as String;
        _durationUnit     = WatchUi.loadResource(Rez.Strings.DurationUnit) as String;
        _durationUnitFont = Graphics.FONT_TINY;
        _is24Hour     = true;
        _showDuration = false;
        _settingsTick = 0;
        _screenH      = 1;
        _screenW      = 10000;
        // Custom Roboto Bold fonts (see resources/fonts) fill the size canyon
        // between NUMBER_MEDIUM (29px digits) and NUMBER_HOT (42px), and extend
        // past it toward the sizes native fields reach via scalable fonts.
        // Ladder order doesn't matter: pickFont() selects the tallest fit, since
        // built-in font sizes vary per device relative to the fixed custom ones.
        var fontBig = WatchUi.loadResource(Rez.Fonts.NumberBig) as Graphics.FontType;
        var fontLrg = WatchUi.loadResource(Rez.Fonts.NumberLrg) as Graphics.FontType;
        var fontXlg = WatchUi.loadResource(Rez.Fonts.NumberXlg) as Graphics.FontType;
        var fontMid = WatchUi.loadResource(Rez.Fonts.NumberMid) as Graphics.FontType;
        _valueFonts = [fontBig, fontLrg, fontXlg, fontMid,
                       Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM,
                       Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM,
                       Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY];
        _rowFonts   = [fontMid,
                       Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM,
                       Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM,
                       Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY];
        refreshSettings();
    }

    hidden function refreshSettings() as Void {
        var settings = System.getDeviceSettings();
        _is24Hour = settings.is24Hour;
        _screenH  = settings.screenHeight;
        _screenW  = settings.screenWidth;
        _showDuration = applyDebugDurationOverride(
            (Properties.getValue("ShowRemainingDuration") as Number) != 0);
    }

    // See DEBUG_FORCE_DURATION above. (:release) sibling below is a no-op.
    (:debug) hidden function applyDebugDurationOverride(v as Boolean) as Boolean {
        return DEBUG_FORCE_DURATION ? true : v;
    }

    (:release) hidden function applyDebugDurationOverride(v as Boolean) as Boolean {
        return v;
    }

    // Native single-value geometry, taken from the device layout specs
    // (simulator.json): label and value are baseline-anchored at fixed
    // fractions of the field height, shifting for taller fields.
    hidden function labelBaseFrac(hFrac as Float) as Float {
        if (hFrac <= 0.45f) { return 0.29f; }
        if (hFrac <= 0.70f) { return 0.35f; }
        return 0.42f;
    }

    hidden function valueBaseFrac(hFrac as Float) as Float {
        if (hFrac <= 0.28f) { return 0.87f;  }
        if (hFrac <= 0.37f) { return 0.845f; }
        if (hFrac <= 0.45f) { return 0.78f;  }
        if (hFrac <= 0.70f) { return 0.744f; }
        return 0.62f;
    }

    // The smoothed pace is meaningless across activities — start fresh.
    function onTimerReset() as Void {
        _paceSpeed    = null;
        _stoppedTicks = 0;
        _resumeTicks  = 0;
    }

    // Called by the app when settings change in Garmin Connect / Express, so the
    // route-mode and clock-format changes show up now rather than at the next
    // periodic refresh.
    function onSettingsChanged() as Void {
        refreshSettings();
        WatchUi.requestUpdate();
    }

    function onLayout(dc as Dc) as Void {
        refreshSettings();
        View.setLayout(Rez.Layouts.MainLayout(dc));
        var lbl = View.findDrawableById("label") as Text;
        var val = View.findDrawableById("value") as Text;
        lbl.locY = lbl.locY - 16;
        val.locY = val.locY + 7;
    }

    // Converts a 24-hour hour value to its 12-hour display form (1-12).
    hidden function to12Hour(h as Number) as Number {
        var h12 = h % 12;
        return h12 == 0 ? 12 : h12;
    }

    hidden function periodOf(h as Number, is24Hour as Boolean) as String {
        return is24Hour ? "" : (h < 12 ? "AM" : "PM");
    }

    // "H:MM" — no leading zero on the hour in either clock mode (period
    // returned separately for 12-hour mode).
    hidden function fmtTime(h as Number, m as Number, is24Hour as Boolean) as String {
        var hh = is24Hour ? h : to12Hour(h);
        return hh.format("%d") + ":" + m.format("%02d");
    }

    // "H:MM" remaining duration (unlike fmtTime, hours count up unbounded
    // rather than wrapping at 12/24 — this is a countdown, not a clock).
    hidden function fmtDuration(totalSeconds as Number) as String {
        var totalMinutes = totalSeconds / 60;
        var hh = totalMinutes / 60;
        var mm = totalMinutes % 60;
        return hh.format("%d") + ":" + mm.format("%02d");
    }

    // Graphics.getFontAscent/Descent arrived with CIQ 3.1; approximate on the
    // 2.4-era Edge 820/Explore firmware variants. Built-in fonts (plain Number
    // constants) put roughly 80% of the box above the baseline; the custom
    // fonts (loaded resources, not Numbers) are tight: baseline ~2px above the
    // box bottom.
    hidden function fontAscent(dc as Dc, f as Graphics.FontType) as Number {
        if (Graphics has :getFontAscent) {
            return Graphics.getFontAscent(f);
        }
        if (!(f instanceof Lang.Number)) {
            return dc.getFontHeight(f) - 2;
        }
        return dc.getFontHeight(f) * 4 / 5;
    }

    hidden function fontDescent(dc as Dc, f as Graphics.FontType) as Number {
        if (Graphics has :getFontDescent) {
            return Graphics.getFontDescent(f);
        }
        if (!(f instanceof Lang.Number)) {
            return 2;
        }
        return dc.getFontHeight(f) / 5;
    }

    // Visually largest font from the ladder whose rendered string fits
    // maxW x maxH; falls back to the ladder's smallest font if nothing fits.
    // Fonts are ranked by digit width, not box height: built-in number fonts
    // carry large internal padding (NUMBER_MEDIUM: 42px box, 29px digits)
    // while the custom fonts are tight, so box height misorders them.
    hidden function pickFont(dc as Dc, str as String, maxW as Number, maxH as Number,
                             ladder as Array<Graphics.FontType>) as Graphics.FontType {
        var best      = null;
        var bestSize  = -1;
        var smallest  = ladder[0];
        var smallSize = dc.getTextWidthInPixels("0", ladder[0]);
        for (var i = 0; i < ladder.size(); i++) {
            var f    = ladder[i];
            var size = dc.getTextWidthInPixels("0", f);
            if (size < smallSize) {
                smallest  = f;
                smallSize = size;
            }
            if (size > bestSize && dc.getFontHeight(f) <= maxH
                    && dc.getTextWidthInPixels(str, f) <= maxW) {
                best     = f;
                bestSize = size;
            }
        }
        return best != null ? best : smallest;
    }

    // Applies a fixed sample ETA when SCREENSHOT_MODE is on; returns whether it did.
    // (:debug)-only — see SCREENSHOT_MODE above. The (:release) sibling below is a
    // no-op, so store builds contain no screenshot logic or sample values at all.
    (:debug) hidden function applyScreenshotMode(is24Hour as Boolean) as Boolean {
        if (!SCREENSHOT_MODE) {
            return false;
        }
        if (!SCREENSHOT_SHOW_ROUTE) {
            _etaStr       = null;
            _etaPeriod    = "";
            _etaIsDuration = false;
            return true;
        }
        if (_showDuration) {
            _etaStr       = fmtDuration(SCREENSHOT_ETA_SECONDS);
            _etaPeriod    = "";
            _etaIsDuration = true;
            return true;
        }
        var etaMoment = Time.now().add(new Time.Duration(SCREENSHOT_ETA_SECONDS));
        var etaInfo = Gregorian.info(etaMoment, Time.FORMAT_SHORT);
        _etaStr    = fmtTime(etaInfo.hour, etaInfo.min, is24Hour);
        _etaPeriod = periodOf(etaInfo.hour, is24Hour);
        _etaIsDuration = false;
        return true;
    }

    (:release) hidden function applyScreenshotMode(is24Hour as Boolean) as Boolean {
        return false;
    }

    function compute(info as Activity.Info) as Void {
        _settingsTick += 1;
        if (_settingsTick >= SETTINGS_REFRESH_TICKS) {
            _settingsTick = 0;
            refreshSettings();
        }
        var is24Hour = _is24Hour;

        var now = System.getClockTime();
        _timeStr    = fmtTime(now.hour, now.min, is24Hour);
        _timePeriod = periodOf(now.hour, is24Hour);

        if (applyScreenshotMode(is24Hour)) {
            return;
        }

        // Track a smoothed "recent pace" from currentSpeed via EMA. This is far less
        // noisy than raw currentSpeed (no ETA swings at every stoplight) and, unlike
        // averageSpeed, doesn't drag the whole ride's history behind it — it reflects
        // how fast you're actually moving right now (e.g. mid-climb). Stops are not
        // sampled (the pace holds), and the first samples after one adapt faster.
        if ((info has :currentSpeed) && info.currentSpeed != null) {
            var cs = info.currentSpeed as Float;
            if (cs < MIN_PACE_SAMPLE_SPEED) {
                _stoppedTicks += 1;
            } else {
                if (_paceSpeed == null) {
                    _paceSpeed = cs;
                } else {
                    if (_stoppedTicks >= PACE_RESUME_STOP_TICKS) {
                        _resumeTicks = PACE_RESUME_SAMPLES;
                    }
                    var alpha = _resumeTicks > 0 ? PACE_EMA_ALPHA_RESUME : PACE_EMA_ALPHA;
                    if (_resumeTicks > 0) {
                        _resumeTicks -= 1;
                    }
                    _paceSpeed = alpha * cs + (1.0f - alpha) * (_paceSpeed as Float);
                }
                _stoppedTicks = 0;
            }
        }

        // distanceToDestination is only meaningful while a course/route is actively
        // loaded. On the simulator (and apparently some devices) it reads 0.0 rather
        // than null when no course is loaded, so null-check alone isn't reliable —
        // require a positive distance as the "course loaded" signal instead.
        var courseLoaded = (info has :distanceToDestination) && info.distanceToDestination != null
            && (info.distanceToDestination as Float) > 0.0f;

        var secondsRemaining = null as Number or Null;

        if ((info has :timeToDestination) && info.timeToDestination != null
                && (info.timeToDestination as Number or Float) > 0) {
            // Garmin's own course-navigation ETA estimate — preferred over computing our own.
            secondsRemaining = (info.timeToDestination as Number or Float).toNumber();
        } else if (courseLoaded) {
            // Prefer the smoothed recent pace; fall back to the ride's cumulative
            // average speed only if we don't have a usable pace estimate yet.
            var paceSpeed = null as Float or Null;
            if (_paceSpeed != null && (_paceSpeed as Float) > MIN_ETA_SPEED) {
                paceSpeed = _paceSpeed as Float;
            } else if ((info has :averageSpeed) && info.averageSpeed != null
                    && (info.averageSpeed as Float) > MIN_ETA_SPEED) {
                paceSpeed = info.averageSpeed as Float;
            }

            if (paceSpeed != null) {
                secondsRemaining = ((info.distanceToDestination as Float) / (paceSpeed as Float)).toNumber();
            }
        }

        if (!courseLoaded) {
            _etaStr        = null;
            _etaPeriod     = "";
            _etaIsDuration = false;
        } else if (secondsRemaining != null) {
            if (_showDuration) {
                _etaStr    = fmtDuration(secondsRemaining as Number);
                _etaPeriod = "";
            } else {
                var etaMoment = Time.now().add(new Time.Duration(secondsRemaining as Number));
                var etaInfo = Gregorian.info(etaMoment, Time.FORMAT_SHORT);
                _etaStr    = fmtTime(etaInfo.hour, etaInfo.min, is24Hour);
                _etaPeriod = periodOf(etaInfo.hour, is24Hour);
            }
            _etaIsDuration = _showDuration;
        } else {
            // Course loaded but no ETA could be determined yet (e.g. no GPS fix).
            // Not a duration, so it draws without the "h" unit.
            _etaStr        = "--:--";
            _etaPeriod     = "";
            _etaIsDuration = false;
        }
    }

    // Clock face (circle outline + hour/minute hands) — current time indicator.
    hidden function drawIconClock(dc as Dc, left as Number, centerY as Number, s as Number) as Void {
        var r  = s / 2;
        var cx = left + r;
        dc.setPenWidth(2);
        dc.drawCircle(cx, centerY, r);
        dc.drawLine(cx, centerY, cx,               centerY - r * 3 / 5);
        dc.drawLine(cx, centerY, cx + r * 2 / 5,    centerY + r / 5);
        dc.setPenWidth(1);
    }

    // Map pin (circle head + teardrop body + punched hole) — arrival indicator.
    hidden function drawIconArrival(dc as Dc, left as Number, centerY as Number,
                                    s as Number, holeColor as Graphics.ColorType) as Void {
        var pinR     = s * 3 / 8;
        var pinCX    = left + pinR;
        var pinHeadY = centerY - s / 10;
        var pinTipY  = centerY + pinR + s / 3;

        dc.fillPolygon([
            [pinCX - pinR * 9 / 10, pinHeadY + pinR / 2],
            [pinCX + pinR * 9 / 10, pinHeadY + pinR / 2],
            [pinCX, pinTipY]
        ]);
        dc.fillCircle(pinCX, pinHeadY, pinR);

        dc.setColor(holeColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(pinCX, pinHeadY, pinR / 3);
    }

    // Draw value in the given font with a unit suffix (AM/PM, or the smaller
    // "h" duration unit) in unitFont, bottom-aligned to the value. x is the
    // right edge of value+unit.
    hidden function drawValue(dc as Dc, x as Number, y as Number, str as String,
                              unit as String, font as Graphics.FontType,
                              unitFont as Graphics.FontType) as Void {
        var unitW = dc.getTextWidthInPixels(unit, unitFont);
        // Align the unit to the value's baseline (digits sit on the baseline;
        // box-based alignment drifts by up to 11px with the tight custom fonts).
        var unitY = y + fontAscent(dc, font) - fontAscent(dc, unitFont);

        dc.drawText(x,        unitY, unitFont, unit, Graphics.TEXT_JUSTIFY_RIGHT);
        dc.drawText(x - unitW, y,    font,     str,  Graphics.TEXT_JUSTIFY_RIGHT);
    }

    // Time-of-day value drawn like drawValue, but reserves extra width for an
    // invisible "h" duration unit so its digit column lines up with the
    // remaining-duration row/cell below or beside it, which draws a visible
    // "h" of its own. Without this, an empty AM/PM period (24h mode) leaves
    // the time's digits sitting further right than the duration's digits.
    hidden function drawTimeAligned(dc as Dc, x as Number, y as Number,
                                    font as Graphics.FontType, fgColor as Graphics.ColorType) as Void {
        var periodW = dc.getTextWidthInPixels(_timePeriod, _unitFont);
        var hiddenW = dc.getTextWidthInPixels(_durationUnit, _durationUnitFont);
        var periodY = y + fontAscent(dc, font) - fontAscent(dc, _unitFont);
        var hiddenY = y + fontAscent(dc, font) - fontAscent(dc, _durationUnitFont);

        dc.setColor(getBackgroundColor(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, hiddenY, _durationUnitFont, _durationUnit, Graphics.TEXT_JUSTIFY_RIGHT);
        dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);

        dc.drawText(x - hiddenW,           periodY, _unitFont, _timePeriod, Graphics.TEXT_JUSTIFY_RIGHT);
        dc.drawText(x - hiddenW - periodW, y,       font,      _timeStr,    Graphics.TEXT_JUSTIFY_RIGHT);
    }

    function onUpdate(dc as Dc) as Void {
        var bgColor = getBackgroundColor();
        var fgColor = bgColor == Graphics.COLOR_BLACK
            ? Graphics.COLOR_WHITE
            : Graphics.COLOR_BLACK;

        (View.findDrawableById("Background") as Background).setColor(bgColor);

        (View.findDrawableById("label") as Text).setText("");
        (View.findDrawableById("value") as Text).setText("");
        View.onUpdate(dc);

        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);

        if (_etaStr == null) {
            // ── No course: native-style field, baseline-anchored per the device
            // layout spec. AM/PM shares the value's baseline, like native. ──
            var hFrac    = h.toFloat() / _screenH;
            var lblBaseY = (h * labelBaseFrac(hFrac)).toNumber();
            var valBaseY = (h * valueBaseFrac(hFrac)).toNumber();
            var lblText  = _timeLabel.toUpper();
            var lblFont  = dc.getTextWidthInPixels(lblText, _labelFont) > w - 2 * CELL_PAD
                ? Graphics.FONT_XTINY : _labelFont;
            // Very short slots (51-60px on some devices): the label must fit above
            // its baseline — step down to XTINY, or failing that push the baseline.
            if (fontAscent(dc, lblFont) + 1 > lblBaseY) {
                if (fontAscent(dc, Graphics.FONT_XTINY) + 1 <= lblBaseY) {
                    lblFont = Graphics.FONT_XTINY;
                } else {
                    lblBaseY = fontAscent(dc, lblFont) + 1;
                }
            }
            var periodW  = dc.getTextWidthInPixels(_timePeriod, _labelFont);
            // Cap the value font at the native size rule (from the device layout
            // specs): ~50% of the slot height, but never more than ~18.5% of the
            // screen height — the largest font native fields ever use.
            var maxValH  = valBaseY - lblBaseY;
            if (h * 50 / 100 < maxValH)         { maxValH = h * 50 / 100; }
            if (_screenH * 185 / 1000 < maxValH) { maxValH = _screenH * 185 / 1000; }
            // Native keeps ~7% side margins around the value; this is what makes
            // wide values step down in size exactly where native shrinks them.
            var valFont  = pickFont(dc, _timeStr, w - 2 * (w * 7 / 100) - periodW, maxValH, _valueFonts);
            var valW     = dc.getTextWidthInPixels(_timeStr, valFont);
            var groupX   = (w - valW - periodW) / 2;

            // Center the value vertically in the band below the label — when the
            // picked font is smaller than native's, a centered value looks right
            // where the native baseline position would leave it bottom-hugging.
            var bandTop  = lblBaseY + fontDescent(dc, lblFont);
            var valTop   = bandTop + (h - 2 - bandTop - dc.getFontHeight(valFont)) / 2;
            var baseline = valTop + fontAscent(dc, valFont);

            dc.drawText(w / 2, lblBaseY - fontAscent(dc, lblFont), lblFont,
                        lblText, Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(groupX, valTop, valFont, _timeStr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(groupX + valW, baseline - fontAscent(dc, _labelFont), _labelFont,
                        _timePeriod, Graphics.TEXT_JUSTIFY_LEFT);

        } else if (w >= _screenW) {
            // ── Course active, full-width field: side-by-side cells split by a
            // vertical divider — current time left, arrival time right. ──
            var halfW   = w / 2;
            var etaStr  = _etaStr as String;
            var timeSuffixW = dc.getTextWidthInPixels(_timePeriod, _unitFont);
            var etaSuffixW;
            if (_etaIsDuration) {
                var hiddenW = dc.getTextWidthInPixels(_durationUnit, _durationUnitFont);
                // In duration mode the time cell also reserves a hidden "h" (see
                // drawTimeAligned) so its digits line up with the duration cell.
                timeSuffixW += hiddenW;
                etaSuffixW = hiddenW;
            } else {
                etaSuffixW = dc.getTextWidthInPixels(_etaPeriod, _unitFont);
            }
            var periodW = timeSuffixW > etaSuffixW ? timeSuffixW : etaSuffixW;

            // Full-height cells fit a larger icon than the stacked rows; hug the
            // icon with a tight zone instead of reserving the fixed 30px column,
            // so the value keeps as much width budget as possible.
            var iconSize = SPLIT_ICON_SIZE <= h - 8 ? SPLIT_ICON_SIZE : h - 8;
            var drawIcons = iconSize >= 8;
            var iconZone  = drawIcons ? iconSize + 4 : 0;

            // One font for both cells so they match; fit against the wider value.
            var probe    = dc.getTextWidthInPixels(_timeStr, Graphics.FONT_NUMBER_MEDIUM)
                         > dc.getTextWidthInPixels(etaStr,   Graphics.FONT_NUMBER_MEDIUM)
                         ? _timeStr : etaStr;
            var cellFont = pickFont(dc, probe, halfW - 2 * CELL_PAD - iconZone - periodW, h - 4, _rowFonts);
            var numH     = dc.getFontHeight(cellFont);
            var valY     = (h - numH) / 2;
            var cy       = h / 2;

            // Left cell: clock icon + current time
            if (drawIcons) {
                drawIconClock(dc, CELL_PAD, cy, iconSize);
            }
            if (_etaIsDuration) {
                drawTimeAligned(dc, halfW - CELL_PAD - 2, valY, cellFont, fgColor);
            } else {
                drawValue(dc, halfW - CELL_PAD - 2, valY, _timeStr, _timePeriod, cellFont, _unitFont);
            }

            // Divider
            dc.setColor(DIVIDER_COLOR, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawLine(halfW, 0, halfW, h);

            // Right cell: pin icon + arrival time (or remaining duration)
            dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
            if (drawIcons) {
                drawIconArrival(dc, halfW + CELL_PAD + iconSize / 8,
                                cy - iconSize / 8, iconSize, bgColor);
                dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
            }
            if (_etaIsDuration) {
                drawValue(dc, w - CELL_PAD, valY, etaStr, _durationUnit, cellFont, _durationUnitFont);
            } else {
                drawValue(dc, w - CELL_PAD, valY, etaStr, _etaPeriod, cellFont, _unitFont);
            }

        } else {
            // ── Course active: dual row with divider ──
            var midY    = h / 2;
            var etaStr  = _etaStr as String;
            var timeSuffixW = dc.getTextWidthInPixels(_timePeriod, _unitFont);
            var etaSuffixW;
            if (_etaIsDuration) {
                var hiddenW = dc.getTextWidthInPixels(_durationUnit, _durationUnitFont);
                // In duration mode the time row also reserves a hidden "h" (see
                // drawTimeAligned) so its digits line up with the duration row.
                timeSuffixW += hiddenW;
                etaSuffixW = hiddenW;
            } else {
                etaSuffixW = dc.getTextWidthInPixels(_etaPeriod, _unitFont);
            }
            var periodW = timeSuffixW > etaSuffixW ? timeSuffixW : etaSuffixW;

            // One font for both rows so they match; fit against the wider value.
            var probe   = dc.getTextWidthInPixels(_timeStr, Graphics.FONT_NUMBER_MEDIUM)
                        > dc.getTextWidthInPixels(etaStr,   Graphics.FONT_NUMBER_MEDIUM)
                        ? _timeStr : etaStr;
            var rowFont = pickFont(dc, probe, w - 2 * CELL_PAD - ICON_ZONE_W - periodW, midY - 2, _rowFonts);
            var numH    = dc.getFontHeight(rowFont);

            var topY  = (midY - numH) / 2;
            var topCY = topY + numH / 2;
            var botY  = midY + (h - midY - numH) / 2;
            var botCY = botY + numH / 2;
            var iconCX = CELL_PAD + ICON_ZONE_W / 2;

            // Shrink the icons with the row height; skip them entirely when the
            // rows are too short for a legible icon.
            var iconSize = ICON_SIZE <= midY - 4 ? ICON_SIZE : midY - 4;
            var drawIcons = iconSize >= 8;

            // Top: clock icon + current time
            if (drawIcons) {
                drawIconClock(dc, iconCX - iconSize / 2, topCY, iconSize);
            }
            if (_etaIsDuration) {
                drawTimeAligned(dc, w - CELL_PAD, topY, rowFont, fgColor);
            } else {
                drawValue(dc, w - CELL_PAD, topY, _timeStr, _timePeriod, rowFont, _unitFont);
            }

            // Divider
            dc.setColor(DIVIDER_COLOR, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawLine(0, midY, w, midY);

            // Bottom: pin icon + arrival time (or remaining duration)
            dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
            if (drawIcons) {
                drawIconArrival(dc, iconCX - iconSize * 3 / 8, botCY - iconSize / 8, iconSize, bgColor);
                dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
            }
            if (_etaIsDuration) {
                drawValue(dc, w - CELL_PAD, botY, etaStr, _durationUnit, rowFont, _durationUnitFont);
            } else {
                drawValue(dc, w - CELL_PAD, botY, etaStr, _etaPeriod, rowFont, _unitFont);
            }
        }
    }

}
