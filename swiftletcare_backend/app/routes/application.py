"""Application HTTP contract. No DDL or database business rule duplication."""

import secrets
from datetime import datetime
from zoneinfo import ZoneInfo

from flask import Blueprint, g, render_template, request, session, current_app
from werkzeug.security import check_password_hash

from .. import db
from ..auth import login_required, role_required, simulator_required, managed_house_ids, require_house_access, require_zone_access, require_device_access, require_alert_access, require_event_access
from ..responses import ApiError, ok
from ..validation import choice, event_time, json_body, number, req_guid, req_int

bp = Blueprint("application", __name__)


def text(data, key, maximum, required=True):
    value = data.get(key, "")
    if (
        not isinstance(value, str)
        or (required and not value.strip())
        or len(value.encode("utf-16-le")) // 2 > maximum
    ):
        raise ApiError(
            400, "INVALID_INPUT", f"{key}: chuỗi không hợp lệ (tối đa {maximum} ký tự)."
        )
    return value.strip()


def query_id(name):
    value = request.args.get(name)
    if value is None or value == "":
        return None
    try:
        value = int(value)
    except ValueError:
        raise ApiError(400, "INVALID_INPUT", f"{name} phải là số nguyên.")
    return req_int({name: value}, name)


def limit():
    value = query_id("limit") or 500
    if value > 1000:
        raise ApiError(400, "INVALID_INPUT", "limit tối đa 1000.")
    return value


def period(required=False):
    values = [request.args.get(k) for k in ("from", "to")]
    if not any(values) and not required:
        return None, None
    if not all(values):
        raise ApiError(400, "INVALID_INPUT", "Cần cả from và to có múi giờ.")
    try:
        dates = [datetime.fromisoformat(v.replace("Z", "+00:00")) for v in values]
        if any(d.tzinfo is None for d in dates) or dates[0] >= dates[1]:
            raise ValueError()
    except ValueError:
        raise ApiError(400, "INVALID_INPUT", "Khoảng thời gian không hợp lệ.")
    return tuple(
        d.astimezone(ZoneInfo(current_app.config["DB_TIMEZONE"])).replace(tzinfo=None)
        for d in dates
    )


def procedure(name, params, created=False):
    sets = db.call_proc("dbo." + name, params)
    row = next((s[0] for s in sets if s and "Success" in s[0]), None)
    if row is None:
        raise ApiError(
            502, "BAD_PROCEDURE_RESPONSE", "Procedure thiếu kết quả nghiệp vụ."
        )
    if not row["Success"]:
        code = row.get("Code", "SYSTEM_ERROR")
        status = (
            500
            if code == "SYSTEM_ERROR"
            else 403
            if code == "FORBIDDEN"
            else 404
            if code.endswith("_NOT_FOUND")
            else 409
            if code
            in {
                "IDEMPOTENCY_CONFLICT",
                "CONCURRENCY_CONFLICT",
                "INVALID_STATE",
                "OPEN_ALERT_EXISTS",
                "MANUAL_OVERRIDE",
                "STALE_READING",
                "DEVICE_UNAVAILABLE",
                "ZONE_UNAVAILABLE",
                "READING_UNAVAILABLE",
                "RULE_UNAVAILABLE",
            }
            else 400
        )
        raise ApiError(
            status, code, row.get("Message") or "Không thể thực hiện thao tác."
        )
    return ok(row, status=201 if created and not row.get("Duplicate") else 200)


def rows_proc(name, params):
    timezone = "Asia/Ho_Chi_Minh" if name == "sp_GetSimulatedSystemEvents" else None
    return next(iter(db.call_proc("dbo." + name, params, timezone=timezone)), [])


@bp.get("/")
@bp.get("/<page>")
def page(page="dashboard"):
    if page not in (
        "dashboard",
        "farms",
        "areas",
        "devices",
        "sensors",
        "alerts",
        "birds",
        "analytics",
        "events",
        "controls",
        "login",
    ):
        raise ApiError(404, "NOT_FOUND", "Không tìm thấy trang.")
    return render_template("application.html", page=page)


