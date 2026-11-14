"""Application compatibility and SQL Server regression checks."""

import concurrent.futures
import re
import subprocess
import uuid

import pytest

from tools.prepare_application_tests import ROOT, deploy, execute
from test_application_integration import ingest, reading

pytestmark = pytest.mark.integration


def run_script(conn, path, database):
    assert re.fullmatch(r"SwiftletCare_AppTest_[a-f0-9]+", database)
    sql = (
        (ROOT / path)
        .read_text(encoding="utf-8-sig")
        .replace("USE SwiftletCare;", f"USE [{database}];")
    )
    for batch in re.split(r"^\s*GO\s*$", sql, flags=re.M | re.I):
        if batch.strip():
            execute(conn, batch)


def test_analytics_and_sql_qa_on_real_server(sql, test_config):
    run_script(sql, "scripts/analytics_qa.sql", test_config["database"])
    run_script(sql, "scripts/qa_tests.sql", test_config["database"])
    assert (
        sql.execute("SELECT dbo.fn_KiemTraMoiTruong(NULL,80)").fetchval()
        == "Chưa có dữ liệu"
    )


def test_upgrade_legacy_twice_preserves_data_and_fifth_output(sql, test_config):
    name = "SwiftletCare_AppTest_" + uuid.uuid4().hex[:12]
    execute(sql, f"CREATE DATABASE [{name}]")
    paths = ["create_tables.sql", "alter_table.sql", "runtime_migration.sql"]
    try:
        # Deploy actual old files from the immutable review baseline, not an imitation.
        for path in paths:
            source = subprocess.check_output(
                [
                    "git",
                    "show",
                    "55169565892694b79242b074f6d699cfb8dd9c67:database/" + path,
                ],
                cwd=ROOT,
            ).decode("utf-8-sig")
            for batch in re.split(
                r"^\s*GO\s*$",
                source.replace("USE SwiftletCare;", f"USE [{name}];"),
                flags=re.M | re.I,
            ):
                if batch.strip():
                    execute(sql, batch)
        execute(
            sql,
            "INSERT dbo.Users(UserName,PasswordHash,FullName,Role) VALUES ('legacy','TEST',N'Legacy','ADMIN'); INSERT dbo.SwiftletHouses(HouseName,ManagerId) VALUES (N'Legacy',1); INSERT dbo.Zones(HouseId,ZoneName) VALUES (1,N'Legacy'); INSERT dbo.Devices(ZoneId,DeviceName,DeviceType) VALUES (1,N'Legacy','SENSOR'); INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity) VALUES (1,29,80);",
        )
        before = tuple(
            sql.execute(
                "SELECT ReadingId,DeviceId,Temperature,Humidity,RecordeAt FROM dbo.SensorReadings"
            ).fetchone()
        )
        deploy(sql, name)
        deploy(sql, name)
        assert (
            tuple(
                sql.execute(
                    "SELECT ReadingId,DeviceId,Temperature,Humidity,RecordeAt FROM dbo.SensorReadings WHERE ReadingId=1"
                ).fetchone()
            )
            == before
        )
        result = execute(
            sql,
            "DECLARE @C VARCHAR(32); EXEC dbo.sp_InsertSensorReading 1,29,80,NULL,@C OUTPUT; SELECT @C AS Code;",
        )
        assert result[-1][0]["Code"] == "OK"
        assert (
            sql.execute(
                "SELECT CO2Ppm,LightLux FROM dbo.SensorReadings WHERE ReadingId=1"
            ).fetchone()[0]
            is None
        )
    finally:
        execute(sql, f"USE [{test_config['database']}]")


def test_backup_restore_and_read_procedure(sql, test_config):
    name = "SwiftletCare_AppTest_" + uuid.uuid4().hex[:12]
    original = test_config["database"]
    backup = "/var/opt/mssql/data/" + name + ".bak"
    before = sql.execute("SELECT COUNT_BIG(*) FROM dbo.SensorReadings").fetchval()
    execute(
        sql,
        f"BACKUP DATABASE [{original}] TO DISK=? WITH COPY_ONLY,CHECKSUM,COMPRESSION",
        [backup],
    )
    execute(sql, "RESTORE VERIFYONLY FROM DISK=? WITH CHECKSUM", [backup])
    files = execute(sql, "RESTORE FILELISTONLY FROM DISK=?", [backup])[0]
    moves = []
    params = [backup]
    for i, file in enumerate(files):
        moves.append("MOVE ? TO ?")
        params += [file["LogicalName"], f"/var/opt/mssql/data/{name}_{i}.dat"]
    execute(
        sql, f"RESTORE DATABASE [{name}] FROM DISK=? WITH " + ",".join(moves), params
    )
    try:
        execute(sql, f"USE [{name}]")
        assert (
            sql.execute("SELECT COUNT_BIG(*) FROM dbo.SensorReadings").fetchval()
            == before
        )
        execute(sql, "EXEC dbo.sp_GetZoneDashboard")
    finally:
        execute(sql, f"USE [{original}]")


