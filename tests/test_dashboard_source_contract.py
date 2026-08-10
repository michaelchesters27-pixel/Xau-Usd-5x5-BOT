from pathlib import Path


DASHBOARD_JS = (
    Path(__file__).parents[1] / "static" / "app.js"
).read_text(encoding="utf-8")

DASHBOARD_HTML = (
    Path(__file__).parents[1] / "templates" / "index.html"
).read_text(encoding="utf-8")


def test_live_polling_cannot_erase_limits_while_user_is_typing():
    assert "let limitsDirty = false;" in DASHBOARD_JS
    assert "if (!limitsDirty)" in DASHBOARD_JS
    assert "limitsDirty = true;" in DASHBOARD_JS
    assert "limitsDirty = false;" in DASHBOARD_JS


def test_browser_restores_limits_after_a_railway_redeploy():
    assert "localStorage.setItem(limitStorageKeys.profit" in DASHBOARD_JS
    assert "localStorage.setItem(limitStorageKeys.loss" in DASHBOARD_JS
    assert "if (!control.limits_configured && saved" in DASHBOARD_JS


def test_dashboard_is_branded_for_xauusd():
    assert "XAU/USD 5×5" in DASHBOARD_HTML
    assert "EUR/USD" not in DASHBOARD_HTML
