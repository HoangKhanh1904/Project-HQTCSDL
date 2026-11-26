"""P5: test phân quyền theo nhà yến (house scope) cho SwiftletCare.

Chạy (từ thư mục swiftletcare_backend): python -m unittest discover -s tests -v
(không cần SQL Server: app.db.query và app.db.call_proc được mock).

Hợp đồng P5 được kiểm tra:
- managed_house_ids(): ADMIN -> None và KHÔNG truy vấn danh sách nhà;
  STAFF -> [HouseId] từ SELECT ... WHERE ManagerId = UserID của mình;
  STAFF không quản lý nhà nào -> [].
- require_house_access(house_id): nhà không tồn tại -> 404 HOUSE_NOT_FOUND;
  STAFF + nhà của người khác -> 403 HOUSE_FORBIDDEN và không gọi SP nào;
  STAFF + nhà của mình -> OK; ADMIN + nhà bất kỳ đã tồn tại -> OK.
- GET /api/dashboard/zones: STAFF truyền ManagerId = UserID của mình và
  HouseId đã chọn vào sp_GetZoneDashboard; ADMIN truyền ManagerId None;
  mỗi zone trả về có thêm house_id.
- GET /api/farms: SQL/params của STAFF chứa điều kiện ManagerId (chỉ nhà
  mình); của ADMIN không có điều kiện đó.
- GET /api/birds: STAFF xin nhà của người khác -> 403 HOUSE_FORBIDDEN và
  sp_GetBirdMovementDaily không được gọi.
- POST /api/controls/<device_id>: STAFF điều khiển thiết bị thuộc nhà
  người khác -> 403 HOUSE_FORBIDDEN và sp_SimulateDeviceControl không
  được gọi.
- GET /api/alerts: STAFF không truyền zone -> câu query alerts bị giới
  hạn theo các nhà được giao.
- GET /api/analytics/correlation: STAFF truyền ManagerId = UserID của
  mình vào sp_GetEnvironmentYieldCorrelation; ADMIN truyền None.
"""

import inspect
import unittest
from unittest.mock import patch

from flask import g, session

from app import create_app
from app.responses import ApiError

# Helper P5 nằm ở app.auth (bản P5); dự phòng vị trí trong routes.
try:
    from app.auth import managed_house_ids, require_house_access
except ImportError:  # pragma: no cover
    from app.routes.application import managed_house_ids, require_house_access

TOKEN = "test-token-123"
CSRF = "csrf-test"

ADMIN = {"UserID": 1, "UserName": "admin", "Role": "ADMIN", "IsActive": True}
STAFF = {"UserID": 7, "UserName": "staff", "Role": "STAFF", "IsActive": True}
STAFF_NO_HOUSE = {
    "UserID": 8,
    "UserName": "staff8",
    "Role": "STAFF",
    "IsActive": True,
}
USERS = {u["UserID"]: u for u in (ADMIN, STAFF, STAFF_NO_HOUSE)}

# Nhà 10, 11 do STAFF (UserID 7) quản lý; nhà 20 do người khác (99) quản lý;
# nhà 999 không tồn tại.
HOUSES = {
    10: {
        "HouseId": 10,
        "HouseName": "Nhà yến A",
        "Address": "Đồng Nai",
        "ManagerId": 7,
        "Status": "ACTIVE",
    },
    11: {
        "HouseId": 11,
        "HouseName": "Nhà yến B",
        "Address": "Bình Dương",
        "ManagerId": 7,
        "Status": "ACTIVE",
    },
    20: {
        "HouseId": 20,
        "HouseName": "Nhà yến C",
        "Address": "Long An",
        "ManagerId": 99,
        "Status": "ACTIVE",
    },
}
ZONES = {3: {"ZoneId": 3, "HouseId": 10}, 4: {"ZoneId": 4, "HouseId": 20}}
# Thiết bị 5 thuộc nhà 20 (của người khác), thiết bị 6 thuộc nhà 10 (của STAFF).
DEVICES = {
    5: {"DeviceId": 5, "ZoneId": 4, "HouseId": 20},
    6: {"DeviceId": 6, "ZoneId": 3, "HouseId": 10},
}

