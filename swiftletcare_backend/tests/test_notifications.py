"""P3 notifications: email chi gui khi co alert moi va SMTP cau hinh; loi duoc log.

Chay (tu thu muc swiftletcare_backend): python -m unittest discover -s tests -v
(khong can SQL Server, khong gui mail that: smtplib va db duoc mock).
"""

import unittest
from unittest.mock import patch

from app import create_app
from app import notifications

TOKEN = "test-token"
READING = {"device_id": 1, "temperature": 36.5, "humidity": 85}
ALERT = {
    "AlertId": 7,
    "AlertType": "HIGH_TEMP",
    "Message": "Nhiệt độ vượt ngưỡng tối đa",
    "CreatedAt": "2026-11-25T10:00:00",
    "ZoneName": "Khu A",
    "HouseName": "Nha yen 1",
}


def make_app(**cfg):
    return create_app(
        {
            "TESTING": True,
            "SECRET_KEY": "k",
            "SIMULATOR_TOKEN": TOKEN,
            **cfg,
        }
    )


class DispatcherTests(unittest.TestCase):
    def setUp(self):
        self.app = make_app(
            SMTP_USER="sender@gmail.com",
            SMTP_PASSWORD="app-password",
            NOTIFY_EMAILS="manager1@gmail.com, manager2@gmail.com",
        )

    def test_email_sent_when_configured(self):
        with (
            patch.object(notifications, "_fetch_new_alerts", return_value=[ALERT]),
            patch.object(notifications, "_log") as log,
            patch("app.notifications.smtplib.SMTP") as smtp_cls,
        ):
            notifications.dispatch_for_reading(self.app, 10, READING)
        server = smtp_cls.return_value.__enter__.return_value
        server.starttls.assert_called_once()
        server.login.assert_called_once_with("sender@gmail.com", "app-password")
        server.send_message.assert_called_once()
        sent = server.send_message.call_args[0][0]
        self.assertIn("HIGH_TEMP", sent["Subject"])
        self.assertEqual(sent["To"], "manager1@gmail.com, manager2@gmail.com")
        channels = [(c.args[2], c.args[3]) for c in log.call_args_list]
        self.assertIn(("IN_APP", "DELIVERED"), channels)
        self.assertEqual(channels.count(("EMAIL", "SENT")), 2)

    def test_email_skipped_when_not_configured(self):
        app = make_app()
        with (
            patch.object(notifications, "_fetch_new_alerts", return_value=[ALERT]),
            patch.object(notifications, "_log") as log,
            patch("app.notifications.smtplib.SMTP") as smtp_cls,
        ):
            notifications.dispatch_for_reading(app, 10, READING)
        smtp_cls.assert_not_called()
        channels = [(c.args[2], c.args[3]) for c in log.call_args_list]
        self.assertIn(("IN_APP", "DELIVERED"), channels)
        self.assertIn(("EMAIL", "SKIPPED"), channels)

    def test_email_failure_logged(self):
        with (
            patch.object(notifications, "_fetch_new_alerts", return_value=[ALERT]),
            patch.object(notifications, "_log") as log,
            patch("app.notifications.smtplib.SMTP") as smtp_cls,
        ):
            smtp_cls.return_value.__enter__.return_value.send_message.side_effect = (
                RuntimeError("smtp down")
            )
            notifications.dispatch_for_reading(self.app, 10, READING)
        channels = [(c.args[2], c.args[3]) for c in log.call_args_list]
        self.assertIn(("EMAIL", "FAILED"), channels)

    def test_no_alerts_no_email(self):
        with (
            patch.object(notifications, "_fetch_new_alerts", return_value=[]),
            patch.object(notifications, "_log") as log,
            patch("app.notifications.smtplib.SMTP") as smtp_cls,
        ):
            notifications.dispatch_for_reading(self.app, 10, READING)
        smtp_cls.assert_not_called()
        log.assert_not_called()


class TriggerTests(unittest.TestCase):
    def setUp(self):
        self.app = make_app()
        self.client = self.app.test_client()

    def _post_reading(self, row):
        with patch(
            "app.repository.insert_reading", return_value=row
        ), patch(
            "app.routes.simulator.notifications.notify_new_alerts"
        ) as notify:
            r = self.client.post(
                "/api/simulator/readings",
                json={
                    "device_id": 1,
                    "temperature": 29.5,
                    "humidity": 85,
                    "source_event_id": "3f2b8c1e-5d4a-4e6f-9a7b-1c2d3e4f5a6b",
                },
                headers={"X-Simulator-Token": TOKEN},
            )
        return r, notify

    def test_trigger_on_new_alerts(self):
        r, notify = self._post_reading(
            {
                "Success": 1,
                "Code": "OK",
                "Message": "OK",
                "ReadingId": 10,
                "AlertCount": 2,
                "ThresholdStatus": "CONFIGURED",
                "Duplicate": 0,
            }
        )
        self.assertEqual(r.status_code, 201)
        notify.assert_called_once()

    def test_no_trigger_without_alerts(self):
        r, notify = self._post_reading(
            {
                "Success": 1,
                "Code": "OK",
                "Message": "OK",
                "ReadingId": 10,
                "AlertCount": 0,
                "ThresholdStatus": "CONFIGURED",
                "Duplicate": 0,
            }
        )
        self.assertEqual(r.status_code, 201)
        notify.assert_not_called()

    def test_no_trigger_on_replay(self):
        r, notify = self._post_reading(
            {
                "Success": 1,
                "Code": "OK",
                "Message": "OK",
                "ReadingId": 10,
                "AlertCount": 2,
                "ThresholdStatus": "CONFIGURED",
                "Duplicate": 1,
            }
        )
        self.assertEqual(r.status_code, 200)
        notify.assert_not_called()


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.app = make_app()
        self.client = self.app.test_client()
        with self.client.session_transaction() as s:
            s.update(user_id=7, role="ADMIN")

    def test_alerts_summary(self):
        def fake_query(sql, params=()):
            if "FROM dbo.Users" in sql:
                return [
                    {
                        "UserID": 7,
                        "UserName": "admin",
                        "Role": "ADMIN",
                        "IsActive": True,
                    }
                ]
            return [
                {"Status": "PENDING", "Cnt": 3},
                {"Status": "ACKNOWLEDGED", "Cnt": 1},
            ]

        with patch("app.db.query", side_effect=fake_query):
            r = self.client.get("/api/alerts/summary")
        self.assertEqual(r.status_code, 200)
        data = r.get_json()["data"]
        self.assertEqual(data["pending"], 3)
        self.assertEqual(data["acknowledged"], 1)
        self.assertEqual(data["resolved"], 0)


if __name__ == "__main__":
    unittest.main()