@bp.get("/api/auth")
def auth_state():
    session.setdefault("csrf_token", secrets.token_urlsafe(32))
    user = None
    if session.get("user_id"):
        records = db.query(
            "SELECT UserID,UserName,Role,IsActive FROM dbo.Users WHERE UserID=?",
            [session["user_id"]],
        )
        if records and records[0]["IsActive"]:
            user = records[0]
        else:
            session.pop("user_id", None)
            session.pop("role", None)
    return ok({"user": user, "csrf_token": session["csrf_token"]})


@bp.post("/api/auth/login")
def login():
    data = json_body()
    username = text(data, "username", 50)
    password = data.get("password")
    if not isinstance(password, str) or not 1 <= len(password) <= 255:
        raise ApiError(400, "INVALID_INPUT", "Mật khẩu không hợp lệ.")
    users = db.query(
        "SELECT UserID,UserName,PasswordHash,Role,IsActive FROM dbo.Users WHERE UserName=?",
        [username],
    )
    valid = False
    if users and users[0]["IsActive"]:
        try:
            valid = check_password_hash(users[0]["PasswordHash"], password)
        except (ValueError, TypeError):
            pass
    if not valid:
        raise ApiError(
            401, "INVALID_CREDENTIALS", "Tên đăng nhập hoặc mật khẩu không đúng."
        )
    session.clear()
    session.update(
        user_id=users[0]["UserID"],
        role=users[0]["Role"],
        csrf_token=secrets.token_urlsafe(32),
    )
    session.permanent = True
    return ok({"csrf_token": session["csrf_token"], "role": users[0]["Role"]})


@bp.post("/api/auth/logout")
def logout():
    session.clear()
    return ok()


@bp.get("/api/managers")
@role_required("ADMIN")
def managers():
    return ok(
        db.query(
            "SELECT UserID,FullName,Role FROM dbo.Users WHERE IsActive=1 ORDER BY UserID"
        )
    )


# Fixed SQL maps: no table or column name is accepted from a request.
ENTITIES = {
    "farms": (
        "SwiftletHouses",
        "HouseId",
        "HouseName",
        "HouseId,HouseName,Address,ManagerId,Status",
    ),
    "areas": (
        "Zones",
        "ZoneId",
        "ZoneName",
        "ZoneId,HouseId,ZoneName,Description,Status",
    ),
    "devices": (
        "Devices",
        "DeviceId",
        "DeviceName",
        "DeviceId,ZoneId,DeviceName,DeviceType,Status",
    ),
}


@bp.get("/api/farms/overview")
@login_required
def farms_overview():
    return ok(
        rows_proc(
            "sp_GetHouseOverview",
            {"ManagerId": None if session.get("role") == "ADMIN" else g.user["UserID"]},
        )
    )


@bp.get("/api/<entity>")
@login_required
def list_entity(entity):
    if entity not in ENTITIES:
        raise ApiError(404, "NOT_FOUND", "Không tìm thấy API.")
    table, key, _, cols = ENTITIES[entity]
    page_no = query_id("page") or 1
    size = limit()
    parent = (
        query_id("house_id" if entity == "areas" else "zone_id")
        if entity != "farms"
        else None
    )
    if entity == "areas" and parent:
        require_house_access(parent)
    if entity == "devices" and parent:
        require_zone_access(parent)
    conditions = []
    params = []
    if parent:
        conditions.append(("HouseId" if entity == "areas" else "ZoneId") + "=?")
        params.append(parent)
    if session.get("role") == "STAFF":
        if entity == "farms":
            conditions.append("ManagerId=?")
            params.append(g.user["UserID"])
        elif entity == "areas":
            conditions.append(
                "HouseId IN (SELECT HouseId FROM dbo.SwiftletHouses WHERE ManagerId=?)"
            )
            params.append(g.user["UserID"])
        elif entity == "devices":
            conditions.append(
                "ZoneId IN (SELECT ZoneId FROM dbo.Zones WHERE HouseId IN (SELECT HouseId FROM dbo.SwiftletHouses WHERE ManagerId=?))"
            )
            params.append(g.user["UserID"])
    where = " WHERE " + " AND ".join(conditions) if conditions else ""
    records = db.query(
        f"SELECT {cols} FROM dbo.{table}{where} ORDER BY {key} DESC OFFSET ? ROWS FETCH NEXT ? ROWS ONLY",
        params + [(page_no - 1) * size, size],
    )
    total = db.query(f"SELECT COUNT_BIG(*) AS N FROM dbo.{table}{where}", params)[0][
        "N"
    ]
    return ok({"items": records, "total": total, "page": page_no, "limit": size})