ZONE_ROWS = [
    {
        "ZoneId": 3,
        "ZoneName": "Tầng 1",
        "HouseId": 10,
        "HouseName": "Nhà yến A",
        "AvgTemperature": 29.5,
        "AvgHumidity": 85.0,
        "LastRecordedAt": "2026-11-26T10:00:00",
        "EnvironmentStatus": "NORMAL",
        "SensorCount": 2,
        "ReadingSensorCount": 2,
    },
    {
        "ZoneId": 4,
        "ZoneName": "Tầng 1",
        "HouseId": 20,
        "HouseName": "Nhà yến C",
        "AvgTemperature": 30.0,
        "AvgHumidity": 83.0,
        "LastRecordedAt": "2026-11-26T10:00:00",
        "EnvironmentStatus": "NORMAL",
        "SensorCount": 1,
        "ReadingSensorCount": 1,
    },
]

PERIOD_QS = "from=2026-11-24T00:00:00%2B07:00&to=2026-11-26T00:00:00%2B07:00"


def make_app(**cfg):
    return create_app(
        {"TESTING": True, "SECRET_KEY": "k", "SIMULATOR_TOKEN": TOKEN, **cfg}
    )


def make_fake_query(record):
    """DB giả lập: phân nhánh theo nội dung SQL, ghi lại mọi lời gọi."""

    def fake_query(sql, params=(), timezone=None):
        params = list(params)
        record.append((sql, params))
        flat = "".join(sql.split())
        if "dbo.Users" in sql:
            user = USERS.get(params[0]) if params else None
            return [dict(user)] if user else []
        if "COUNT" in sql:
            return [{"N": 0}]
        if "dbo.SwiftletHouses" in sql and "ManagerId=?" in flat:
            return [
                {"HouseId": h["HouseId"]}
                for h in HOUSES.values()
                if h["ManagerId"] in params
            ]
        if "dbo.SwiftletHouses" in sql and "HouseId=?" in flat:
            house = HOUSES.get(params[0]) if params else None
            return [dict(house)] if house else []
        if "dbo.Devices" in sql:
            device = DEVICES.get(params[0]) if params else None
            return [dict(device)] if device else []
        if "dbo.Zones" in sql:
            zone = ZONES.get(params[0]) if params else None
            return [dict(zone)] if zone else []
        if "dbo.Alerts" in sql:
            return []
        if "dbo.SwiftletHouses" in sql:
            return [dict(h) for h in HOUSES.values()]
        return []

    return fake_query


def make_fake_call_proc(record):
    """SP giả lập: ghi lại (tên, params) và trả result set đầu tiên."""

    def fake_call_proc(name, params, timezone=None):
        record.append((name, params))
        if name.endswith("sp_GetZoneDashboard"):
            return [ZONE_ROWS]
        if name.endswith("sp_GetBirdMovementDaily"):
            return [
                [
                    {
                        "ReportDate": "2026-11-25",
                        "BirdInCount": 10,
                        "BirdOutCount": 4,
                        "NetMovement": 6,
                    }
                ]
            ]
        if name.endswith("sp_GetEnvironmentYieldCorrelation"):
            return [
                [
                    {
                        "HouseId": params.get("HouseId"),
                        "ReportDate": "2026-11-25",
                        "InRangePct": 90.0,
                        "NetMovement": 6,
                    }
                ]
            ]
        if name.endswith("sp_SimulateDeviceControl"):
            return [
                [
                    {
                        "Success": 1,
                        "Code": "OK",
                        "Message": "Đã điều khiển",
                        "DeviceId": params.get("DeviceId"),
                    }
                ]
            ]
        return [[]]

    return fake_call_proc


def call_managed_house_ids():
    # Chấp nhận cả chữ ký không tham số (đọc user từ g/session) lẫn
    # chữ ký nhận dict user hiện tại.
    if len(inspect.signature(managed_house_ids).parameters) == 0:
        return managed_house_ids()
    return managed_house_ids(g.user)


def call_require_house_access(house_id):
    if len(inspect.signature(require_house_access).parameters) == 0:
        return require_house_access()
    return require_house_access(house_id)


