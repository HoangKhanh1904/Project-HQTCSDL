"""Run the database demo against the configured local Docker SQL Server."""

import argparse
import datetime as dt
import decimal
import hashlib
import json
import sys
import re
import threading
import time
import uuid
from pathlib import Path

sys.dont_write_bytecode = True
import pyodbc
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parent
TABLES = {
    "Users": "UserID", "SwiftletHouses": "HouseId", "Zones": "ZoneId",
    "Devices": "DeviceId", "SensorReadings": "ReadingId",
    "EnvironmentThresholds": "ThresholdsId", "Alerts": "AlertId",
    "AlertActions": "ActionId", "ControlLogs": "ControlLogId",
}


def serial(value):
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, (dt.datetime, dt.date, decimal.Decimal)):
        return str(value)
    raise TypeError(type(value).__name__)


def save(name, value):
    """Report to the terminal only; do not create evidence/artifacts in the repo."""
    if isinstance(value, dict) and value.get('status'):
        print(name.rsplit('.', 1)[0], value['status'], flush=True)


def connect(database="SwiftletCare"):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,100}", database):
        raise ValueError("Invalid database name")
    config = dotenv_values(ROOT.parent / ".env")
    password = config.get("MSSQL_SA_PASSWORD")
    if not password:
        raise RuntimeError("MSSQL_SA_PASSWORD is missing from configured .env")
    escaped = password.replace("}", "}}")
    conn = pyodbc.connect(
        "DRIVER={ODBC Driver 18 for SQL Server};SERVER=127.0.0.1,14330;"
        "DATABASE=" + database + ";UID=sa;PWD={" + escaped + "};"
        "Encrypt=yes;TrustServerCertificate=yes;APP=SwiftletCareDatabaseDemo;",
        timeout=8, autocommit=True,
    )
    conn.timeout = 60
    return conn


def execute(conn, sql, params=()):
    cursor = conn.cursor()
    result = []
    try:
        cursor.execute(sql, params)
        while True:
            if cursor.description:
                columns = [c[0] for c in cursor.description]
                result.append({
                    "columns": columns,
                    "types": [str(c[1]) for c in cursor.description],
                    "rows": [dict(zip(columns, row)) for row in cursor.fetchall()],
                })
            if not cursor.nextset():
                break
        return result
    except pyodbc.Error as error:
        error.partial_results = result
        raise
    finally:
        cursor.close()


