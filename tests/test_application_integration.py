"""Real HTTP + SQL regression and deterministic event replay. No repository mocks."""

import concurrent.futures
import threading
import uuid
import os
import subprocess
import sys
import re
from pathlib import Path

import pytest
import requests

from conftest import Client

pytestmark = pytest.mark.integration


def ingest(server, config, path, payload):
    return requests.post(
        server + "/api/simulator/" + path,
        json=payload,
        headers={"X-Simulator-Token": config["simulator_token"]},
        timeout=20,
    )


def reading(f, **kwargs):
    return {
        "device_id": f["SENSOR"],
        "temperature": 29,
        "humidity": 80,
        "source_event_id": str(uuid.uuid4()),
        **kwargs,
    }


def test_reading_replay_conflict_and_dashboard(
    client, server, test_config, fixture_data, sql
):
    f = fixture_data
    p = reading(f, temperature=35, humidity=65, co2_ppm=0, light_lux=0)
    first = ingest(server, test_config, "readings", p)
    assert first.status_code == 201, first.text
    duplicate = ingest(server, test_config, "readings", p)
    assert duplicate.status_code == 200 and duplicate.json()["data"]["Duplicate"]
    assert duplicate.json()["data"]["ReadingId"] == first.json()["data"]["ReadingId"]
    conflict = ingest(server, test_config, "readings", {**p, "temperature": 36})
    assert (
        conflict.status_code == 409
        and conflict.json()["code"] == "IDEMPOTENCY_CONFLICT"
    )
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.SensorReadings WHERE DeviceId=?", f["SENSOR"]
        ).fetchval()
        == 1
    )
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.Alerts WHERE ZoneId=?", f["zone"]
        ).fetchval()
        == 2
    )
    dashboard = client.data("GET", "/dashboard/zones?zone_id=" + str(f["zone"]))[
        "zones"
    ][0]
    assert dashboard["temperature"] == 35 and dashboard["status"] == "WARNING"
    metrics = client.data("GET", "/metrics?device_id=" + str(f["SENSOR"]))[0]
    assert (
        metrics["CO2Ppm"] == 0
        and metrics["LightLux"] == 0
        and metrics["RecordeAt"].endswith("+00:00")
    )


@pytest.mark.parametrize(
    "overrides",
    [
        dict(temperature=-40),
        dict(temperature=100),
        dict(co2_ppm=100000, light_lux=200000),
        dict(co2_ppm=None, light_lux=None),
    ],
)
def test_sql_http_boundaries(server, test_config, fixture_data, overrides):
    r = ingest(server, test_config, "readings", reading(fixture_data, **overrides))
    assert r.status_code == 201, r.text


@pytest.mark.parametrize(
    "overrides",
    [
        dict(temperature=-40.01),
        dict(temperature=100.01),
        dict(co2_ppm=100000.01),
        dict(humidity=True),
        dict(light_lux=-1),
    ],
)
def test_bad_inputs_do_not_write(server, test_config, fixture_data, sql, overrides):
    f = fixture_data
    r = ingest(server, test_config, "readings", reading(f, **overrides))
    assert r.status_code == 400
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.SensorReadings WHERE DeviceId=?", f["SENSOR"]
        ).fetchval()
        == 0
    )


def test_bird_backtest_daily_boundaries_and_retry(
    client, server, test_config, fixture_data, sql
):
    f = fixture_data
    # UTC dates deliberately cross midnight in Vietnam. Expected counts are literal.
    events = [
        ("IN", 7, "2026-01-01T16:59:59Z"),
        ("OUT", 2, "2026-01-01T16:59:59Z"),
        ("IN", 11, "2026-01-01T17:00:00Z"),
    ]
    for direction, count, at in events:
        p = {
            "house_id": f["house"],
            "direction": direction,
            "count": count,
            "event_time": at,
            "source_event_id": str(uuid.uuid4()),
        }
        first = ingest(server, test_config, "bird-movements", p)
        assert first.status_code == 201, first.text
        assert ingest(server, test_config, "bird-movements", p).status_code == 200
        assert (
            ingest(
                server, test_config, "bird-movements", {**p, "count": count + 1}
            ).status_code
            == 409
        )
    result = client.data(
        "GET",
        f"/birds?house_id={f['house']}&from=2026-01-01T00:00:00%2B07:00&to=2026-01-02T00:00:00%2B07:00",
    )
    assert (
        len(result) == 1
        and result[0]["InCount"] == 7
        and result[0]["OutCount"] == 2
        and result[0]["EventCount"] == 2
    )
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.BirdMovementEvents WHERE HouseId=?", f["house"]
        ).fetchval()
        == 3
    )


