"""P6: test tìm kiếm phía server (q) + lọc status + validation ngưỡng.

Chạy (từ thư mục swiftletcare_backend): python -m unittest discover -s tests -v
(không cần SQL Server: app.db.query và app.db.call_proc được mock hoàn toàn).

Hợp đồng P6 được kiểm tra:
- list_entity (farms/areas/devices) nhận tham số `q`: tối đa 100 ký tự
  (dài hơn -> 400 INVALID_INPUT, không chạy câu list); escape LIKE kiểu
  T-SQL: `[` -> `[[]`, `%` -> `[%]`, `_` -> `[_]`, pattern = "%" + đã
  escape + "%". Cột tìm kiếm: farms -> HouseName, Address; areas ->
  ZoneName, Description; devices -> DeviceName, DeviceType.
- list_entity nhận tham số `status`: chỉ ACTIVE/INACTIVE, riêng devices
  thêm MAINTENANCE; giá trị khác -> 400 INVALID_INPUT. Điều kiện lọc là
  "Status=?" và cộng dồn với phân quyền STAFF (ManagerId) + phân trang.
- alerts() nhận `q`: tìm trong Message và AlertType.
- controls() nhận `q`: tìm trong DeviceName.
- save_threshold (đã có từ trước): Min > Max -> 400; chỉ nhập một trong
  hai Min/MaxLightLux -> 400; MinLightLux > MaxLightLux -> 400; cả ba
  trường hợp đều KHÔNG gọi stored procedure.
"""

import unittest
from unittest.mock import patch

from app import create_app

TOKEN = "test-token-123"
CSRF = "csrf-test"

ADMIN = {"UserID": 7, "UserName": "admin", "Role": "ADMIN", "IsActive": True}
STAFF = {"UserID": 6002, "UserName": "staff", "Role": "STAFF", "IsActive": True}
USERS = {u["UserID"]: u for u in (ADMIN, STAFF)}

# Chỉ nhà 1 và khu 2 (thuộc nhà 1) "tồn tại" trong DB giả lập, để các câu
# kiểm tra SwiftletHouses/Zones của tầng phân quyền trả về 1 dòng khi hợp lệ.
VALID_HOUSE_IDS = {1}
VALID_ZONES = {2: 1}  # ZoneId -> HouseId

FARM_ROWS = [
    {
        "HouseId": 1,
        "HouseName": "Nhà yến Bình Dương",
        "Address": "Bình Dương",
        "ManagerId": 6002,
        "Status": "ACTIVE",
    }
]
AREA_ROWS = [
    {
        "ZoneId": 2,
        "HouseId": 1,
        "ZoneName": "Khu Alpha",
        "Description": "Khu alpha",
        "Status": "ACTIVE",
    }
]
DEVICE_ROWS = [
    {
        "DeviceId": 3,
        "ZoneId": 2,
        "DeviceName": "Quạt 1",
        "DeviceType": "FAN",
        "Status": "ACTIVE",
    }
]
ALERT_ROWS = [
    {
        "AlertId": 9,
        "ZoneId": 2,
        "ReadingId": None,
        "AlertType": "HIGH_TEMP",
        "Message": "Cảnh báo nhiệt độ cao",
        "Status": "PENDING",
        "CreatedAt": "2026-11-28T10:00:00",
        "ResolvedAt": None,
    }
]
CONTROL_ROWS = [
    {
        "DeviceId": 3,
        "DeviceName": "Đèn 1",
        "ZoneId": 2,
        "DeviceType": "LIGHT",
        "ControlMode": "AUTO",
        "IsOn": True,
        "UpdatedAt": "2026-11-28T10:00:00",
    }
]

BASE_THRESHOLD = {
    "MinTemperature": 26,
    "MaxTemperature": 32,
    "MinHumidity": 70,
    "MaxHumidity": 90,
}


def make_app(**cfg):
    return create_app(
        {"TESTING": True, "SECRET_KEY": "k", "SIMULATOR_TOKEN": TOKEN, **cfg}
    )