def test_fault_rolls_back_control_and_audit(sql, client, fixture_data):
    f = fixture_data
    client.data(
        "POST", f"/controls/{f['FAN']}", json={"action": "MANUAL", "is_on": False}
    )
    before = sql.execute(
        "SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?", f["FAN"]
    ).fetchval()
    result = execute(
        sql,
        f"""BEGIN TRY
        BEGIN TRANSACTION;
        ALTER TABLE dbo.ControlLogs WITH NOCHECK ADD CONSTRAINT CK_AppTestFault CHECK(DeviceId<>{f["FAN"]});
        EXEC dbo.sp_SimulateDeviceControl ?,?,'MANUAL',@IsOn=1;
        SELECT XACT_STATE() AS S;
        ROLLBACK;
        END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH;""",
        [f["FAN"], f["manager"]],
    )
    assert result[0][0]["Code"] == "SYSTEM_ERROR" and result[0][0]["ErrorNumber"] == 547
    assert result[1][0]["S"] == -1
    assert not sql.execute(
        "SELECT IsOn FROM dbo.DeviceControlSettings WHERE DeviceId=?", f["FAN"]
    ).fetchval()
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?", f["FAN"]
        ).fetchval()
        == before
    )
    assert sql.execute("SELECT @@TRANCOUNT").fetchval() == 0


def test_manual_lock_wins_against_http_auto(
    sql, client, fixture_data, server, test_config
):
    f = fixture_data
    rid = ingest(server, test_config, "readings", reading(f, temperature=35)).json()[
        "data"
    ]["ReadingId"]
    client.data(
        "POST", f"/controls/{f['FAN']}", json={"action": "SET_MODE", "mode": "AUTO"}
    )
    sql.autocommit = False
    execute(
        sql,
        "EXEC dbo.sp_SimulateDeviceControl ?,?,'MANUAL',@IsOn=0;",
        [f["FAN"], f["manager"]],
    )
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(
                client.request,
                "POST",
                f"/controls/{f['FAN']}",
                json={"action": "AUTO", "reading_id": str(rid)},
            )
            # A separate observer can prove the HTTP connection is blocked on our lock.
            import pyodbc
            import time

            c = test_config
            observer = pyodbc.connect(
                f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER=127.0.0.1,{c['port']};DATABASE={c['database']};UID=sa;PWD={c['sa_password']};Encrypt=yes;TrustServerCertificate=yes;",
                autocommit=True,
            )
            try:
                spid = sql.execute("SELECT @@SPID").fetchval()
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if observer.execute(
                        "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE blocking_session_id=?",
                        spid,
                    ).fetchval():
                        break
                    time.sleep(0.05)
                else:
                    raise AssertionError(
                        "HTTP worker did not reach the expected SQL lock"
                    )
            finally:
                observer.close()
                sql.commit()
            result = future.result(timeout=12)
        assert result.status_code == 409 and result.json()["code"] == "MANUAL_OVERRIDE"
        assert tuple(
            sql.execute(
                "SELECT ControlMode,IsOn FROM dbo.DeviceControlSettings WHERE DeviceId=?",
                f["FAN"],
            ).fetchone()
        ) == ("MANUAL", False)
    finally:
        sql.rollback()
        sql.autocommit = True


def test_known_database_mode_only_audit(sql, client, fixture_data):
    f = fixture_data
    path = f"/controls/{f['FAN']}"
    client.data("POST", path, json={"action": "MANUAL", "is_on": False})
    before = sql.execute(
        "SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?", f["FAN"]
    ).fetchval()
    client.data("POST", path, json={"action": "SET_MODE", "mode": "AUTO"})
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?", f["FAN"]
        ).fetchval()
        == before
    )


@pytest.mark.parametrize("kind", ["FAN", "HUMIDIFIER", "LIGHT"])
@pytest.mark.parametrize("is_on", [False, True])
def test_mode_and_state_changes_are_independent(sql, client, fixture_data, kind, is_on):
    device = fixture_data[kind]
    path = f"/controls/{device}"
    initial = client.data("POST", path, json={"action": "MANUAL", "is_on": is_on})
    assert initial["StateChanged"] == is_on
    assert (initial["ControlLogId"] is not None) == is_on
    before = sql.execute(
        "SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?", device
    ).fetchval()
    for mode in ("AUTO", "MANUAL"):
        result = client.data("POST", path, json={"action": "SET_MODE", "mode": mode})
        assert result["IsOn"] == is_on
        assert result["Changed"] is True and result["ModeChanged"] is True
        assert result["StateChanged"] is False and result["ControlLogId"] is None
        stamp = sql.execute(
            "SELECT UpdatedAt FROM dbo.DeviceControlSettings WHERE DeviceId=?", device
        ).fetchval()
        repeat = client.data("POST", path, json={"action": "SET_MODE", "mode": mode})
        assert repeat["ExecutionStatus"] == "NO_CHANGE" and repeat["Changed"] is False
        assert repeat["ModeChanged"] is False and repeat["StateChanged"] is False
        assert (
            sql.execute(
                "SELECT UpdatedAt FROM dbo.DeviceControlSettings WHERE DeviceId=?",
                device,
            ).fetchval()
            == stamp
        )
    same = client.data("POST", path, json={"action": "MANUAL", "is_on": is_on})
    assert same["ExecutionStatus"] == "NO_CHANGE"
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?", device
        ).fetchval()
        == before
    )
    changed = client.data("POST", path, json={"action": "MANUAL", "is_on": not is_on})
    assert changed["StateChanged"] is True and changed["ModeChanged"] is False
    assert (
        sql.execute(
            "SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?", device
        ).fetchval()
        == before + 1
    )
    command = sql.execute(
        "SELECT Command FROM dbo.ControlLogs WHERE ControlLogId=?",
        changed["ControlLogId"],
    ).fetchval()
    assert command == ("TURN_OFF" if is_on else "TURN_ON")