class ScopeTestCase(unittest.TestCase):
    def setUp(self):
        self.app = make_app()
        self.client = self.app.test_client()
        self.queries = []
        self.procs = []
        self.fake_query = make_fake_query(self.queries)
        self.fake_call_proc = make_fake_call_proc(self.procs)

    def login(self, user_id=7, role="STAFF"):
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

    def proc_params(self, proc_name):
        return [params for name, params in self.procs if proc_name in name]

    def push_user_context(self, user, house_id=None):
        path = "/" if house_id is None else f"/?house_id={house_id}"
        ctx = self.app.test_request_context(path)
        ctx.push()
        self.addCleanup(ctx.pop)
        session["user_id"] = user["UserID"]
        session["role"] = user["Role"]
        g.user = dict(user)
        return ctx


class ManagedHouseIdsTests(ScopeTestCase):
    def test_admin_returns_none_without_house_query(self):
        self.push_user_context(ADMIN)
        with patch("app.db.query", side_effect=self.fake_query):
            result = call_managed_house_ids()
        self.assertIsNone(result)
        house_queries = [sql for sql, _ in self.queries if "SwiftletHouses" in sql]
        self.assertEqual(house_queries, [])

    def test_staff_returns_own_house_ids(self):
        self.push_user_context(STAFF)
        with patch("app.db.query", side_effect=self.fake_query):
            result = call_managed_house_ids()
        self.assertEqual(sorted(result), [10, 11])
        managed = [
            (sql, params)
            for sql, params in self.queries
            if "SwiftletHouses" in sql and "ManagerId" in sql
        ]
        self.assertTrue(managed)
        self.assertIn(7, managed[0][1])

    def test_staff_without_houses_returns_empty_list(self):
        self.push_user_context(STAFF_NO_HOUSE)
        with patch("app.db.query", side_effect=self.fake_query):
            result = call_managed_house_ids()
        self.assertEqual(result, [])


class RequireHouseAccessTests(ScopeTestCase):
    def test_house_not_found_404(self):
        self.push_user_context(STAFF, house_id=999)
        with patch("app.db.query", side_effect=self.fake_query):
            with self.assertRaises(ApiError) as cm:
                call_require_house_access(999)
        self.assertEqual(cm.exception.status, 404)
        self.assertEqual(cm.exception.code, "HOUSE_NOT_FOUND")

    def test_staff_other_house_403_and_no_proc(self):
        self.push_user_context(STAFF, house_id=20)
        q, p = self.patched()
        with q, p:
            with self.assertRaises(ApiError) as cm:
                call_require_house_access(20)
        self.assertEqual(cm.exception.status, 403)
        self.assertEqual(cm.exception.code, "HOUSE_FORBIDDEN")
        self.assertEqual(self.procs, [])

    def test_staff_own_house_ok(self):
        self.push_user_context(STAFF, house_id=10)
        with patch("app.db.query", side_effect=self.fake_query):
            call_require_house_access(10)  # không raise là đạt

    def test_admin_any_existing_house_ok(self):
        self.push_user_context(ADMIN, house_id=20)
        with patch("app.db.query", side_effect=self.fake_query):
            call_require_house_access(20)  # không raise là đạt


class DashboardScopeTests(ScopeTestCase):
    def test_staff_passes_manager_and_selected_house(self):
        self.login(7, "STAFF")
        r = self.get("/api/dashboard/zones?house_id=10")
        self.assertEqual(r.status_code, 200)
        calls = self.proc_params("sp_GetZoneDashboard")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["ManagerId"], 7)
        self.assertEqual(calls[0]["HouseId"], 10)

    def test_admin_passes_manager_none(self):
        self.login(1, "ADMIN")
        r = self.get("/api/dashboard/zones")
        self.assertEqual(r.status_code, 200)
        calls = self.proc_params("sp_GetZoneDashboard")
        self.assertEqual(len(calls), 1)
        self.assertIsNone(calls[0]["ManagerId"])

    def test_zones_include_house_id(self):
        self.login(7, "STAFF")
        r = self.get("/api/dashboard/zones?house_id=10")
        self.assertEqual(r.status_code, 200)
        zones = r.get_json()["data"]["zones"]
        self.assertTrue(zones)
        for zone in zones:
            self.assertIn("house_id", zone)
        self.assertEqual(zones[0]["house_id"], ZONE_ROWS[0]["HouseId"])
        self.assertEqual(zones[1]["house_id"], ZONE_ROWS[1]["HouseId"])