@bp.route("/api/<entity>", methods=["POST"])
@bp.route("/api/<entity>/<int:item_id>", methods=["PUT", "DELETE"])
@role_required("ADMIN")
def save_entity(entity, item_id=None):
    if entity not in ENTITIES:
        raise ApiError(404, "NOT_FOUND", "Không tìm thấy API.")
    table, key, name, cols = ENTITIES[entity]
    if request.method == "DELETE":
        result = db.query(
            f"UPDATE dbo.{table} SET Status='INACTIVE' OUTPUT inserted.{key} WHERE {key}=?",
            [item_id],
        )
    else:
        data = json_body()
        fields = {
            name: text(data, "name", 100),
            "Status": choice(
                data,
                "status",
                {"ACTIVE", "INACTIVE", "MAINTENANCE"}
                if entity == "devices"
                else {"ACTIVE", "INACTIVE"},
            ),
        }
        if entity == "farms":
            manager_id = req_int(data, "manager_id")
            if not db.query(
                "SELECT UserID FROM dbo.Users WHERE UserID=? AND IsActive=1",
                [manager_id],
            ):
                raise ApiError(400, "INVALID_INPUT", "Người quản lý không hoạt động.")
            fields.update(
                Address=text(data, "address", 255, False), ManagerId=manager_id
            )
        elif entity == "areas":
            fields.update(
                HouseId=req_int(data, "house_id"),
                Description=text(data, "description", 255, False),
            )
        else:
            fields.update(
                ZoneId=req_int(data, "zone_id"),
                DeviceType=choice(
                    data, "device_type", {"SENSOR", "FAN", "HUMIDIFIER", "LIGHT"}
                ),
            )
        if item_id is None:
            result = db.query(
                f"INSERT dbo.{table} ({','.join(fields)}) OUTPUT inserted.{key} VALUES ({','.join('?' for _ in fields)})",
                list(fields.values()),
            )
        else:
            result = db.query(
                f"UPDATE dbo.{table} SET {','.join(k + '=?' for k in fields)} OUTPUT inserted.{key} WHERE {key}=?",
                list(fields.values()) + [item_id],
            )
    if not result:
        raise ApiError(404, "NOT_FOUND", "Không tìm thấy dữ liệu.")
    return ok(result[0], status=201 if item_id is None else 200)