def test_events_contract_and_transitions(client, server, test_config, fixture_data):
    f = fixture_data
    p = {
        "house_id": f["house"],
        "zone_id": f["zone"],
        "device_id": f["SENSOR"],
        "event_type": "PREDATOR_DETECTED",
        "severity": "WARNING",
        "message": "Mô phỏng chim săn mồi",
        "event_time": "2026-01-01T17:00:00Z",
        "source_event_id": str(uuid.uuid4()),
    }
    r = ingest(server, test_config, "events", p)
    assert r.status_code == 201, r.text
    eid = r.json()["data"]["EventId"]
    assert ingest(server, test_config, "events", p).status_code == 200
    assert (
        ingest(server, test_config, "events", {**p, "message": "khác"}).status_code
        == 409
    )
    assert (
        ingest(
            server, test_config, "events", {**p, "event_type": "PREDATOR"}
        ).status_code
        == 400
    )
    listed = client.data("GET", f"/events?house_id={f['house']}")
    assert listed[0]["EventAt"] == "2026-01-02T00:00:00+07:00"
    result = client.data(
        "POST",
        f"/events/{eid}/status",
        json={"expected_status": "NEW", "status": "ACKNOWLEDGED"},
    )
    assert result["Changed"]
    assert not client.data(
        "POST",
        f"/events/{eid}/status",
        json={"expected_status": "NEW", "status": "ACKNOWLEDGED"},
    )["Changed"]
    client.data(
        "POST",
        f"/events/{eid}/status",
        json={"expected_status": "ACKNOWLEDGED", "status": "RESOLVED"},
    )
    assert client.data("GET", f"/events?house_id={f['house']}") == []


def test_alert_lifecycle_and_audit(client, server, test_config, fixture_data, sql):
    f = fixture_data
    assert (
        ingest(server, test_config, "readings", reading(f, temperature=35)).status_code
        == 201
    )
    aid = sql.execute(
        "SELECT AlertId FROM dbo.Alerts WHERE ZoneId=?", f["zone"]
    ).fetchval()
    assert client.request("POST", f"/alerts/{aid}/resolve", json={}).status_code == 409
    for action in ("acknowledge", "resolve", "reopen"):
        client.data("POST", f"/alerts/{aid}/{action}", json={})
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.AlertActions WHERE AlertId=?", aid
        ).fetchval()
        == 3
    )
    assert (
        sql.execute("SELECT Status FROM dbo.Alerts WHERE AlertId=?", aid).fetchval()
        == "PENDING"
    )


def test_concurrent_same_event_http(server, test_config, fixture_data, sql):
    f = fixture_data
    payload = reading(f, temperature=35)
    barrier = threading.Barrier(8)

    def send(_):
        barrier.wait(timeout=10)
        r = ingest(server, test_config, "readings", payload)
        return r.status_code, r.json()["data"]["ReadingId"]

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(send, range(8)))
    assert sorted(s for s, _ in results) == [200] * 7 + [201]
    assert len({r for _, r in results}) == 1
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.Alerts WHERE ZoneId=?", f["zone"]
        ).fetchval()
        == 1
    )


def test_concurrent_different_payload_one_winner(
    server, test_config, fixture_data, sql
):
    f = fixture_data
    payload = reading(f)
    barrier = threading.Barrier(2)

    def send(temp):
        barrier.wait(timeout=10)
        return ingest(
            server, test_config, "readings", {**payload, "temperature": temp}
        ).status_code

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        result = list(pool.map(send, [28, 30]))
    assert sorted(result) == [201, 409]
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.SensorReadings WHERE DeviceId=?", f["SENSOR"]
        ).fetchval()
        == 1
    )


def test_concurrent_threshold_rowversion(client, server, test_config, fixture_data):
    f = fixture_data
    version = client.data("GET", f"/thresholds/{f['zone']}")[0]["RowVer"]
    clients = [Client(server, test_config), Client(server, test_config)]
    barrier = threading.Barrier(2)

    def save(pair):
        i, c = pair
        barrier.wait(timeout=10)
        return c.request(
            "PUT",
            f"/thresholds/{f['zone']}",
            json={**f["thresholds"], "MaxTemperature": 33 + i, "row_version": version},
        ).status_code

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(save, enumerate(clients)))
        assert sorted(results) == [200, 409]
    finally:
        for c in clients:
            c.session.close()


