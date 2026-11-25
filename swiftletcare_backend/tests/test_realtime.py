"""P2 realtime: ket noi Socket.IO yeu cau dang nhap; dashboard_update toi duoc client.

Chay (tu thu muc swiftletcare_backend): python -m unittest discover -s tests -v
(khong can SQL Server: emitter khong start trong create_app).
"""

import unittest
from unittest.mock import patch

from app import create_app, socketio
from app import realtime


def make_app(**cfg):
    return create_app(
        {"TESTING": True, "SECRET_KEY": "k", "SIMULATOR_TOKEN": "t", **cfg}
    )


class RealtimeTests(unittest.TestCase):
    def setUp(self):
        self.app = make_app()
        self.flask_client = self.app.test_client()

    def _login(self):
        with self.flask_client.session_transaction() as sess:
            sess["user_id"] = 1

    def test_connect_requires_login(self):
        client = socketio.test_client(self.app, flask_test_client=self.flask_client)
        try:
            self.assertFalse(client.is_connected())
        finally:
            client.disconnect()

    def test_connect_with_login_and_receive_update(self):
        self._login()
        client = socketio.test_client(self.app, flask_test_client=self.flask_client)
        try:
            self.assertTrue(client.is_connected())
            realtime.broadcast_dashboard({"source": "TEST", "zones": []})
            received = client.get_received()
            self.assertTrue(
                any(
                    r["name"] == "dashboard_update"
                    and r["args"][0]["source"] == "TEST"
                    for r in received
                )
            )
        finally:
            client.disconnect()

    def test_emit_only_on_change(self):
        self._login()
        client = socketio.test_client(self.app, flask_test_client=self.flask_client)
        try:
            payload = {"source": "SQL_SERVER", "zones": [{"zone_id": 1}]}
            with patch.object(
                realtime, "_dashboard_payload", return_value=payload
            ):
                key = realtime.emit_dashboard_once(self.app, None)
                self.assertIsNotNone(key)
                first = client.get_received()
                self.assertEqual(
                    len([r for r in first if r["name"] == "dashboard_update"]),
                    1,
                )
                key2 = realtime.emit_dashboard_once(self.app, key)
                self.assertEqual(key2, key)
                second = client.get_received()
                self.assertEqual(
                    len([r for r in second if r["name"] == "dashboard_update"]),
                    0,
                )
        finally:
            client.disconnect()

    def test_no_db_query_without_clients(self):
        with patch.object(realtime, "_dashboard_payload") as fake:
            key = realtime.emit_dashboard_once(self.app, None)
            fake.assert_not_called()
            self.assertIsNone(key)


if __name__ == "__main__":
    unittest.main()