class SearchTestCase(unittest.TestCase):
    def setUp(self):
        self.app = make_app()
        self.client = self.app.test_client()
        self.queries = []  # mọi (sql, params) đã gọi qua db.query
        self.procs = []  # mọi (name, params) đã gọi qua db.call_proc
        self.count_n = 2  # giá trị N mà câu COUNT_BIG giả lập trả về

    # DB giả lập: phân nhánh theo nội dung SQL, ghi lại mọi lời gọi.
    def fake_query(self, sql, params=(), timezone=None):
        params = list(params)
        self.queries.append((sql, params))
        flat = "".join(sql.split())
        if "dbo.Users" in sql:
            user = USERS.get(params[0]) if params else None
            return [dict(user)] if user else []
        if "COUNT_BIG" in sql:
            return [{"N": self.count_n}]
        if "OFFSET" in sql:  # câu list có phân trang của list_entity
            if "dbo.SwiftletHouses" in sql:
                return [dict(r) for r in FARM_ROWS]
            if "dbo.Zones" in sql:
                return [dict(r) for r in AREA_ROWS]
            if "dbo.Devices" in sql:
                return [dict(r) for r in DEVICE_ROWS]
            return []
        if "dbo.SwiftletHouses" in sql and "ManagerId=?" in flat:
            # managed_house_ids(): các nhà STAFF quản lý.
            return [{"HouseId": 1}] if STAFF["UserID"] in params else []
        if "dbo.SwiftletHouses" in sql and "HouseId=?" in flat:
            house_id = params[0] if params else None
            return (
                [{"HouseId": house_id}] if house_id in VALID_HOUSE_IDS else []
            )
        if "dbo.Zones" in sql and "ZoneId=?" in flat:
            zone_id = params[0] if params else None
            if zone_id in VALID_ZONES:
                return [{"ZoneId": zone_id, "HouseId": VALID_ZONES[zone_id]}]
            return []
        if "dbo.Devices" in sql and "DeviceId=?" in flat:
            return [{"DeviceId": params[0], "ZoneId": 2, "HouseId": 1}]
        if "dbo.Alerts" in sql:
            return [dict(r) for r in ALERT_ROWS]
        if "dbo.Devices" in sql:  # câu list của controls()
            return [dict(r) for r in CONTROL_ROWS]
        return []

    def fake_call_proc(self, name, params=None, timezone=None):
        self.procs.append((name, dict(params or {})))
        return [[{"Success": 1, "Code": "OK", "Message": "OK"}]]

    def login(self, user_id=7, role="ADMIN"):
        with self.client.session_transaction() as s:
            s.update(user_id=user_id, role=role, csrf_token=CSRF)

    def patched(self):
        return patch("app.db.query", side_effect=self.fake_query), patch(
            "app.db.call_proc", side_effect=self.fake_call_proc
        )

    def get(self, url):
        q, p = self.patched()
        with q, p:
            return self.client.get(url)

    def post_threshold(self, payload, zone_id=2):
        q, p = self.patched()
        with q, p:
            return self.client.post(
                f"/api/thresholds/{zone_id}",
                json=payload,
                headers={"X-CSRF-Token": CSRF},
            )

    def list_calls(self):
        """Các câu list có phân trang (chứa OFFSET) đã gọi."""
        return [(sql, params) for sql, params in self.queries if "OFFSET" in sql]

    def count_calls(self):
        return [
            (sql, params) for sql, params in self.queries if "COUNT_BIG" in sql
        ]

    def calls_containing(self, text):
        return [(sql, params) for sql, params in self.queries if text in sql]