def test_control_hysteresis_and_manual_override(
    client, server, test_config, fixture_data, sql
):
    f = fixture_data
    path = "/controls/" + str(f["FAN"])
    client.data("POST", path, json={"action": "SET_MODE", "mode": "AUTO"})
    for temp, expected in [(35, True), (29, True), (25, False)]:
        r = ingest(
            server, test_config, "readings", reading(f, temperature=temp)
        ).json()["data"]["ReadingId"]
        assert (
            client.data("POST", path, json={"action": "AUTO", "reading_id": str(r)})[
                "IsOn"
            ]
            == expected
        )
    client.data("POST", path, json={"action": "MANUAL", "is_on": True})
    assert (
        client.request(
            "POST", path, json={"action": "AUTO", "reading_id": str(r)}
        ).status_code
        == 409
    )
    assert sql.execute(
        "SELECT IsOn FROM dbo.DeviceControlSettings WHERE DeviceId=?", f["FAN"]
    ).fetchval()


def test_authorization_csrf_and_least_privilege(
    client, server, test_config, fixture_data, sql
):
    assert requests.get(server + "/api/farms", timeout=10).status_code == 401
    assert (
        client.session.post(server + "/api/farms", json={}, timeout=10).status_code
        == 403
    )
    staff = Client(server, test_config, "apptest_staff")
    try:
        assert staff.request("POST", "/farms", json={}).status_code == 403
        assert staff.request("GET", "/farms").status_code == 200
        assert (
            staff.request(
                "PUT", f"/thresholds/{fixture_data['zone']}", json={}
            ).status_code
            == 403
        )
    finally:
        staff.session.close()
    import pyodbc

    c = test_config
    conn = pyodbc.connect(
        f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER=127.0.0.1,{c['port']};DATABASE={c['database']};UID={c['app_user']};PWD={c['app_password']};Encrypt=yes;TrustServerCertificate=yes;",
        autocommit=True,
    )
    try:
        assert tuple(
            conn.execute(
                "SELECT IS_SRVROLEMEMBER('sysadmin'),IS_MEMBER('db_owner')"
            ).fetchone()
        ) == (0, 0)
        with pytest.raises(pyodbc.Error):
            conn.execute(
                "INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity) VALUES (?,29,80)",
                fixture_data["SENSOR"],
            )
    finally:
        conn.close()


def test_api_invalid_filters(client):
    for path in [
        "/metrics?from=bad",
        "/metrics?limit=1001",
        "/events?status=BAD",
        "/birds",
        "/metrics?device_id=-1",
    ]:
        assert client.request("GET", path).status_code == 400, path


def test_real_db_connection_failure_is_safe(client, monkeypatch):
    monkeypatch.setenv(
        "MSSQL_PORT", "14338"
    )  # Dedicated unused test port; not the user's instance.
    r = client.request("GET", "/health")
    assert r.status_code == 503
    assert r.json()["code"] == "DB_UNAVAILABLE"
    assert "password" not in r.text.lower() and "traceback" not in r.text.lower()


def test_missing_threshold_and_no_sample(client):
    uid = client.data("GET", "/managers")[0]["UserID"]
    hid = client.data(
        "POST",
        "/farms",
        json={"name": "Chưa cấu hình", "manager_id": uid, "status": "ACTIVE"},
    )["HouseId"]
    zid = client.data(
        "POST",
        "/areas",
        json={"name": "Chưa có ngưỡng", "house_id": hid, "status": "ACTIVE"},
    )["ZoneId"]
    assert client.data("GET", f"/thresholds/{zid}") == []
    assert (
        client.data("GET", f"/dashboard/zones?zone_id={zid}")["zones"][0]["status"]
        == "UNCONFIGURED"
    )
    sid = client.data(
        "POST",
        "/devices",
        json={
            "name": "Chưa đo",
            "zone_id": zid,
            "device_type": "SENSOR",
            "status": "ACTIVE",
        },
    )["DeviceId"]
    row = client.data("GET", f"/metrics?device_id={sid}")[0]
    assert row["ReadingStatus"] == "NO_DATA" and all(
        row[k] is None for k in ("Temperature", "Humidity", "CO2Ppm", "LightLux")
    )