def file_sql(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


def batches(sql):
    return [b for b in re.split(r"(?im)^\s*GO\s*$", sql) if b.strip()]


def run_file(conn, path, replacements=None):
    sql = file_sql(path)
    for before, after in (replacements or {}).items():
        if before not in sql:
            raise RuntimeError(f"Expected test option missing: {before}")
        sql = sql.replace(before, after, 1)
    result = []
    for batch in batches(sql):
        result.extend(execute(conn, batch))
    return result


def snapshot(conn):
    result = {}
    for table, pk in TABLES.items():
        exists = execute(conn, "SELECT OBJECT_ID(?, 'U') AS ObjectId", ("dbo." + table,))[0]["rows"][0]["ObjectId"]
        if exists is None:
            result[table] = {"count": 0, "missing": True, "hashes": {}}
            continue
        rows = execute(conn, f"SELECT * FROM dbo.[{table}] ORDER BY [{pk}]")[0]["rows"]
        hashes = {
            str(row[pk]): hashlib.sha256(json.dumps(
                {k:v for k,v in row.items() if not (k in (
                    "SourceEventId", "CO2Ppm", "LightLux", "ControlMode", "ExecutionKind"
                ) and v is None)},
                sort_keys=True, default=serial).encode()).hexdigest()
            for row in rows
        }
        result[table] = {"count": len(rows), "hashes": hashes}
    return result


def inspect(conn, label):
    inventory = {
        "environment": "SELECT @@VERSION AS Version, DB_NAME() AS DatabaseName, @@SPID AS SPID, SERVERPROPERTY('ProductVersion') AS ProductVersion, CONVERT(VARCHAR(40),SYSDATETIMEOFFSET(),127) AS ServerTime; SELECT name, is_read_committed_snapshot_on, recovery_model_desc FROM sys.databases WHERE name=DB_NAME();",
        "columns": "SELECT t.name AS TableName,c.name AS ColumnName,ty.name AS TypeName,c.max_length,c.precision,c.scale,c.is_nullable,c.is_identity FROM sys.tables t JOIN sys.columns c ON c.object_id=t.object_id JOIN sys.types ty ON ty.user_type_id=c.user_type_id ORDER BY t.name,c.column_id;",
        "constraints": "SELECT name,type_desc,OBJECT_NAME(parent_object_id) AS TableName FROM sys.objects WHERE type IN ('PK','UQ','F','C') ORDER BY type,name; SELECT name,is_disabled,is_not_trusted,definition FROM sys.check_constraints; SELECT name,is_disabled,is_not_trusted,OBJECT_NAME(parent_object_id) AS ParentTable,OBJECT_NAME(referenced_object_id) AS TargetTable FROM sys.foreign_keys;",
        "indexes": "SELECT OBJECT_NAME(object_id) AS TableName,name,type_desc,is_unique,is_disabled FROM sys.indexes WHERE object_id IN (SELECT object_id FROM sys.tables) AND index_id>0;",
        "procedures": "SELECT p.name,m.definition FROM sys.procedures p LEFT JOIN sys.sql_modules m ON m.object_id=p.object_id;",
        "permissions": "SELECT p.name AS Principal,p.type_desc,dp.state_desc,dp.permission_name,dp.class_desc,OBJECT_NAME(dp.major_id) AS ObjectName,dp.minor_id FROM sys.database_permissions dp JOIN sys.database_principals p ON p.principal_id=dp.grantee_principal_id; SELECT name,type_desc,authentication_type_desc FROM sys.database_principals WHERE principal_id>4; SELECT USER_NAME(role_principal_id) AS RoleName, USER_NAME(member_principal_id) AS MemberName FROM sys.database_role_members;",
        "triggers": "SELECT name,is_disabled,OBJECT_NAME(parent_id) AS TableName,OBJECT_DEFINITION(object_id) AS Definition FROM sys.triggers;",
        "data": "SELECT Status,COUNT_BIG(*) AS Total FROM dbo.Alerts GROUP BY Status; SELECT ZoneId,CONVERT(VARCHAR(16),CONVERT(BINARY(8),RowVer),2) AS RowVer FROM dbo.EnvironmentThresholds; SELECT COUNT_BIG(*) AS MismatchedAlertZones FROM dbo.Alerts a JOIN dbo.SensorReadings r ON a.ReadingId=r.ReadingId JOIN dbo.Devices d ON d.DeviceId=r.DeviceId WHERE a.ZoneId<>d.ZoneId OR d.DeviceType<>'SENSOR'; SELECT name FROM sys.tables WHERE name IN ('ConcurrencyDemoValue','ConcurrencyDemoItems');",
        "sessions": "SELECT session_id,status,open_transaction_count FROM sys.dm_exec_sessions WHERE is_user_process=1; SELECT session_id,blocking_session_id,status,wait_type FROM sys.dm_exec_requests WHERE database_id=DB_ID(); SELECT @@TRANCOUNT AS TranCount,XACT_STATE() AS XactState;",
    }
    output = {key: execute(conn, sql) for key, sql in inventory.items()}
    output["snapshot"] = snapshot(conn)
    output["time_vietnam"] = dt.datetime.now(dt.timezone(dt.timedelta(hours=7))).isoformat()
    save(label + ".json", output)
    print(json.dumps({"label": label, "environment": output["environment"], "counts": {t: s["count"] for t,s in output["snapshot"].items()}, "data": output["data"], "sessions": output["sessions"]}, default=serial))


def deploy(conn):
    backup = "/var/opt/mssql/data/SwiftletCare_before_demo_" + dt.datetime.now().strftime("%Y%m%d_%H%M%S") + ".bak"
    log = {"backup": backup, "steps": []}
    try:
        execute(conn, "BACKUP DATABASE SwiftletCare TO DISK=? WITH COPY_ONLY, CHECKSUM, COMPRESSION", (backup,))
        execute(conn, "RESTORE VERIFYONLY FROM DISK=? WITH CHECKSUM", (backup,))
        log["backup_verified"] = True
        save("deployment.json", log)
        paths = ["create_tables.sql", "alter_table.sql", "runtime_migration.sql", "application_extension.sql",
                 "concurrency/sp_acknowledge_alert.sql", "concurrency/sp_get_environment_threshold.sql",
                 "concurrency/sp_update_environment_threshold.sql", "procedures/sp_transition_alert.sql"]
        paths += [str(p.relative_to(ROOT)).replace("\\", "/") for p in sorted((ROOT / "procedures").glob("*.sql")) if p.name != "sp_transition_alert.sql"]
        paths += ["security.sql", "concurrency_tests.sql", "isolation_demos/setup.sql"]
        paths += [str(p.relative_to(ROOT)).replace("\\", "/") for p in sorted((ROOT / "isolation_demos").glob("0*.sql"))]
        for path in paths:
            result = run_file(conn, path)
            log["steps"].append({"file": path, "status": "PASS", "result": result})
            save("deployment.json", log)
            print("DEPLOY PASS", path, flush=True)
    except Exception as error:
        log["error"] = str(error)
        save("deployment.json", log)
        raise


def seed(conn):
    log = {"before": snapshot(conn), "runs": []}
    try:
        for i in range(2):
            run_file(conn, "seed_data.sql")
            log["runs"].append({"run": i + 1, "snapshot": snapshot(conn)})
        assert log["before"] == log["runs"][0]["snapshot"] == log["runs"][1]["snapshot"], "Seed modified existing data or added rows; inspect evidence"
        log["status"] = "PASS"
        print("SEED PASS: both runs preserved all rows and hashes")
    finally:
        save("seed.json", log)


def queries(conn):
    pieces = re.split(r"(?m)^-- (Q\d{2})\s*$", file_sql("queries.sql"))
    log = []
    for i in range(1, len(pieces), 2):
        name, sql = pieces[i:i + 2]
        try:
            results = execute(conn, sql)
            log.append({"query": name, "status": "PASS", "result": results})
            print(name, "PASS", [len(s["rows"]) for s in results])
        except Exception as error:
            log.append({"query": name, "status": "FAIL", "error": str(error)})
    save("queries.json", log)
    assert len(log) == 30 and all(x["status"] == "PASS" for x in log)


def regression(conn):
    log = {"before": snapshot(conn)}
    try:
        log["result"] = run_file(conn, "transaction.sql", {"DECLARE @RunTests BIT = 0;": "DECLARE @RunTests BIT = 1;"})
        log["after"] = snapshot(conn)
        assert log["before"] == log["after"], "Regression did not restore original rows"
        log["status"] = "PASS"
        print("REGRESSION PASS", [row["TestName"] for result in log["result"] for row in result["rows"] if row.get("TestResult") == "PASS"])
    except Exception as error:
        log["status"] = "FAIL"
        log["error"] = str(error)
        log["partial_result"] = getattr(error, "partial_results", [])
        log["transaction"] = execute(conn, "SELECT @@TRANCOUNT AS TranCount, XACT_STATE() AS XactState")
        raise
    finally:
        save("regression.json", log)


def mode_sql(mode, tag):
    return re.sub(r"(?im)^\s*GO\s*$", "", file_sql("concurrency/test_application_concurrency.sql")).replace("DECLARE @Mode VARCHAR(32) = 'HELP';", f"DECLARE @Mode VARCHAR(32) = '{mode}';").replace("DECLARE @RunTag NVARCHAR(24) = N'demo01';", f"DECLARE @RunTag NVARCHAR(24) = N'{tag}';")


def concurrency(conn):
    tag = "rt" + uuid.uuid4().hex[:16]
    log = {"tag": tag, "before": snapshot(conn), "pairs": []}
    setup_done = False
    try:
        log["setup"] = execute(conn, mode_sql("SETUP", tag))
        setup_done = True
        fixture = log["setup"][0]["rows"][0]
        log["initial_state"] = execute(conn, "SELECT a.AlertId,a.Status,(SELECT COUNT(*) FROM dbo.AlertActions aa WHERE aa.AlertId=a.AlertId) AS ActionCount FROM dbo.Alerts a WHERE AlertId=?", (fixture["AlertId"],))
        for prefix in ["ACK", "THRESHOLD"]:
            pair = {"name": prefix, "workers": {}, "blocking": []}
            log["pairs"].append(pair)
            ready = threading.Event()

            def worker(suffix):
                item = {"mode": prefix + "_" + suffix}
                pair["workers"][suffix] = item
                connection = None
                try:
                    connection = connect()
                    item["spid"] = execute(connection, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SELECT @@SPID AS SPID")[0]["rows"][0]["SPID"]
                    item["started"] = dt.datetime.now(dt.timezone.utc).isoformat()
                    if suffix == "B":
                        ready.set()
                    item["result"] = execute(connection, mode_sql(item["mode"], tag))
                    item["status"] = "PASS"
                except Exception as error:
                    item["status"] = "FAIL"
                    item["error"] = str(error)
                    ready.set()
                finally:
                    if connection is not None:
                        item["transaction"] = execute(connection, "SELECT @@TRANCOUNT AS TranCount, XACT_STATE() AS XactState; IF @@TRANCOUNT>0 ROLLBACK;")
                        connection.close()
                    item["ended"] = dt.datetime.now(dt.timezone.utc).isoformat()

            thread_b = threading.Thread(target=worker, args=("B",))
            thread_b.start()
            ready.wait(10)
            for _ in range(100):
                spid = pair["workers"]["B"].get("spid", -1)
                waits = execute(conn, "SELECT wait_type FROM sys.dm_exec_requests WHERE session_id=?", (spid,))[0]["rows"]
                if any(r["wait_type"] == "WAITFOR" for r in waits):
                    break
                if not thread_b.is_alive():
                    raise RuntimeError("Session B failed before waiting")
                time.sleep(0.05)
            else:
                thread_b.join()
                raise RuntimeError("Could not confirm session B reached WAITFOR")
            thread_a = threading.Thread(target=worker, args=("A",))
            thread_a.start()
            while thread_a.is_alive() or thread_b.is_alive():
                if prefix == "ACK":
                    rows = execute(conn, "SELECT session_id,blocking_session_id,wait_type FROM sys.dm_exec_requests WHERE session_id=? AND blocking_session_id>0", (spid,))[0]["rows"]
                    if rows:
                        pair["blocking"].append({"time": dt.datetime.now(dt.timezone.utc).isoformat(), "rows": rows})
                thread_a.join(0.2)
                thread_b.join(0.2)
            assert pair["workers"]["A"]["spid"] != pair["workers"]["B"]["spid"]
            assert all(w["status"] == "PASS" for w in pair["workers"].values()), pair
            pair["verification"] = execute(conn, mode_sql("VERIFY_" + prefix, tag))
            print("CONCURRENCY PASS", prefix, "SPIDs", pair["workers"]["A"]["spid"], pair["workers"]["B"]["spid"], flush=True)
        log["final_fixture"] = execute(conn, "SELECT Status,(SELECT COUNT(*) FROM dbo.AlertActions WHERE AlertId=?) AS ActionCount FROM dbo.Alerts WHERE AlertId=?; SELECT ZoneId,MinTemperature,MaxTemperature,MinHumidity,MaxHumidity,RowVer FROM dbo.EnvironmentThresholds WHERE ZoneId=?", (fixture["AlertId"], fixture["AlertId"], fixture["ZoneId"]))
        log["status"] = "PASS"
    except Exception as error:
        log["status"] = "FAIL"
        log["error"] = str(error)
        raise
    finally:
        if setup_done:
            log["cleanup"] = execute(conn, mode_sql("CLEANUP", tag))
        log["after"] = snapshot(conn)
        log["data_unchanged"] = log["before"] == log["after"]
        save("concurrency.json", log)
    assert log["data_unchanged"]


def supplement(conn):
    tag = "edge" + uuid.uuid4().hex[:14]
    log = {"before": snapshot(conn), "checks": []}
    fixture = None
    try:
        fixture = execute(conn, mode_sql("SETUP", tag))[0]["rows"][0]
        zone = fixture["ZoneId"]
        admin = fixture["AdminA"]
        alert = fixture["AlertId"]
        house = execute(conn, "SELECT HouseId FROM dbo.Zones WHERE ZoneId=?", (zone,))[0]["rows"][0]["HouseId"]
        sensor = execute(conn, "SELECT DeviceId FROM dbo.Devices WHERE ZoneId=?", (zone,))[0]["rows"][0]["DeviceId"]

        def check(name, sql, params, expected):
            result = execute(conn, sql, params)
            assert len(result) == 1 and len(result[0]["rows"]) == 1, name
            row = result[0]["rows"][0]
            assert row["Code"] == expected and row["Success"] == (expected == "OK"), (name, row)
            log["checks"].append({"name": name, "status": "PASS", "result": result})

        check("ACK_INVALID_ID", "EXEC dbo.sp_AcknowledgeAlert 0,?", (admin,), "VALIDATION_ERROR")
        check("ACK_UNKNOWN_USER", "EXEC dbo.sp_AcknowledgeAlert ?,2147483647", (alert,), "FORBIDDEN")
        check("GET_INVALID_ZONE", "EXEC dbo.sp_GetEnvironmentThreshold NULL", (), "VALIDATION_ERROR")
        check("GET_SUCCESS_TOKEN", "EXEC dbo.sp_GetEnvironmentThreshold ?", (zone,), "OK")
        row = log["checks"][-1]["result"][0]["rows"][0]
        assert len(row["RowVer"]) == 8 and row["ZoneId"] == zone

        execute(conn, "BEGIN TRANSACTION")
        try:
            result = execute(conn, "DECLARE @C VARCHAR(32); EXEC dbo.sp_AcknowledgeAlert ?,?,@ResultCode=@C OUTPUT; SELECT @C AS OutputCode,@@TRANCOUNT AS TranCount,XACT_STATE() AS XactState;", (alert, admin))
            assert result[-1]["rows"][0] == {"OutputCode": "OK", "TranCount": 1, "XactState": 1}
        finally:
            execute(conn, "IF @@TRANCOUNT>0 ROLLBACK")
        assert execute(conn, "SELECT Status FROM dbo.Alerts WHERE AlertId=?", (alert,))[0]["rows"][0]["Status"] == "PENDING"
        assert execute(conn, "SELECT COUNT(*) AS N FROM dbo.AlertActions WHERE AlertId=?", (alert,))[0]["rows"][0]["N"] == 0
        log["checks"].append({"name": "ACK_CALLER_ROLLBACK", "status": "PASS", "result": result})

        for principal in ["swiftlet_staff_demo", "swiftlet_admin_demo"]:
            for table in ["Alerts", "AlertActions", "EnvironmentThresholds"]:
                for operation in ["INSERT", "UPDATE", "DELETE"]:
                    result = execute(conn, f"EXECUTE AS USER='{principal}'; SELECT USER_NAME() AS Principal,IS_MEMBER('db_owner') AS IsDbOwner,HAS_PERMS_BY_NAME('dbo.{table}','OBJECT','{operation}') AS Allowed; REVERT;")
                    assert result[0]["rows"][0]["IsDbOwner"] == 0
                    assert result[0]["rows"][0]["Allowed"] == 0
                    log["checks"].append({"name": f"{principal}_{operation}_{table}", "status": "PASS", "result": result})
        result = execute(conn, "EXECUTE AS USER='swiftlet_staff_demo'; BEGIN TRY EXEC sys.sp_executesql N'INSERT dbo.AlertActions(AlertId,UserId,ActionType) SELECT 1,1,''ACKNOWLEDGE'' WHERE 1=0'; END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber; END CATCH; REVERT;")
        assert result[0]["rows"][0]["ErrorNumber"] == 229
        log["checks"].append({"name": "STAFF_DIRECT_INSERT_DENIED", "status": "PASS", "result": result})

        query_parts = re.split(r"(?m)^-- (Q\d{2})\s*$", file_sql("queries.sql"))
        sqls = dict(zip(query_parts[1::2], query_parts[2::2]))
        execute(conn, "BEGIN TRANSACTION")
        try:
            execute(conn, "INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity,RecordeAt) VALUES (?,28,80,'2020-01-01'),(?,29,80,'2020-01-02')", (sensor,sensor))
            sql = sqls["Q08"].replace("@DeviceId INT = 1", f"@DeviceId INT = {sensor}").replace("DATEADD(DAY, -7, SYSDATETIME())", "'2020-01-01'").replace("@EndTime DATETIME2 = SYSDATETIME()", "@EndTime DATETIME2 = '2020-01-02'")
            result = execute(conn, sql)
            assert len(result[0]["rows"]) == 1 and result[0]["rows"][0]["Temperature"] == 28
            log["checks"].append({"name": "Q08_START_INCLUDED_END_EXCLUDED", "status": "PASS", "result": result})

            expected = {zone: "WARNING"}
            execute(conn, "INSERT dbo.Devices(DeviceName,ZoneId,DeviceType) VALUES ('edge-missing',?,'SENSOR')", (zone,))
            for name, config, readings in [("UNCONFIGURED", False, []), ("NO_DATA", True, []), ("INCOMPLETE_DATA", True, [True,False]), ("NORMAL", True, [True])]:
                zid = execute(conn, "INSERT dbo.Zones(HouseId,ZoneName) OUTPUT inserted.ZoneId VALUES (?,?)", (house,name))[0]["rows"][0]["ZoneId"]
                expected[zid] = name
                if config:
                    execute(conn, "INSERT dbo.EnvironmentThresholds(ZoneId,MinTemperature,MaxTemperature,MinHumidity,MaxHumidity) VALUES (?,26,32,70,90)", (zid,))
                for index, has_reading in enumerate(readings):
                    did = execute(conn, "INSERT dbo.Devices(DeviceName,ZoneId,DeviceType) OUTPUT inserted.DeviceId VALUES (?,?, 'SENSOR')", (f"edge-{index}",zid))[0]["rows"][0]["DeviceId"]
                    if has_reading:
                        execute(conn, "INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity,RecordeAt) VALUES (?,35,80,'2020-01-01'),(?,28,80,SYSDATETIME())", (did,did))
            result = execute(conn, sqls["Q30"])
            relevant = [r for r in result[0]["rows"] if r["ZoneId"] in expected]
            assert len(relevant) == 5
            for row in relevant:
                assert row["EnvironmentStatus"] == expected[row["ZoneId"]], row
                if row["EnvironmentStatus"] in ["NORMAL", "INCOMPLETE_DATA"]:
                    assert row["AvgTemperature"] == 28 and row["ReadingSensorCount"] == 1
            log["checks"].append({"name": "Q30_FIVE_STATES_AND_LATEST_READING", "status": "PASS", "rows": relevant})

            second = next(z for z,s in expected.items() if s == "NORMAL")
            other_reading = execute(conn, "SELECT r.ReadingId FROM dbo.SensorReadings r JOIN dbo.Devices d ON d.DeviceId=r.DeviceId WHERE d.ZoneId=?", (second,))[0]["rows"][0]["ReadingId"]
            first_reading = execute(conn, "SELECT ReadingId FROM dbo.Alerts WHERE AlertId=?", (alert,))[0]["rows"][0]["ReadingId"]
            maximum = execute(conn, "SELECT MAX(N) AS N FROM (SELECT COUNT(*) AS N FROM dbo.Alerts GROUP BY ZoneId) c")[0]["rows"][0]["N"] + 2
            for zid,rid in [(zone,first_reading),(second,other_reading)]:
                existing = execute(conn, "SELECT COUNT(*) AS N FROM dbo.Alerts WHERE ZoneId=?", (zid,))[0]["rows"][0]["N"]
                for _ in range(maximum-existing):
                    execute(conn, "INSERT dbo.Alerts(ZoneId,ReadingId,AlertType,Message) VALUES (?,?,'HIGH_TEMP','edge-tie')", (zid,rid))
            result = execute(conn, sqls["Q19"])
            assert {r["ZoneId"] for r in result[0]["rows"]} == {zone, second}
            assert all(r["TotalAlerts"] == maximum for r in result[0]["rows"])
            log["checks"].append({"name": "Q19_WITH_TIES", "status": "PASS", "result": result})
        finally:
            execute(conn, "IF @@TRANCOUNT>0 ROLLBACK")
        log["status"] = "PASS"
    except Exception as error:
        log["status"] = "FAIL"
        log["error"] = str(error)
        raise
    finally:
        execute(conn, "REVERT; IF @@TRANCOUNT>0 ROLLBACK")
        if fixture:
            log["cleanup"] = execute(conn, mode_sql("CLEANUP", tag))
        log["after"] = snapshot(conn)
        log["data_unchanged"] = log["before"] == log["after"]
        save("supplement.json", log)
    assert log["data_unchanged"]
    print("SUPPLEMENT PASS", len(log["checks"]), "checks; original data unchanged")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=["before", "after", "deploy", "seed", "queries", "regression", "concurrency", "supplement"])
    args = parser.parse_args()
    with connect() as conn:
        if args.stage in ["before", "after"]:
            inspect(conn, args.stage)
        else:
            globals()[args.stage](conn)


if __name__ == "__main__":
    main()
