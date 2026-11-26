"""P4 analytics: test API /api/analytics/correlation theo contract route THAT
da build (patch P4), khong phai contract du kien ban dau.

Chay (tu thu muc swiftletcare_backend): python -m unittest discover -s tests -v
(khong can SQL Server: app.db.query va app.db.call_proc duoc mock).

Contract route that:
- GET /api/analytics/correlation, @login_required: chua dang nhap -> 401.
- period(required=True): from/to BAT BUOC, phai co mui gio, from < to.
  Thieu ca hai dau, thieu mot dau, thieu mui gio hoac from >= to
  -> 400 INVALID_INPUT. Khong co mac dinh 7 ngay, khong gioi han 92 ngay.
- house_id/zone_id tuy chon qua query_id(): khong phai so nguyen -> 400.
  house_id co nhung khong ton tai trong dbo.SwiftletHouses
  -> 404 HOUSE_NOT_FOUND, va SP khong duoc goi.
- Route goi rows_proc("sp_GetEnvironmentYieldCorrelation",
  {"HouseId": ..., "ZoneId": ..., "From": start, "To": end});
  rows_proc goi db.call_proc("dbo.sp_GetEnvironmentYieldCorrelation", ...)
  va lay result set DAU TIEN. Route tra ok(rows): data la MANG THUAN cac
  dong SP tra, giu nguyen ten cot cua SP (PascalCase) -- khong phai
  {"days": [...], "summary": {...}}, khong co result set tong thu hai.
"""

import unittest
from datetime import datetime
from unittest.mock import patch

from app import create_app

USER = {"UserID": 7, "UserName": "admin", "Role": "ADMIN", "IsActive": True}

# Chi nha 1 ton tai trong DB gia lap; nha khac -> 404 HOUSE_NOT_FOUND.
EXISTING_HOUSE_IDS = {1}

# Hai dong mau dung dang SP tra (1 dong = 1 nha x 1 ngay, kem he so Pearson
# da tinh san trong tung dong). Route tra nguyen cac dong nay trong data.
ROWS = [
    {
        "HouseId": 1,
        "HouseName": "Nha yen 1",
        "ZoneId": 2,
        "ZoneName": "Khu A",
        "ReportDate": "2026-11-24",
        "ReadingCount": 4,
        "InRangePct": 75.0,
        "EstimatedHoursInRange": 18.0,
        "AvgTemperature": 30.5,
        "AvgHumidity": 82.0,
        "BirdInCount": 120,
        "BirdOutCount": 100,
        "NetMovement": 20,
        "PearsonInRangeVsNet": 1.0,
    },
    {
        "HouseId": 1,
        "HouseName": "Nha yen 1",
        "ZoneId": 2,
        "ZoneName": "Khu A",
        "ReportDate": "2026-11-25",
        "ReadingCount": 4,
        "InRangePct": 100.0,
        "EstimatedHoursInRange": 24.0,
        "AvgTemperature": 29.8,
        "AvgHumidity": 84.5,
        "BirdInCount": 150,
        "BirdOutCount": 110,
        "NetMovement": 40,
        "PearsonInRangeVsNet": 1.0,
    },
]

VALID_QS = "?from=2026-11-24T00:00:00%2B07:00&to=2026-11-26T00:00:00%2B07:00"


def make_app(**cfg):
    return create_app(
        {
            "TESTING": True,
            "SECRET_KEY": "k",
            "SIMULATOR_TOKEN": "test-token",
            "DB_TIMEZONE": "Asia/Ho_Chi_Minh",
            **cfg,
        }
    )


def fake_query(sql, params=()):
    if "FROM dbo.Users" in sql:
        return [USER]
    if "FROM dbo.SwiftletHouses" in sql:
        house_id = params[0] if params else None
        return [{"HouseId": house_id}] if house_id in EXISTING_HOUSE_IDS else []
    return []


