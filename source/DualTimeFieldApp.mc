import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class DualTimeFieldApp extends Application.AppBase {

    hidden var _view as DualTimeFieldView or Null;

    function initialize() {
        AppBase.initialize();
        _view = null;
    }

    function onSettingsChanged() as Void {
        if (_view != null) {
            (_view as DualTimeFieldView).onSettingsChanged();
        }
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        _view = new DualTimeFieldView();
        return [ _view as DualTimeFieldView ];
    }

}

function getApp() as DualTimeFieldApp {
    return Application.getApp() as DualTimeFieldApp;
}
