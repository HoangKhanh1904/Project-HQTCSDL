"""Chạy: python -m unittest discover -s tests -v   (không cần SQL Server: repository/db được mock)."""
import unittest
from unittest.mock import patch

from app import create_app, db
from app.auth import role_required
from app.responses import ApiError, ok
from app.validation import event_time

TOKEN = "test-token-123"
READING = {"device_id": 1, "temperature": 29.5, "humidity": 85,
           "source_event_id": "3f2b8c1e-5d4a-4e6f-9a7b-1c2d3e4f5a6b"}
H = {"X-Simulator-Token": TOKEN}


def make_app(**cfg):
    app = create_app({"TESTING": True, "SECRET_KEY": "k", "SIMULATOR_TOKEN": TOKEN, **cfg})

    @app.get("/admin-only")
    @role_required("ADMIN")
    def admin_only():
        return ok({"secret": 1})
    return app


class IngestTests(unittest.TestCase):
    def setUp(self):
        self.client = make_app().test_client()

    def post(self, payload, headers=H):
        return self.client.post("/api/simulator/readings", json=payload, headers=headers)

    def test_requires_token(self):
        for headers in ({}, {"X-Simulator-Token": "sai"}):
            r = self.post(READING, headers)
            self.assertEqual(r.status_code, 401)
            self.assertFalse(r.get_json()["success"])

    def test_bearer_token_accepted(self):
        with patch("app.repository.insert_reading", return_value={"Success": 1, "Code": "OK", "ReadingId": 5}):
            r = self.post(READING, {"Authorization": f"Bearer {TOKEN}"})
        self.assertEqual(r.status_code, 201)

    def test_disabled_when_token_not_configured(self):
        client = make_app(SIMULATOR_TOKEN=None).test_client()
        r = client.post("/api/simulator/readings", json=READING, headers=H)
        self.assertEqual(r.status_code, 503)

    def test_new_reading_201(self):
        row = {"Success": 1, "Code": "OK", "Message": "Đã ghi", "ReadingId": 10,
               "AlertCount": 1, "ThresholdStatus": "HIGH_TEMP", "Duplicate": 0}
        with patch("app.repository.insert_reading", return_value=row) as m:
            r = self.post(READING)
        self.assertEqual(r.status_code, 201)
        body = r.get_json()
        self.assertTrue(body["success"])
        self.assertEqual(body["data"]["ReadingId"], 10)
        self.assertEqual(body["data"]["AlertCount"], 1)
        self.assertIsNone(m.call_args[0][0]["co2_ppm"])

    def test_replay_200(self):
        row = {"Success": 1, "Code": "DUPLICATE", "ReadingId": 10, "Duplicate": 1}
        with patch("app.repository.insert_reading", return_value=row):
            r = self.post(READING)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.get_json()["data"]["Duplicate"])

    def test_payload_mismatch_409(self):
        row = {"Success": 0, "Code": "PAYLOAD_MISMATCH", "Message": "Khác payload"}
        with patch("app.repository.insert_reading", return_value=row):
            r = self.post(READING)
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.get_json()["code"], "PAYLOAD_MISMATCH")

    def test_invalid_inputs_rejected_before_db(self):
        bad = [
            {**READING, "humidity": 150}, {**READING, "humidity": -1},
            {**READING, "co2_ppm": -5}, {**READING, "light_lux": -0.1},
            {**READING, "source_event_id": "abc"},
            {k: v for k, v in READING.items() if k != "device_id"},
            {**READING, "temperature": "nóng"}, {**READING, "temperature": True},
            {**READING, "device_id": 0}, {**READING, "temperature": float("nan")},
        ]
        with patch("app.repository.insert_reading") as m:
            for payload in bad:
                r = self.post(payload)
                self.assertEqual(r.status_code, 400, payload)
                self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
            m.assert_not_called()

    def test_non_json_body_400(self):
        r = self.client.post("/api/simulator/readings", data="x", headers=H)
        self.assertEqual(r.status_code, 400)

    def test_co2_light_zero_and_null_accepted(self):
        row = {"Success": 1, "Code": "OK", "ReadingId": 1}
        with patch("app.repository.insert_reading", return_value=row) as m:
            self.assertEqual(self.post({**READING, "co2_ppm": 0, "light_lux": 0}).status_code, 201)
            self.assertEqual(self.post({**READING, "co2_ppm": None, "light_lux": None}).status_code, 201)
            self.assertEqual(m.call_args_list[0][0][0]["co2_ppm"], 0.0)

    def test_procedure_returns_nothing_502(self):
        with patch("app.repository.insert_reading", return_value=None):
            self.assertEqual(self.post(READING).status_code, 502)

    def test_unexpected_error_hides_details(self):
        with patch("app.repository.insert_reading", side_effect=RuntimeError("mật khẩu=abc stacktrace")):
            r = self.post(READING)
        self.assertEqual(r.status_code, 500)
        text = r.get_data(as_text=True)
        self.assertNotIn("mật khẩu", text)
        self.assertNotIn("Traceback", text)


class GeneralTests(unittest.TestCase):
    def test_unknown_route_uses_envelope(self):
        r = make_app().test_client().get("/api/khong-ton-tai")
        self.assertEqual(r.status_code, 404)
        self.assertFalse(r.get_json()["success"])

    def test_health_db_down_is_safe(self):
        err = ApiError(503, "DB_UNAVAILABLE", "Không kết nối được cơ sở dữ liệu.")
        with patch("app.db.ping", side_effect=err):
            r = make_app().test_client().get("/api/health")
        self.assertEqual(r.status_code, 503)
        self.assertEqual(r.get_json()["code"], "DB_UNAVAILABLE")

    def test_role_required(self):
        client = make_app().test_client()
        self.assertEqual(client.get("/admin-only").status_code, 401)
        with client.session_transaction() as s:
            s.update(user_id=7, role="STAFF")
        self.assertEqual(client.get("/admin-only").status_code, 403)
        with client.session_transaction() as s:
            s["role"] = "ADMIN"
        self.assertEqual(client.get("/admin-only").status_code, 200)

    def test_secret_key_required(self):
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaises(RuntimeError):
                create_app()

    def test_call_proc_rejects_bad_names(self):
        with self.assertRaises(ValueError):
            db.call_proc("dbo.sp_x; DROP TABLE Users", {})
        with self.assertRaises(ValueError):
            db.call_proc("dbo.sp_x", {"a; DROP": 1})

    def test_event_time(self):
        self.assertIsNone(event_time({}))
        self.assertEqual(event_time({"event_time": "2026-10-31T08:30:00+07:00"}).hour, 1)
        for bad in ("2026-10-31T08:30:00", "không phải ngày", "2999-01-01T00:00:00Z"):
            with self.assertRaises(ApiError):
                event_time({"event_time": bad})


if __name__ == "__main__":
    unittest.main()
