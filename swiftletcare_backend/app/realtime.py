"""P2: dashboard real-time qua Flask-SocketIO.

- Server co mot emitter chay nen: moi 2 giay doc dashboard (sp_GetZoneDashboard)
  va emit su kien "dashboard_update" cho moi client dang ket noi, CHI khi du
  lieu thay doi so voi lan emit truoc. Khong co client nao ket noi thi khong
  query DB.
- Frontend nhan su kien thi goi lai load() hien co; neu Socket.IO mat ket noi
  thi polling 2s o frontend van cap nhat dashboard (fallback).
- Emitter chi duoc start tu run.py, khong start trong create_app, de test
  (create_app) khong sinh thread nen.
"""

import json
import logging

from flask import request, session

from . import db, socketio

logger = logging.getLogger(__name__)

EMIT_INTERVAL_SECONDS = 2
_clients = set()
_emitter_started = False


def _dashboard_payload(app):
    """Doc dashboard giong route GET /api/dashboard/zones (khong loc zone)."""
    with app.app_context():
        result_sets = db.call_proc("dbo.sp_GetZoneDashboard", {"ZoneId": None})
        raw = result_sets[0] if result_sets else []
        zones = [
            {
                "zone_id": r["ZoneId"],
                "zone_name": r["ZoneName"],
                "house_name": r["HouseName"],
                "temperature": r["AvgTemperature"],
                "humidity": r["AvgHumidity"],
                "last_updated": r["LastRecordedAt"],
                "status": r["EnvironmentStatus"],
                "sensor_count": r["SensorCount"],
                "reading_sensor_count": r["ReadingSensorCount"],
            }
            for r in raw
        ]
        return {"source": "SQL_SERVER", "zones": zones}


def broadcast_dashboard(payload):
    """Emit mot payload dashboard cho moi client dang ket noi."""
    socketio.emit("dashboard_update", payload)


def emit_dashboard_once(app, last_key):
    """Mot chu ky emitter: tra ve key moi (giong key cu neu khong doi/loi).

    Khong co client ket noi thi khong query DB. Loi DB chi log, khong lam
    chet thread emitter.
    """
    if not _clients:
        return last_key
    try:
        payload = _dashboard_payload(app)
    except Exception:
        logger.exception("Realtime emitter: cannot load dashboard")
        return last_key
    key = json.dumps(payload, sort_keys=True, default=str)
    if key == last_key:
        return last_key
    broadcast_dashboard(payload)
    return key


def emit_new_alerts_once(app, last_alert_ids):
    """P3: mot chu ky kiem tra alert moi: emit 'new_alert' cho moi alert
    PENDING chua tung emit. Tra ve tap AlertId PENDING hien tai."""
    if not _clients:
        return last_alert_ids
    try:
        with app.app_context():
            rows = db.query(
                "SELECT TOP (20) a.AlertId, a.AlertType, a.Message, a.CreatedAt, "
                "z.ZoneName, h.HouseName FROM dbo.Alerts a "
                "JOIN dbo.Zones z ON z.ZoneId = a.ZoneId "
                "JOIN dbo.SwiftletHouses h ON h.HouseId = z.HouseId "
                "WHERE a.Status = 'PENDING' ORDER BY a.CreatedAt DESC, a.AlertId DESC",
            )
    except Exception:
        logger.exception("Realtime emitter: cannot load new alerts")
        return last_alert_ids
    current_ids = {r["AlertId"] for r in rows}
    if last_alert_ids is None:
        return current_ids
    for r in rows:
        if r["AlertId"] not in last_alert_ids:
            socketio.emit(
                "new_alert",
                {
                    "alert_id": r["AlertId"],
                    "alert_type": r["AlertType"],
                    "message": r["Message"],
                    "zone_name": r["ZoneName"],
                    "house_name": r["HouseName"],
                    "created_at": r["CreatedAt"],
                },
            )
    return current_ids


def _emitter_loop(app):
    last_key = None
    last_alert_ids = None
    while True:
        last_key = emit_dashboard_once(app, last_key)
        last_alert_ids = emit_new_alerts_once(app, last_alert_ids)
        socketio.sleep(EMIT_INTERVAL_SECONDS)


def start_emitter(app):
    """Start emitter nen (chi start 1 lan). Chi goi tu run.py."""
    global _emitter_started
    if _emitter_started:
        return
    _emitter_started = True
    socketio.start_background_task(_emitter_loop, app)


@socketio.on("connect")
def _on_connect():
    # Chi client da dang nhap (co session user_id) moi duoc ket noi realtime.
    if not session.get("user_id"):
        return False
    _clients.add(request.sid)
    logger.info("Realtime client connected: %s", request.sid)


@socketio.on("disconnect")
def _on_disconnect():
    _clients.discard(request.sid)
    logger.info("Realtime client disconnected: %s", request.sid)