def test_concurrent_two_sensors_no_duplicate_open_alert(
    client, server, test_config, fixture_data, sql
):
    f = fixture_data
    sid = client.data(
        "POST",
        "/devices",
        json={
            "name": "Sensor 2",
            "zone_id": f["zone"],
            "device_type": "SENSOR",
            "status": "ACTIVE",
        },
    )["DeviceId"]
    barrier = threading.Barrier(2)

    def send(device):
        barrier.wait(timeout=10)
        return ingest(
            server,
            test_config,
            "readings",
            reading(f, device_id=device, temperature=35),
        ).status_code

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        assert list(pool.map(send, [sid, f["SENSOR"]])) == [201, 201]
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.Alerts WHERE ZoneId=? AND AlertType='HIGH_TEMP' AND Status='PENDING'",
            f["zone"],
        ).fetchval()
        == 1
    )


def test_concurrent_alert_ack_has_one_audit(
    client, server, test_config, fixture_data, sql
):
    f = fixture_data
    ingest(server, test_config, "readings", reading(f, temperature=35))
    aid = sql.execute(
        "SELECT AlertId FROM dbo.Alerts WHERE ZoneId=?", f["zone"]
    ).fetchval()
    clients = [Client(server, test_config), Client(server, test_config)]
    barrier = threading.Barrier(2)

    def send(c):
        barrier.wait(timeout=10)
        return c.request("POST", f"/alerts/{aid}/acknowledge", json={}).status_code

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            statuses = list(pool.map(send, clients))
        assert sorted(statuses) == [200, 409]
        assert (
            sql.execute(
                "SELECT COUNT(*) FROM dbo.AlertActions WHERE AlertId=?", aid
            ).fetchval()
            == 1
        )
    finally:
        for c in clients:
            c.session.close()


def test_real_fk_error_does_not_persist(client, sql):
    before = sql.execute("SELECT COUNT(*) FROM dbo.Devices").fetchval()
    r = client.request(
        "POST",
        "/devices",
        json={
            "name": "Bad FK",
            "zone_id": 2147483647,
            "device_type": "SENSOR",
            "status": "ACTIVE",
        },
    )
    assert r.status_code == 409
    assert sql.execute("SELECT COUNT(*) FROM dbo.Devices").fetchval() == before
    assert client.request("GET", "/devices").status_code == 200


@pytest.mark.parametrize(
    "scenario",
    [
        "normal",
        "high_temperature",
        "low_humidity",
        "co2_light",
        "repeat_event",
        "invalid_input",
        "birds",
        "predator",
        "speaker_failure",
        "abnormal_sound",
        "device_offline",
    ],
)
def test_simulator_cli_real_http(server, test_config, fixture_data, scenario):
    f = fixture_data
    script = (
        Path(__file__).resolve().parents[1]
        / "swiftletcare_backend"
        / "simulator"
        / "run.py"
    )
    result = subprocess.run(
        [
            sys.executable,
            str(script),
            "--scenario",
            scenario,
            "--api",
            server,
            "--device",
            str(f["SENSOR"]),
            "--house",
            str(f["house"]),
            "--zone",
            str(f["zone"]),
            "--duration",
            "0.1",
            "--seed",
            "7",
        ],
        env={
            **os.environ,
            "SIMULATOR_TOKEN": test_config["simulator_token"],
            "PYTHONUTF8": "1",
        },
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=20,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert re.search(r"^\[\s*\d+\]\s+OK\b", result.stdout, re.M)
    assert not re.search(r"^\[\s*\d+\]\s+FAIL\b", result.stdout, re.M)


def test_http_ingest_fault_rolls_back_and_recovers(
    server, test_config, fixture_data, sql
):
    f = fixture_data
    # Force the second write (alert) to fail after the first write (reading).
    sql.execute(
        f"ALTER TABLE dbo.Alerts WITH NOCHECK ADD CONSTRAINT CK_AppHTTPFault CHECK(ZoneId<>{f['zone']});"
    )
    try:
        result = ingest(server, test_config, "readings", reading(f, temperature=35))
        assert result.status_code == 500
        assert "traceback" not in result.text.lower()
        assert (
            sql.execute(
                "SELECT COUNT(*) FROM dbo.SensorReadings WHERE DeviceId=?", f["SENSOR"]
            ).fetchval()
            == 0
        )
        assert (
            sql.execute(
                "SELECT COUNT(*) FROM dbo.Alerts WHERE ZoneId=?", f["zone"]
            ).fetchval()
            == 0
        )
    finally:
        sql.execute("ALTER TABLE dbo.Alerts DROP CONSTRAINT CK_AppHTTPFault")
    assert (
        ingest(server, test_config, "readings", reading(f, temperature=35)).status_code
        == 201
    )
