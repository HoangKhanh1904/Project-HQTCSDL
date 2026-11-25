"""P3: dispatcher thong bao khi co canh bao moi (trong app + Gmail SMTP).

- Trigger: route POST /api/simulator/readings goi notify_new_alerts (thread nen)
  khi insert thanh cong, khong phai replay, va AlertCount > 0.
- Moi alert moi: ghi 1 dong NotificationLogs kenh IN_APP (DELIVERED) — ban ghi
  thong bao trong app (trang alerts hien thi qua polling/Socket.IO);
  neu SMTP cau hinh thi gui email va ghi kenh EMAIL (SENT/FAILED);
  neu chua cau hinh SMTP thi ghi EMAIL SKIPPED (chi dung thong bao trong app).
- Gui mail chay trong thread nen de khong chan API ingest; loi chi log,
  khong lam hong request.
"""

import logging
import smtplib
import threading
from email.message import EmailMessage

from . import db

logger = logging.getLogger(__name__)

APP_URL = "http://127.0.0.1:5000"


def _smtp_config(app):
    cfg = app.config
    return {
        "host": cfg.get("SMTP_HOST") or "smtp.gmail.com",
        "port": int(cfg.get("SMTP_PORT") or 587),
        "user": cfg.get("SMTP_USER") or "",
        "password": cfg.get("SMTP_PASSWORD") or "",
        "from": cfg.get("SMTP_FROM") or cfg.get("SMTP_USER") or "",
        "recipients": [
            e.strip()
            for e in (cfg.get("NOTIFY_EMAILS") or "").split(",")
            if e.strip()
        ],
    }


def _smtp_configured(smtp):
    return bool(smtp["user"] and smtp["password"] and smtp["recipients"])



def _log(app, alert_id, channel, status, recipient=None, error=None):
    """Ghi 1 dong NotificationLogs. Loi ghi log chi log, khong raise."""
    try:
        with app.app_context():
            db.query(
                "INSERT INTO dbo.NotificationLogs "
                "(AlertId, Channel, Recipient, Status, ErrorMessage) "
                "VALUES (?, ?, ?, ?, ?)",
                [
                    alert_id,
                    channel,
                    recipient,
                    status,
                    (str(error)[:1000] if error else None),
                ],
            )
    except Exception:
        logger.exception("Notifications: cannot write log for alert %s", alert_id)


def _send_email(smtp, alert, reading):
    msg = EmailMessage()
    msg["Subject"] = (
        f"[SwiftletCare] Canh bao {alert['AlertType']} — "
        f"{alert['ZoneName']} ({alert['HouseName']})"
    )
    msg["From"] = smtp["from"]
    msg["To"] = ", ".join(smtp["recipients"])
    msg.set_content(
        f"{alert['Message']}\n\n"
        f"Nha yen: {alert['HouseName']}\n"
        f"Khu vuc: {alert['ZoneName']}\n"
        f"Loai canh bao: {alert['AlertType']}\n"
        f"So do: nhiet do {reading.get('temperature')}°C, "
        f"do am {reading.get('humidity')}%\n"
        f"Thoi gian: {alert.get('CreatedAt')}\n"
        f"Xem chi tiet: {APP_URL}/alerts\n"
    )
    with smtplib.SMTP(smtp["host"], smtp["port"], timeout=10) as server:
        server.starttls()
        server.login(smtp["user"], smtp["password"])
        server.send_message(msg)



def _fetch_new_alerts(app, reading_id):
    with app.app_context():
        return db.query(
            "SELECT a.AlertId, a.AlertType, a.Message, a.CreatedAt, "
            "z.ZoneName, h.HouseName FROM dbo.Alerts a "
            "JOIN dbo.Zones z ON z.ZoneId = a.ZoneId "
            "JOIN dbo.SwiftletHouses h ON h.HouseId = z.HouseId "
            "WHERE a.ReadingId = ? ORDER BY a.AlertId",
            [reading_id],
        )


def dispatch_for_reading(app, reading_id, reading):
    """Chay trong thread nen. Gui thong bao cho moi alert moi cua reading."""
    try:
        alerts = _fetch_new_alerts(app, reading_id)
    except Exception:
        logger.exception(
            "Notifications: cannot load new alerts for reading %s", reading_id
        )
        return
    if not alerts:
        return
    smtp = _smtp_config(app)
    for alert in alerts:
        _log(app, alert["AlertId"], "IN_APP", "DELIVERED")
        if not _smtp_configured(smtp):
            _log(app, alert["AlertId"], "EMAIL", "SKIPPED")
            continue
        try:
            _send_email(smtp, alert, reading)
        except Exception as exc:
            logger.exception(
                "Notifications: email failed for alert %s", alert["AlertId"]
            )
            _log(app, alert["AlertId"], "EMAIL", "FAILED", error=exc)
            continue
        for recipient in smtp["recipients"]:
            _log(app, alert["AlertId"], "EMAIL", "SENT", recipient=recipient)


def notify_new_alerts(app, reading_id, reading):
    """Khoi dong thread dispatch (khong chan request)."""
    thread = threading.Thread(
        target=dispatch_for_reading, args=(app, reading_id, reading), daemon=True
    )
    thread.start()