class FarmsScopeTests(ScopeTestCase):
    def test_staff_farms_query_scoped_by_manager(self):
        self.login(7, "STAFF")
        r = self.get("/api/farms")
        self.assertEqual(r.status_code, 200)
        # Điều kiện lọc là "ManagerId=?" (cột ManagerId trong SELECT không tính).
        scoped = [
            (sql, params)
            for sql, params in self.queries
            if "SwiftletHouses" in sql
            and "ManagerId=?" in "".join(sql.split())
            and 7 in params
        ]
        self.assertTrue(
            scoped, "STAFF /api/farms phải bị giới hạn theo ManagerId của mình"
        )

    def test_admin_farms_query_has_no_manager_condition(self):
        self.login(1, "ADMIN")
        r = self.get("/api/farms")
        self.assertEqual(r.status_code, 200)
        for sql, _ in self.queries:
            self.assertNotIn("ManagerId=?", "".join(sql.split()))


class BirdsScopeTests(ScopeTestCase):
    def test_staff_other_house_403_and_proc_not_called(self):
        self.login(7, "STAFF")
        r = self.get(f"/api/birds?house_id=20&{PERIOD_QS}")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.get_json()["code"], "HOUSE_FORBIDDEN")
        self.assertEqual(self.proc_params("sp_GetBirdMovementDaily"), [])

    def test_staff_own_house_ok_and_proc_called(self):
        self.login(7, "STAFF")
        r = self.get(f"/api/birds?house_id=10&{PERIOD_QS}")
        self.assertEqual(r.status_code, 200)
        calls = self.proc_params("sp_GetBirdMovementDaily")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["HouseId"], 10)


class ControlsScopeTests(ScopeTestCase):
    def post_control(self, device_id):
        q, p = self.patched()
        with q, p:
            return self.client.post(
                f"/api/controls/{device_id}",
                json={"action": "MANUAL", "is_on": True},
                headers={"X-CSRF-Token": CSRF},
            )

    def test_staff_device_of_other_house_403_and_proc_not_called(self):
        self.login(7, "STAFF")
        r = self.post_control(5)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.get_json()["code"], "HOUSE_FORBIDDEN")
        self.assertEqual(self.proc_params("sp_SimulateDeviceControl"), [])

    def test_staff_device_of_own_house_ok(self):
        self.login(7, "STAFF")
        r = self.post_control(6)
        self.assertEqual(r.status_code, 200)
        calls = self.proc_params("sp_SimulateDeviceControl")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["DeviceId"], 6)


class AlertsScopeTests(ScopeTestCase):
    def test_staff_alerts_without_zone_scoped_to_managed_houses(self):
        self.login(7, "STAFF")
        r = self.get("/api/alerts")
        self.assertEqual(r.status_code, 200)
        alert_calls = [
            (sql, params) for sql, params in self.queries if "dbo.Alerts" in sql
        ]
        self.assertTrue(alert_calls)
        sql, params = alert_calls[0]
        scoped = (
            "ManagerId" in sql
            or "SwiftletHouses" in sql
            or 7 in params
            or (10 in params and 11 in params)
        )
        self.assertTrue(
            scoped, "Query alerts của STAFF phải bị giới hạn theo nhà được giao"
        )


class CorrelationScopeTests(ScopeTestCase):
    def test_staff_passes_manager_id(self):
        self.login(7, "STAFF")
        r = self.get(f"/api/analytics/correlation?house_id=10&{PERIOD_QS}")
        self.assertEqual(r.status_code, 200)
        calls = self.proc_params("sp_GetEnvironmentYieldCorrelation")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["ManagerId"], 7)
        self.assertEqual(calls[0]["HouseId"], 10)

    def test_admin_passes_manager_none(self):
        self.login(1, "ADMIN")
        r = self.get(f"/api/analytics/correlation?{PERIOD_QS}")
        self.assertEqual(r.status_code, 200)
        calls = self.proc_params("sp_GetEnvironmentYieldCorrelation")
        self.assertEqual(len(calls), 1)
        self.assertIsNone(calls[0]["ManagerId"])


if __name__ == "__main__":
    unittest.main()
