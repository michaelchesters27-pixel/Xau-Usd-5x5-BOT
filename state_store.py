import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TERMINAL_STATUSES = {
    "OFF",
    "OFF_REQUESTED",
    "MANUAL_OFF",
    "PROFIT_TARGET_REACHED",
    "MAX_LOSS_REACHED",
    "EA_STOPPED",
    "ERROR",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class StateStore:
    """Small persistent state store for one XAUUSD EA instance."""

    def __init__(
        self,
        database_path: str,
        default_profit_target: float = 0,
        default_max_loss: float = 0,
    ):
        self.database_path = database_path
        self.default_profit_target = max(0.0, float(default_profit_target))
        self.default_max_loss = max(0.0, float(default_max_loss))
        self._lock = threading.RLock()
        Path(database_path).parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=10)
        connection.row_factory = sqlite3.Row
        return connection

    def _initialize(self) -> None:
        with self._lock, self._connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS control_state (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    profit_target REAL NOT NULL DEFAULT 0,
                    max_loss REAL NOT NULL DEFAULT 0,
                    campaign_target REAL NOT NULL DEFAULT 5,
                    enabled INTEGER NOT NULL DEFAULT 0,
                    active_session TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'WAITING_FOR_LIMITS',
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS telemetry (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    session_id TEXT NOT NULL DEFAULT '',
                    payload TEXT NOT NULL DEFAULT '{}',
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_type TEXT NOT NULL,
                    message TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                """
            )
            now = utc_now()
            initial_status = (
                "READY"
                if self.default_profit_target > 0 and self.default_max_loss > 0
                else "WAITING_FOR_LIMITS"
            )
            connection.execute(
                """
                INSERT OR IGNORE INTO control_state
                    (id, profit_target, max_loss, campaign_target, enabled,
                     active_session, status, updated_at)
                VALUES (1, ?, ?, 5, 0, '', ?, ?)
                """,
                (
                    self.default_profit_target,
                    self.default_max_loss,
                    initial_status,
                    now,
                ),
            )
            connection.execute(
                """
                INSERT OR IGNORE INTO telemetry (id, session_id, payload, updated_at)
                VALUES (1, '', '{}', ?)
                """,
                (now,),
            )

    def _add_event(
        self, connection: sqlite3.Connection, event_type: str, message: str
    ) -> None:
        connection.execute(
            "INSERT INTO events (event_type, message, created_at) VALUES (?, ?, ?)",
            (event_type, message, utc_now()),
        )
        connection.execute(
            """
            DELETE FROM events
            WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 100)
            """
        )

    def get_control(self) -> dict[str, Any]:
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM control_state WHERE id = 1"
            ).fetchone()
            return self._control_dict(row)

    @staticmethod
    def _control_dict(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "profit_target": float(row["profit_target"]),
            "max_loss": float(row["max_loss"]),
            "campaign_target": float(row["campaign_target"]),
            "enabled": bool(row["enabled"]),
            "active_session": row["active_session"],
            "status": row["status"],
            "updated_at": row["updated_at"],
            "limits_configured": (
                float(row["profit_target"]) > 0 and float(row["max_loss"]) > 0
            ),
        }

    def set_limits(self, profit_target: float, max_loss: float) -> dict[str, Any]:
        now = utc_now()
        with self._lock, self._connect() as connection:
            current = connection.execute(
                "SELECT * FROM control_state WHERE id = 1"
            ).fetchone()
            next_status = current["status"]
            if not current["active_session"]:
                next_status = "READY"
            connection.execute(
                """
                UPDATE control_state
                SET profit_target = ?, max_loss = ?, status = ?, updated_at = ?
                WHERE id = 1
                """,
                (profit_target, max_loss, next_status, now),
            )
            self._add_event(
                connection,
                "LIMITS_UPDATED",
                f"Overall limits set: +${profit_target:.2f} / -${max_loss:.2f}",
            )
        return self.get_control()

    def start_session(self, session_id: str) -> tuple[dict[str, Any], bool]:
        """Start only for a genuinely new MT5 attachment/session."""
        now = utc_now()
        with self._lock, self._connect() as connection:
            current = connection.execute(
                "SELECT * FROM control_state WHERE id = 1"
            ).fetchone()
            if float(current["profit_target"]) <= 0 or float(current["max_loss"]) <= 0:
                return self._control_dict(current), False

            is_new_session = session_id != current["active_session"]
            if is_new_session:
                connection.execute(
                    """
                    UPDATE control_state
                    SET enabled = 1, active_session = ?, status = 'STARTING',
                        updated_at = ?
                    WHERE id = 1
                    """,
                    (session_id, now),
                )
                connection.execute(
                    """
                    UPDATE telemetry
                    SET session_id = ?, payload = '{}', updated_at = ?
                    WHERE id = 1
                    """,
                    (session_id, now),
                )
                self._add_event(
                    connection, "SESSION_STARTED", "New MT5 bot session started"
                )
            row = connection.execute(
                "SELECT * FROM control_state WHERE id = 1"
            ).fetchone()
            return self._control_dict(row), is_new_session

    def request_off(self) -> dict[str, Any]:
        now = utc_now()
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                UPDATE control_state
                SET enabled = 0, status = 'OFF_REQUESTED', updated_at = ?
                WHERE id = 1
                """,
                (now,),
            )
            self._add_event(
                connection,
                "OFF_REQUESTED",
                "OFF pressed: close trades and delete pending orders",
            )
        return self.get_control()

    def config_for_session(self, session_id: str) -> dict[str, Any]:
        control = self.get_control()
        stale = bool(control["active_session"]) and (
            session_id != control["active_session"]
        )
        return {
            "enabled": control["enabled"] and not stale,
            "profit_target": control["profit_target"],
            "max_loss": control["max_loss"],
            "campaign_target": control["campaign_target"],
            "status": "STALE_SESSION" if stale else control["status"],
            "session_matches": not stale,
            "server_time": utc_now(),
        }

    def update_telemetry(
        self, session_id: str, payload: dict[str, Any]
    ) -> tuple[bool, str]:
        now = utc_now()
        status = str(payload.get("status", "RUNNING"))[:64]
        with self._lock, self._connect() as connection:
            control = connection.execute(
                "SELECT * FROM control_state WHERE id = 1"
            ).fetchone()
            if session_id != control["active_session"]:
                return False, "stale session"

            connection.execute(
                """
                UPDATE telemetry
                SET session_id = ?, payload = ?, updated_at = ?
                WHERE id = 1
                """,
                (session_id, json.dumps(payload, separators=(",", ":")), now),
            )
            enabled = 0 if status in TERMINAL_STATUSES else int(control["enabled"])
            effective_status = status
            if (
                not bool(control["enabled"])
                and control["status"] == "OFF_REQUESTED"
                and status not in TERMINAL_STATUSES
            ):
                effective_status = "OFF_REQUESTED"
            connection.execute(
                """
                UPDATE control_state
                SET enabled = ?, status = ?, updated_at = ?
                WHERE id = 1
                """,
                (enabled, effective_status, now),
            )
            event_type = str(payload.get("event", ""))[:64]
            if event_type:
                message = str(payload.get("message", event_type))[:300]
                self._add_event(connection, event_type, message)
        return True, "accepted"

    def dashboard_state(self) -> dict[str, Any]:
        with self._lock, self._connect() as connection:
            control_row = connection.execute(
                "SELECT * FROM control_state WHERE id = 1"
            ).fetchone()
            telemetry_row = connection.execute(
                "SELECT * FROM telemetry WHERE id = 1"
            ).fetchone()
            events = connection.execute(
                "SELECT event_type, message, created_at FROM events ORDER BY id DESC LIMIT 20"
            ).fetchall()

        try:
            telemetry = json.loads(telemetry_row["payload"])
        except (TypeError, json.JSONDecodeError):
            telemetry = {}
        return {
            "control": self._control_dict(control_row),
            "telemetry": telemetry,
            "telemetry_updated_at": telemetry_row["updated_at"],
            "events": [dict(row) for row in events],
            "server_time": utc_now(),
        }
