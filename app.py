import hmac
import os
from functools import wraps
from pathlib import Path
from typing import Any, Callable

from flask import Flask, jsonify, redirect, render_template, request, session, url_for

from state_store import StateStore


def create_app(test_config: dict[str, Any] | None = None) -> Flask:
    app = Flask(__name__)
    default_database = os.environ.get("STATE_DB_PATH", "/tmp/xauusd-5x5/state.db")
    app.config.from_mapping(
        SECRET_KEY=os.environ.get("SECRET_KEY", "local-development-secret"),
        BOT_API_KEY=os.environ.get("BOT_API_KEY", "local-dev-key"),
        DASHBOARD_PASSWORD=os.environ.get("DASHBOARD_PASSWORD", ""),
        STATE_DB_PATH=default_database,
        DEFAULT_PROFIT_TARGET=float(os.environ.get("DEFAULT_PROFIT_TARGET", "100")),
        DEFAULT_MAX_LOSS=float(os.environ.get("DEFAULT_MAX_LOSS", "50")),
    )
    if test_config:
        app.config.update(test_config)

    Path(app.config["STATE_DB_PATH"]).parent.mkdir(parents=True, exist_ok=True)
    store = StateStore(
        app.config["STATE_DB_PATH"],
        default_profit_target=app.config["DEFAULT_PROFIT_TARGET"],
        default_max_loss=app.config["DEFAULT_MAX_LOSS"],
    )
    app.extensions["state_store"] = store

    def dashboard_authorized() -> bool:
        password = app.config["DASHBOARD_PASSWORD"]
        return not password or bool(session.get("dashboard_authenticated"))

    def dashboard_login_required(view: Callable[..., Any]) -> Callable[..., Any]:
        @wraps(view)
        def wrapped(*args: Any, **kwargs: Any) -> Any:
            if dashboard_authorized():
                return view(*args, **kwargs)
            if request.path.startswith("/api/"):
                return jsonify({"error": "dashboard login required"}), 401
            return redirect(url_for("login"))

        return wrapped

    def ea_authorized() -> bool:
        supplied = request.headers.get("X-Bot-Key", "")
        expected = app.config["BOT_API_KEY"]
        return bool(expected) and hmac.compare_digest(supplied, expected)

    def require_ea_key(view: Callable[..., Any]) -> Callable[..., Any]:
        @wraps(view)
        def wrapped(*args: Any, **kwargs: Any) -> Any:
            if not ea_authorized():
                return jsonify({"error": "invalid bot key"}), 401
            return view(*args, **kwargs)

        return wrapped

    @app.get("/health")
    def health() -> Any:
        return jsonify(
            {
                "ok": True,
                "service": "xauusd-5x5-bot",
                "version": "1.00",
                "limit_persistence": True,
            }
        )

    @app.route("/login", methods=["GET", "POST"])
    def login() -> Any:
        if not app.config["DASHBOARD_PASSWORD"]:
            return redirect(url_for("dashboard"))
        error = ""
        if request.method == "POST":
            supplied = request.form.get("password", "")
            if hmac.compare_digest(supplied, app.config["DASHBOARD_PASSWORD"]):
                session["dashboard_authenticated"] = True
                return redirect(url_for("dashboard"))
            error = "Incorrect password"
        return render_template("login.html", error=error)

    @app.post("/logout")
    def logout() -> Any:
        session.clear()
        return redirect(url_for("login"))

    @app.get("/")
    @dashboard_login_required
    def dashboard() -> Any:
        return render_template("index.html")

    @app.get("/api/status")
    @dashboard_login_required
    def dashboard_status() -> Any:
        return jsonify(store.dashboard_state())

    @app.post("/api/settings")
    @dashboard_login_required
    def update_settings() -> Any:
        data = request.get_json(silent=True) or {}
        try:
            profit_target = round(float(data.get("profit_target", 0)), 2)
            max_loss = round(float(data.get("max_loss", 0)), 2)
        except (TypeError, ValueError):
            return jsonify({"error": "Enter valid money amounts"}), 400
        if profit_target <= 0 or max_loss <= 0:
            return jsonify({"error": "Both amounts must be greater than zero"}), 400
        if profit_target > 1_000_000 or max_loss > 1_000_000:
            return jsonify({"error": "Amount is outside the supported range"}), 400
        return jsonify({"ok": True, "control": store.set_limits(profit_target, max_loss)})

    @app.post("/api/off")
    @dashboard_login_required
    def off() -> Any:
        return jsonify({"ok": True, "control": store.request_off()})

    @app.post("/api/ea/start")
    @require_ea_key
    def ea_start() -> Any:
        data = request.get_json(silent=True) or {}
        session_id = str(data.get("session_id", "")).strip()[:120]
        if not session_id:
            return jsonify({"error": "session_id is required"}), 400
        control, is_new = store.start_session(session_id)
        if not control["limits_configured"]:
            return (
                jsonify(
                    {
                        "error": "Set the overall profit target and maximum loss on the dashboard first",
                        "control": control,
                    }
                ),
                409,
            )
        return jsonify(
            {
                "ok": True,
                "new_session": is_new,
                "config": store.config_for_session(session_id),
            }
        )

    @app.get("/api/ea/config")
    @require_ea_key
    def ea_config() -> Any:
        session_id = request.args.get("session_id", "")[:120]
        if not session_id:
            return jsonify({"error": "session_id is required"}), 400
        return jsonify(store.config_for_session(session_id))

    @app.post("/api/ea/telemetry")
    @require_ea_key
    def ea_telemetry() -> Any:
        data = request.get_json(silent=True) or {}
        session_id = str(data.pop("session_id", "")).strip()[:120]
        if not session_id:
            return jsonify({"error": "session_id is required"}), 400
        accepted, message = store.update_telemetry(session_id, data)
        if not accepted:
            return jsonify({"error": message}), 409
        return jsonify({"ok": True})

    return app


app = create_app()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), debug=False)