class ListSearchTests(SearchTestCase):
    def test_areas_search_matches_zone_name_and_description(self):
        self.login()
        r = self.get("/api/areas?q=alpha")
        self.assertEqual(r.status_code, 200)
        calls = self.list_calls()
        self.assertEqual(len(calls), 1)
        sql, params = calls[0]
        self.assertIn("ZoneName LIKE ?", sql)
        self.assertIn("Description LIKE ?", sql)
        self.assertIn("%alpha%", params)

    def test_devices_search_matches_device_name_and_type(self):
        self.login()
        r = self.get("/api/devices?q=quat")
        self.assertEqual(r.status_code, 200)
        calls = self.list_calls()
        self.assertEqual(len(calls), 1)
        sql, params = calls[0]
        self.assertIn("DeviceName LIKE ?", sql)
        self.assertIn("DeviceType LIKE ?", sql)
        self.assertIn("%quat%", params)

    def test_farms_search_matches_house_name_and_address(self):
        self.login()
        r = self.get("/api/farms?q=binh")
        self.assertEqual(r.status_code, 200)
        calls = self.list_calls()
        self.assertEqual(len(calls), 1)
        sql, params = calls[0]
        self.assertIn("HouseName LIKE ?", sql)
        self.assertIn("Address LIKE ?", sql)
        self.assertIn("%binh%", params)

    def test_search_escapes_percent_sign(self):
        self.login()
        r = self.get("/api/farms?q=100%25")
        self.assertEqual(r.status_code, 200)
        _, params = self.list_calls()[0]
        # % gốc phải thành [%]: pattern trọn vẹn là "%100[%]%", không còn
        # ký tự % trần nào trong phần từ khóa.
        self.assertIn("%100[%]%", params)
        self.assertNotIn("%100%%", params)

    def test_search_escapes_underscore(self):
        self.login()
        r = self.get("/api/farms?q=a_b")
        self.assertEqual(r.status_code, 200)
        _, params = self.list_calls()[0]
        self.assertIn("%a[_]b%", params)

    def test_search_term_over_100_chars_rejected_without_list_query(self):
        self.login()
        r = self.get("/api/farms?q=" + "x" * 101)
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.list_calls(), [])
        self.assertEqual(self.count_calls(), [])

    def test_no_search_term_adds_no_like_condition(self):
        self.login()
        r = self.get("/api/farms")
        self.assertEqual(r.status_code, 200)
        sql, _ = self.list_calls()[0]
        self.assertNotIn("LIKE", sql)
        self.queries.clear()
        r = self.get("/api/farms?q=")
        self.assertEqual(r.status_code, 200)
        sql, _ = self.list_calls()[0]
        self.assertNotIn("LIKE", sql)

    def test_status_active_adds_status_condition(self):
        self.login()
        r = self.get("/api/farms?status=ACTIVE")
        self.assertEqual(r.status_code, 200)
        sql, params = self.list_calls()[0]
        self.assertIn("Status=?", "".join(sql.split()))
        self.assertIn("ACTIVE", params)

    def test_invalid_status_rejected(self):
        self.login()
        r = self.get("/api/farms?status=XYZ")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.list_calls(), [])

    def test_devices_accept_maintenance_but_farms_reject_it(self):
        self.login()
        r = self.get("/api/devices?status=MAINTENANCE")
        self.assertEqual(r.status_code, 200)
        _, params = self.list_calls()[0]
        self.assertIn("MAINTENANCE", params)
        self.queries.clear()
        r = self.get("/api/farms?status=MAINTENANCE")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.list_calls(), [])

    def test_staff_farms_search_keeps_manager_scope_and_like(self):
        self.login(user_id=6002, role="STAFF")
        r = self.get("/api/farms?q=binh")
        self.assertEqual(r.status_code, 200)
        sql, params = self.list_calls()[0]
        # Vừa bị giới hạn theo ManagerId của STAFF, vừa có điều kiện LIKE.
        self.assertIn("ManagerId=?", "".join(sql.split()))
        self.assertIn("LIKE", sql)
        self.assertIn(6002, params)
        self.assertIn("%binh%", params)

    def test_total_reflects_filtered_count(self):
        self.login()
        self.count_n = 3
        r = self.get("/api/farms?q=binh")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.get_json()["data"]["total"], 3)

    def test_pagination_offset_kept_with_search(self):
        self.login()
        r = self.get("/api/farms?q=binh&page=2&limit=50")
        self.assertEqual(r.status_code, 200)
        _, params = self.list_calls()[0]
        # OFFSET (page-1)*limit = 50 nằm ngay trước FETCH NEXT 50.
        self.assertEqual(params[-2], 50)
        self.assertEqual(params[-1], 50)
        body = r.get_json()["data"]
        self.assertEqual(body["page"], 2)
        self.assertEqual(body["limit"], 50)


class AlertControlSearchTests(SearchTestCase):
    def test_alerts_search_matches_message_and_alert_type(self):
        self.login()
        r = self.get("/api/alerts?q=canh%20bao")
        self.assertEqual(r.status_code, 200)
        calls = [
            (sql, params)
            for sql, params in self.calls_containing("dbo.Alerts")
            if "LIKE" in sql
        ]
        self.assertEqual(len(calls), 1)
        sql, params = calls[0]
        self.assertIn("Message LIKE ?", sql)
        self.assertIn("AlertType LIKE ?", sql)
        self.assertIn("%canh bao%", params)

    def test_controls_search_matches_device_name(self):
        self.login()
        r = self.get("/api/controls?q=den")
        self.assertEqual(r.status_code, 200)
        calls = [
            (sql, params)
            for sql, params in self.calls_containing("dbo.Devices")
            if "LIKE" in sql
        ]
        self.assertEqual(len(calls), 1)
        sql, params = calls[0]
        self.assertIn("DeviceName LIKE ?", sql)
        self.assertIn("%den%", params)


class ThresholdValidationTests(SearchTestCase):
    def test_threshold_min_temperature_above_max_rejected_without_proc(self):
        self.login()
        r = self.post_threshold(
            {**BASE_THRESHOLD, "MinTemperature": 35, "MaxTemperature": 32}
        )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.procs, [])

    def test_threshold_only_min_light_rejected_without_proc(self):
        self.login()
        r = self.post_threshold({**BASE_THRESHOLD, "MinLightLux": 100})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.procs, [])

    def test_threshold_min_light_above_max_rejected_without_proc(self):
        self.login()
        r = self.post_threshold(
            {**BASE_THRESHOLD, "MinLightLux": 600, "MaxLightLux": 500}
        )
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.get_json()["code"], "INVALID_INPUT")
        self.assertEqual(self.procs, [])


if __name__ == "__main__":
    unittest.main()