@bp.get("/api/dashboard/zones")
@login_required
def dashboard():
    house_id = query_id("house_id")
    if house_id is not None:
        require_house_access(house_id)
    raw = rows_proc(
        "sp_GetZoneDashboard",
        {
            "ZoneId": query_id("zone_id"),
            "HouseId": house_id,
            "ManagerId": None if session.get("role") == "ADMIN" else g.user["UserID"],
        },
    )
    zones = [
        {
            "zone_id": r["ZoneId"],
            "house_id": r["HouseId"],
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
    return ok({"source": "SQL_SERVER", "zones": zones})


@bp.get("/api/metrics")
@login_required
def metrics():
    start, end = period()
    house_id = query_id("house_id")
    zone_id = query_id("zone_id")
    device_id = query_id("device_id")
    if house_id is not None:
        require_house_access(house_id)
    if zone_id is not None:
        require_zone_access(zone_id)
    if device_id is not None:
        require_device_access(device_id)
    return ok(
        rows_proc(
            "sp_GetEnvironmentMetrics",
            {
                "HouseId": house_id,
                "ZoneId": zone_id,
                "DeviceId": device_id,
                "From": start,
                "To": end,
                "Limit": limit(),
                "ManagerId": None if session.get("role") == "ADMIN" else g.user["UserID"],
            },
        )
    )


@bp.get("/api/alerts")
@login_required
def alerts():
    zone = query_id("zone_id")
    if zone is not None:
        require_zone_access(zone)
    sql = "SELECT TOP (?) AlertId,ZoneId,ReadingId,AlertType,Message,Status,CreatedAt,ResolvedAt FROM dbo.Alerts WHERE (? IS NULL OR ZoneId=?)"
    params = [limit(), zone, zone]
    if session.get("role") == "STAFF" and zone is None:
        sql += " AND ZoneId IN (SELECT ZoneId FROM dbo.Zones WHERE HouseId IN (SELECT HouseId FROM dbo.SwiftletHouses WHERE ManagerId=?))"
        params.append(g.user["UserID"])
    sql += " ORDER BY CreatedAt DESC,AlertId DESC"
    return ok(db.query(sql, params))


@bp.get("/api/alerts/summary")
@login_required
def alerts_summary():
    """P3: so luong alert theo trang thai (cho chuong thong bao trong app)."""
    where = ""
    params = []
    if session.get("role") == "STAFF":
        where = " WHERE ZoneId IN (SELECT ZoneId FROM dbo.Zones WHERE HouseId IN (SELECT HouseId FROM dbo.SwiftletHouses WHERE ManagerId=?))"
        params = [g.user["UserID"]]
    rows = db.query(
        f"SELECT Status, COUNT(*) AS Cnt FROM dbo.Alerts{where} GROUP BY Status",
        params,
    )
    counts = {r["Status"]: r["Cnt"] for r in rows}
    return ok(
        {
            "pending": counts.get("PENDING", 0),
            "acknowledged": counts.get("ACKNOWLEDGED", 0),
            "resolved": counts.get("RESOLVED", 0),
        }
    )


@bp.post("/api/alerts/<int:alert_id>/<action>")
@role_required("ADMIN", "STAFF")
def alert_action(alert_id, action):
    procs = {
        "acknowledge": "sp_AcknowledgeAlert",
        "resolve": "sp_ResolveAlert",
        "reopen": "sp_ReopenAlert",
    }
    if action not in procs:
        raise ApiError(404, "NOT_FOUND", "Hành động không hợp lệ.")
    require_alert_access(alert_id)
    return procedure(procs[action], {"AlertId": alert_id, "UserId": g.user["UserID"]})


@bp.get("/api/thresholds/<int:zone_id>")
@login_required
def threshold(zone_id):
    require_zone_access(zone_id)
    rows = rows_proc("sp_GetEnvironmentThreshold", {"ZoneId": zone_id})
    if rows and rows[0].get("Code") == "THRESHOLD_NOT_FOUND":
        return ok([])
    if rows and not rows[0].get("Success"):
        raise ApiError(
            404 if rows[0].get("Code") == "ZONE_NOT_FOUND" else 500,
            rows[0]["Code"],
            rows[0]["Message"],
        )
    return ok(rows)


@bp.route("/api/thresholds/<int:zone_id>", methods=["POST", "PUT"])
@role_required("ADMIN")
def save_threshold(zone_id):
    data = json_body()
    params = {"ZoneId": zone_id, "UserId": g.user["UserID"]}
    for key, lower, upper, required in [
        ("MinTemperature", -40, 100, True),
        ("MaxTemperature", -40, 100, True),
        ("MinHumidity", 0, 100, True),
        ("MaxHumidity", 0, 100, True),
        # Ngưỡng ánh sáng là tùy chọn: bỏ trống cả hai = chưa cấu hình.
        ("MinLightLux", 0, 200000, False),
        ("MaxLightLux", 0, 200000, False),
    ]:
        params[key] = number(data, key, lower, upper, required=required)
    if (
        params["MinTemperature"] > params["MaxTemperature"]
        or params["MinHumidity"] > params["MaxHumidity"]
    ):
        raise ApiError(400, "INVALID_INPUT", "Min phải nhỏ hơn hoặc bằng Max.")
    if (params["MinLightLux"] is None) != (params["MaxLightLux"] is None):
        raise ApiError(
            400,
            "INVALID_INPUT",
            "Cần gửi cả MinLightLux và MaxLightLux, hoặc bỏ trống cả hai.",
        )
    if (
        params["MinLightLux"] is not None
        and params["MinLightLux"] > params["MaxLightLux"]
    ):
        raise ApiError(
            400, "INVALID_INPUT", "MinLightLux phải nhỏ hơn hoặc bằng MaxLightLux."
        )
    if request.method == "PUT":
        try:
            value = bytes.fromhex(data.get("row_version", ""))
            if len(value) != 8:
                raise ValueError()
        except (ValueError, TypeError):
            raise ApiError(400, "INVALID_INPUT", "row_version cần 16 ký tự hex.")
        params["ExpectedRowVer"] = value
    return procedure(
        "sp_UpdateEnvironmentThreshold"
        if request.method == "PUT"
        else "sp_CreateEnvironmentThreshold",
        params,
    )


def local_event(data):
    value = event_time(data)
    if value is None:
        raise ApiError(
            400,
            "INVALID_INPUT",
            "event_time có múi giờ là bắt buộc và phải giữ nguyên khi retry.",
        )
    return (
        value.replace(tzinfo=ZoneInfo("UTC"))
        .astimezone(ZoneInfo("Asia/Ho_Chi_Minh"))
        .replace(tzinfo=None)
    )


@bp.post("/api/simulator/bird-movements")
@simulator_required
def ingest_birds():
    data = json_body()
    return procedure(
        "sp_InsertBirdMovement",
        {
            "HouseId": req_int(data, "house_id"),
            "Direction": choice(data, "direction", {"IN", "OUT"}),
            "BirdCount": req_int(data, "count"),
            "ObservedAt": local_event(data),
            "SourceType": "SIMULATED",
            "SourceEventId": req_guid(data, "source_event_id"),
        },
        created=True,
    )


@bp.get("/api/birds")
@login_required
def birds():
    period(required=True)
    house = query_id("house_id")
    if house is None:
        raise ApiError(400, "INVALID_INPUT", "house_id là bắt buộc.")
    if not db.query("SELECT HouseId FROM dbo.SwiftletHouses WHERE HouseId=?", [house]):
        raise ApiError(404, "HOUSE_NOT_FOUND", "Nhà yến không tồn tại.")
    require_house_access(house)
    # This procedure groups local Vietnam dates, independently of sensor server time.
    dates = [
        datetime.fromisoformat(request.args[k].replace("Z", "+00:00"))
        .astimezone(ZoneInfo("Asia/Ho_Chi_Minh"))
        .replace(tzinfo=None)
        for k in ("from", "to")
    ]
    return ok(
        rows_proc(
            "sp_GetBirdMovementDaily",
            {"HouseId": house, "From": dates[0], "To": dates[1]},
        )
    )


@bp.get("/api/analytics/correlation")
@login_required
def analytics_correlation():
    """P4: bao cao tuong quan moi truong - chim ra/vao theo nha va khoang ngay.

    Goi SP sp_GetEnvironmentYieldCorrelation(@HouseId, @ZoneId, @From, @To):
    moi dong = 1 nha x 1 ngay (ReportDate): so gio trong nguong uoc tinh,
    ti le thoi gian trong nguong, tong chim IN/OUT va chenh lech (IN - OUT).
    ZoneId/ZoneName chi la tham so loc (NULL khi khong loc khu); phan chim
    luon la cap nha vi BirdMovementEvents khong co ZoneId.
    house_id/zone_id tuy chon (bo trong = tat ca); from/to bat buoc, co mui gio.
    """
    start, end = period(required=True)
    house = query_id("house_id")
    zone = query_id("zone_id")
    if house is not None and not db.query(
        "SELECT HouseId FROM dbo.SwiftletHouses WHERE HouseId=?", [house]
    ):
        raise ApiError(404, "HOUSE_NOT_FOUND", "Nhà yến không tồn tại.")
    if house is not None:
        require_house_access(house)
    if zone is not None:
        require_zone_access(zone)
    return ok(
        rows_proc(
            "sp_GetEnvironmentYieldCorrelation",
            {
                "HouseId": house,
                "ZoneId": zone,
                "From": start,
                "To": end,
                "ManagerId": None if session.get("role") == "ADMIN" else g.user["UserID"],
            },
        )
    )


@bp.post("/api/simulator/events")
@simulator_required
def ingest_event():
    data = json_body()
    return procedure(
        "sp_InsertSimulatedSystemEvent",
        {
            "HouseId": req_int(data, "house_id"),
            "ZoneId": req_int(data, "zone_id"),
            "DeviceId": req_int(data, "device_id")
            if data.get("device_id") is not None
            else None,
            "EventType": choice(
                data,
                "event_type",
                {
                    "PREDATOR_DETECTED",
                    "SPEAKER_FAILURE",
                    "ABNORMAL_SOUND",
                    "DEVICE_OFFLINE",
                },
            ),
            "Severity": choice(data, "severity", {"INFO", "WARNING", "CRITICAL"}),
            "Message": text(data, "message", 255),
            "EventAt": local_event(data),
            "SourceEventId": req_guid(data, "source_event_id"),
        },
        created=True,
    )


@bp.get("/api/events")
@login_required
def events():
    status = request.args.get("status") or None
    if status not in (None, "NEW", "ACKNOWLEDGED", "RESOLVED"):
        raise ApiError(400, "INVALID_INPUT", "status không hợp lệ.")
    house_id = query_id("house_id")
    zone_id = query_id("zone_id")
    if house_id is not None:
        require_house_access(house_id)
    if zone_id is not None:
        require_zone_access(zone_id)
    return ok(
        rows_proc(
            "sp_GetSimulatedSystemEvents",
            {
                "HouseId": house_id,
                "ZoneId": zone_id,
                "Status": status,
                "Limit": limit(),
                "ManagerId": None if session.get("role") == "ADMIN" else g.user["UserID"],
            },
        )
    )


@bp.post("/api/events/<int:event_id>/status")
@role_required("ADMIN", "STAFF")
def event_status(event_id):
    data = json_body()
    require_event_access(event_id)
    return procedure(
        "sp_UpdateSimulatedEventStatus",
        {
            "EventId": event_id,
            "UserId": g.user["UserID"],
            "ExpectedStatus": choice(data, "expected_status", {"NEW", "ACKNOWLEDGED"}),
            "NewStatus": choice(data, "status", {"ACKNOWLEDGED", "RESOLVED"}),
        },
    )


@bp.get("/api/controls")
@login_required
def controls():
    sql = "SELECT d.DeviceId,d.DeviceName,d.ZoneId,d.DeviceType,s.ControlMode,s.IsOn,s.UpdatedAt FROM dbo.Devices d LEFT JOIN dbo.DeviceControlSettings s ON s.DeviceId=d.DeviceId WHERE d.DeviceType<>'SENSOR'"
    params = []
    if session.get("role") == "STAFF":
        sql += " AND d.ZoneId IN (SELECT ZoneId FROM dbo.Zones WHERE HouseId IN (SELECT HouseId FROM dbo.SwiftletHouses WHERE ManagerId=?))"
        params = [g.user["UserID"]]
    sql += " ORDER BY d.DeviceId"
    return ok(db.query(sql, params, timezone="Asia/Ho_Chi_Minh"))


@bp.post("/api/controls/<int:device_id>")
@role_required("ADMIN", "STAFF")
def control(device_id):
    data = json_body()
    require_device_access(device_id)
    action = choice(data, "action", {"SET_MODE", "MANUAL", "AUTO"})
    params = {"DeviceId": device_id, "UserId": g.user["UserID"], "Action": action}
    if action == "SET_MODE":
        params["ControlMode"] = choice(data, "mode", {"AUTO", "MANUAL"})
    elif action == "MANUAL":
        if not isinstance(data.get("is_on"), bool):
            raise ApiError(400, "INVALID_INPUT", "is_on phải là boolean.")
        params["IsOn"] = data["is_on"]
    else:
        value = data.get("reading_id")
        try:
            if isinstance(value, bool) or not isinstance(value, (int, str)):
                raise ValueError()
            value = int(value)
        except (ValueError, TypeError):
            raise ApiError(400, "INVALID_INPUT", "reading_id không hợp lệ.")
        params["ReadingId"] = req_int({"id": value}, "id", maximum=9223372036854775807)
    return procedure("sp_SimulateDeviceControl", params)