class CorrelationTests(unittest.TestCase):
    def setUp(self):
        self.app = make_app()
        self.client = self.app.test_client()
        self.calls = []

    def _login(self):
        with self.client.session_transaction() as s:
            s.update(user_id=7, role="ADMIN")

    def _call_proc(self, rows=ROWS):
        def fake(name, params, timezone=None):
            self.calls.append((name, params))
            # Mot result set duy nhat; rows_proc lay sets[0].
            return [rows]

        return fake

    def _get(self, qs=VALID_QS, rows=ROWS):
        with patch("app.db.query", side_effect=fake_query), patch(
            "app.db.call_proc", side_effect=self._call_proc(rows)
        ):
            return self.client.get("/api/analytics/correlation" + qs)

    def test_requires_login(self):
        with patch("app.db.query", side_effect=fake_query), patch(
            "app.db.call_proc", side_effect=self._call_proc()
        ) as proc:
            r = self.client.get("/api/analytics/correlation" + VALID_QS)
        self.assertEqual(r.status_code, 401)
        self.assertFalse(r.get_json()["success"])
        proc.assert_not_called()

    def test_returns_rows_array_verbatim(self):
        self._login()
        r = self._get(
            "?house_id=1&zone_id=2"
            "&from=2026-11-24T00:00:00%2B07:00&to=2026-11-26T00:00:00%2B07:00"
        )
        self.assertEqual(r.status_code, 200)
        body = r.get_json()
        self.assertTrue(body["success"])
        # data la mang thuan cac dong SP, giu nguyen ten cot PascalCase;
        # khong boc trong {"days": ..., "summary": ...}.
        self.assertIsInstance(body["data"], list)
        self.assertEqual(body["data"], ROWS)
        self.assertEqual(body["data"][0]["InRangePct"], 75.0)
        self.assertEqual(body["data"][1]["InRangePct"], 100.0)
        self.assertEqual(body["data"][1]["NetMovement"], 40)

    def test_proc_called_with_filters_and_period(self):
        self._login()
        r = self._get(
            "?house_id=1&zone_id=2"
            "&from=2026-11-24T00:00:00%2B07:00&to=2026-11-26T00:00:00%2B07:00"
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(self.calls), 1)
        name, params = self.calls[0]
        self.assertEqual(name, "dbo.sp_GetEnvironmentYieldCorrelation")
        self.assertEqual(params["HouseId"], 1)
        self.assertEqual(params["ZoneId"], 2)
        # period() doi ve gio DB (Asia/Ho_Chi_Minh) va bo tzinfo.
        self.assertEqual(params["From"], datetime(2026, 11, 24, 0, 0))
        self.assertEqual(params["To"], datetime(2026, 11, 26, 0, 0))

    def test_filters_optional(self):
        self._login()
        r = self._get()
        self.assertEqual(r.status_code, 200)
        _, params = self.calls[0]
        self.assertIsNone(params["HouseId"])
        self.assertIsNone(params["ZoneId"])

    def test_house_not_found_returns_404(self):
        self._login()
        r = self._get(
            "?house_id=999"
            "&from=2026-11-24T00:00:00%2B07:00&to=2026-11-26T00:00:00%2B07:00"
        )
        self.assertEqual(r.status_code, 404)
        body = r.get_json()
        self.assertFalse(body["success"])
        self.assertEqual(body["code"], "HOUSE_NOT_FOUND")
        self.assertEqual(self.calls, [])

    def test_missing_period_rejected(self):
        # period(required=True): khong truyen from/to -> 400, khong co
        # khoang mac dinh 7 ngay nhu contract cu.
        self._login()
        r = self._get("")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.calls, [])

    def test_missing_from_rejected(self):
        self._login()
        r = self._get("?to=2026-11-26T00:00:00%2B07:00")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.calls, [])

    def test_missing_to_rejected(self):
        self._login()
        r = self._get("?from=2026-11-24T00:00:00%2B07:00")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.calls, [])

    def test_period_without_timezone_rejected(self):
        self._login()
        r = self._get("?from=2026-11-24T00:00:00&to=2026-11-26T00:00:00")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.calls, [])

    def test_from_not_before_to_rejected(self):
        self._login()
        r = self._get(
            "?from=2026-11-26T00:00:00%2B07:00&to=2026-11-26T00:00:00%2B07:00"
        )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.calls, [])
        r = self._get(
            "?from=2026-11-27T00:00:00%2B07:00&to=2026-11-26T00:00:00%2B07:00"
        )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.calls, [])

    def test_invalid_house_id_rejected(self):
        self._login()
        r = self._get(
            "?house_id=abc"
            "&from=2026-11-24T00:00:00%2B07:00&to=2026-11-26T00:00:00%2B07:00"
        )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.calls, [])

    def test_invalid_zone_id_rejected(self):
        self._login()
        r = self._get(
            "?zone_id=1.5"
            "&from=2026-11-24T00:00:00%2B07:00&to=2026-11-26T00:00:00%2B07:00"
        )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.calls, [])

    def test_empty_result_returns_empty_list(self):
        self._login()
        r = self._get(rows=[])
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.get_json()["data"], [])


if __name__ == "__main__":
    unittest.main()
