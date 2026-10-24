import Toybox.Graphics;
import Toybox.WatchUi;

class Background extends WatchUi.Drawable {

    hidden var mColor as Graphics.ColorValue;

    function initialize() {
        Drawable.initialize({ :identifier => "Background" });
        mColor = Graphics.COLOR_WHITE;
    }

    function setColor(color as Graphics.ColorValue) as Void {
        mColor = color;
    }

    function draw(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, mColor);
        dc.clear();
    }

}
