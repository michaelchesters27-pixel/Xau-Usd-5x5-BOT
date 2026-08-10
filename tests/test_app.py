from pathlib import Path

import pytest

from app import create_app


@pytest.fixture()
def app(tmp_path: Path):
    return create_app(
        {
            "TESTING": True,
            "SECRET_KEY": "test-secret",
            "BOT_API_KEY": "test-bot-key",
            "DASHBOARD_PASSWORD": "",
            "STATE_DB_PATH": str(tmp_path / "state.db"),
            "DEFAULT_PROFIT_TARGET": 0,
            "DEFAULT_MAX_LOSS": 0,
        }
    )


@pytest.fixture()
def client(app):
    return app.test_client()


def bot_headers():
    return {"X-Bot-Key": "test-bot-key"}


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json()["ok"] is True
    assert response.get_json()["limit_persistence"] is True


def test_dashboard_loads(client):
    response = client.get("/")
    assert response.status_code == 200
    assert b"5\xc3\x975 Campaign Bot" in response.data


def test_bot_api_rejects_wrong_key(client):
    response = client.get("/api/ea/config?session_id=one")
    assert response.status_code == 401


def test_session_waits_until_both_limits_are_set(client):
    response = client.post(
        "/api/ea/start",
        headers=bot_headers(),
        json={"session_id": "session-one"},
    )
    assert response.status_code == 409
    assert "dashboard first" in response.get_json()["error"]


def test_limits_can_be_any_positive_money_amounts(client):
    response = client.post(
        "/api/settings", json={"profit_target": 37.25, "max_loss": 82.9}
    )
    assert response.status_code == 200
    control = response.get_json()["control"]
    assert control["profit_target"] == 37.25
    assert control["max_loss"] == 82.9
    assert control["campaign_target"] == 5.0
    assert control["status"] == "READY"


def test_new_mt5_session_starts_and_same_session_cannot_bypass_off(client):
    client.post("/api/settings", json={"profit_target": 100, "max_loss": 50})
    start = client.post(
        "/api/ea/start", headers=bot_headers(), json={"session_id": "session-one"}
    )
    assert start.status_code == 200
    assert start.get_json()["new_session"] is True
    assert start.get_json()["config"]["enabled"] is True

    off = client.post("/api/off")
    assert off.status_code == 200
    assert off.get_json()["control"]["enabled"] is False

    same = client.post(
        "/api/ea/start", headers=bot_headers(), json={"session_id": "session-one"}
    )
    assert same.status_code == 200
    assert same.get_json()["new_session"] is False
    assert same.get_json()["config"]["enabled"] is False

    new = client.post(
        "/api/ea/start", headers=bot_headers(), json={"session_id": "session-two"}
    )
    assert new.status_code == 200
    assert new.get_json()["new_session"] is True
    assert new.get_json()["config"]["enabled"] is True


def test_telemetry_updates_dashboard_and_terminal_status_disables_bot(client):
    client.post("/api/settings", json={"profit_target": 100, "max_loss": 50})
    client.post(
        "/api/ea/start", headers=bot_headers(), json={"session_id": "session-one"}
    )
    response = client.post(
        "/api/ea/telemetry",
        headers=bot_headers(),
        json={
            "session_id": "session-one",
            "status": "PROFIT_TARGET_REACHED",
            "run_pl": 100.12,
            "campaign_pl": 5.02,
            "campaign_number": 20,
            "open_positions": 0,
            "pending_orders": 0,
            "levels": [],
        },
    )
    assert response.status_code == 200
    status = client.get("/api/status").get_json()
    assert status["control"]["enabled"] is False
    assert status["control"]["status"] == "PROFIT_TARGET_REACHED"
    assert status["telemetry"]["run_pl"] == 100.12


def test_stale_session_cannot_write_telemetry(client):
    client.post("/api/settings", json={"profit_target": 100, "max_loss": 50})
    client.post(
        "/api/ea/start", headers=bot_headers(), json={"session_id": "current"}
    )
    response = client.post(
        "/api/ea/telemetry",
        headers=bot_headers(),
        json={"session_id": "old", "status": "RUNNING"},
    )
    assert response.status_code == 409


def test_old_running_update_does_not_hide_pending_off_request(client):
    client.post("/api/settings", json={"profit_target": 100, "max_loss": 50})
    client.post(
        "/api/ea/start", headers=bot_headers(), json={"session_id": "current"}
    )
    client.post("/api/off")
    response = client.post(
        "/api/ea/telemetry",
        headers=bot_headers(),
        json={"session_id": "current", "status": "RUNNING", "run_pl": 1.0},
    )
    assert response.status_code == 200
    status = client.get("/api/status").get_json()
    assert status["control"]["enabled"] is False
    assert status["control"]["status"] == "OFF_REQUESTED"


def test_dashboard_password_protects_controls(tmp_path: Path):
    protected_app = create_app(
        {
            "TESTING": True,
            "SECRET_KEY": "test-secret",
            "BOT_API_KEY": "test-key",
            "DASHBOARD_PASSWORD": "private",
            "STATE_DB_PATH": str(tmp_path / "protected.db"),
            "DEFAULT_PROFIT_TARGET": 0,
            "DEFAULT_MAX_LOSS": 0,
        }
    )
    client = protected_app.test_client()
    assert client.get("/").status_code == 302
    assert client.get("/api/status").status_code == 401
    assert client.post("/login", data={"password": "wrong"}).status_code == 200
    assert client.post("/login", data={"password": "private"}).status_code == 302
    assert client.get("/api/status").status_code == 200


def test_first_boot_defaults_are_ready_without_a_volume(tmp_path: Path):
    default_app = create_app(
        {
            "TESTING": True,
            "SECRET_KEY": "test-secret",
            "BOT_API_KEY": "test-key",
            "DASHBOARD_PASSWORD": "",
            "STATE_DB_PATH": str(tmp_path / "defaults.db"),
            "DEFAULT_PROFIT_TARGET": 100,
            "DEFAULT_MAX_LOSS": 50,
        }
    )
    status = default_app.test_client().get("/api/status").get_json()
    assert status["control"]["profit_target"] == 100
    assert status["control"]["max_loss"] == 50
    assert status["control"]["status"] == "READY"
