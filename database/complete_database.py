"""Deploy and verify the database completion without changing application files."""
import argparse
import datetime as dt
import sys
import threading
import time
import uuid

sys.dont_write_bytecode = True
import run_database_demo as d

DEPLOY_FILES = [
    "create_tables.sql", "alter_table.sql", "runtime_migration.sql", "application_extension.sql",
    "concurrency/sp_acknowledge_alert.sql", "concurrency/sp_get_environment_threshold.sql",
    "concurrency/sp_update_environment_threshold.sql", "procedures/sp_insert_sensor_reading.sql",
    "procedures/sp_transition_alert.sql", "procedures/sp_resolve_alert.sql", "procedures/sp_reopen_alert.sql",
    "procedures/sp_create_environment_threshold.sql", "procedures/sp_get_latest_sensor_readings.sql",
    "procedures/sp_get_sensor_history.sql", "procedures/sp_get_unresolved_alerts.sql",
    "procedures/sp_get_zone_dashboard.sql", "procedures/sp_bird_movements.sql",
    "procedures/sp_get_environment_metrics.sql", "procedures/sp_simulated_system_events.sql",
    "procedures/sp_simulate_device_control.sql", "security.sql", "isolation_demos/setup.sql",
    "isolation_demos/01_dirty_read.sql", "isolation_demos/02_nonrepeatable_read.sql",
    "isolation_demos/03_phantom_read.sql", "isolation_demos/04_lost_update.sql",
]


def run_file(conn, path, database="SwiftletCare"):
    result = []
    for batch in d.batches(d.file_sql(path).replace("USE SwiftletCare;", f"USE [{database}];")):
        result.extend(d.execute(conn, batch))
    return result


def rows(conn, sql, params=()):
    return d.execute(conn, sql, params)[0]["rows"]


def check(condition, label):
    if not condition:
        raise AssertionError(label)


def deploy(conn, database="SwiftletCare", backup=True):
    log = {"database": database, "steps": []}
    name = "deployment" if backup else "fresh_deployment"
    try:
        if backup:
            path = "/var/opt/mssql/data/SwiftletCare_completion_" + uuid.uuid4().hex[:12] + ".bak"
            d.execute(conn, "BACKUP DATABASE SwiftletCare TO DISK=? WITH COPY_ONLY,CHECKSUM,COMPRESSION", (path,))
            d.execute(conn, "RESTORE VERIFYONLY FROM DISK=? WITH CHECKSUM", (path,))
            log.update(backup=path, backup_verified=True)
        for path in DEPLOY_FILES:
            run_file(conn, path, database)
            log["steps"].append({"file": path, "status": "PASS"})
            d.save(name + ".json", log)
        log["status"] = "PASS"
        print("DEPLOY PASS", database, len(log["steps"]), flush=True)
    except Exception as error:
        log.update(status="FAIL", error=str(error))
        raise
    finally:
        d.save(name + ".json", log)


def pair(observer, first_sql, second_sql, first_params=(), second_params=(), wait_first=True):
    output = {"workers": {}, "blocking": []}
    ready = threading.Event()

    def worker(name, sql, params):
        connection = None
        item = output["workers"][name] = {}
        try:
            connection = d.connect(observer.getinfo(d.pyodbc.SQL_DATABASE_NAME))
            item["spid"] = rows(connection, "SELECT @@SPID AS SPID")[0]["SPID"]
            item["started"] = dt.datetime.now(dt.timezone.utc).isoformat()
            if name == "T1":
                ready.set()
            item["result"] = d.execute(connection, sql, params)
            item["status"] = "PASS"
        except Exception as error:
            item.update(status="FAIL", error=str(error))
            ready.set()
        finally:
            if connection is not None:
                item["transaction"] = d.execute(connection, "SELECT @@TRANCOUNT AS TranCount,XACT_STATE() AS XactState; IF @@TRANCOUNT>0 ROLLBACK;")
                connection.close()
            item["ended"] = dt.datetime.now(dt.timezone.utc).isoformat()

    t1 = threading.Thread(target=worker, args=("T1", first_sql, first_params))
    t1.start()
    ready.wait(10)
    if wait_first:
        for _ in range(150):
            spid = output["workers"]["T1"].get("spid", -1)
            wait = rows(observer, "SELECT wait_type FROM sys.dm_exec_requests WHERE session_id=?", (spid,))
            if any(row["wait_type"] == "WAITFOR" for row in wait):
                break
            if not t1.is_alive():
                raise RuntimeError("T1 ended before reaching its synchronization point: " + str(output))
            time.sleep(0.02)
        else:
            t1.join()
            raise RuntimeError("T1 did not reach WAITFOR")
    t2 = threading.Thread(target=worker, args=("T2", second_sql, second_params))
    t2.start()
    while t1.is_alive() or t2.is_alive():
        blocking = rows(observer, "SELECT session_id,blocking_session_id,wait_type FROM sys.dm_exec_requests WHERE session_id IN (?,?) AND blocking_session_id>0", tuple(output["workers"].get(n, {}).get("spid", -1) for n in ["T1", "T2"]))
        if blocking:
            output["blocking"].append({"time": dt.datetime.now(dt.timezone.utc).isoformat(), "rows": blocking})
        t1.join(0.1)
        t2.join(0.1)
    check(all(w["status"] == "PASS" for w in output["workers"].values()), output)
    check(output["workers"]["T1"]["spid"] != output["workers"]["T2"]["spid"], "Sessions must be independent")
    check(all(w["transaction"][0]["rows"][0] == {"TranCount": 0, "XactState": 0} for w in output["workers"].values()), "Open transaction after test")
    return output


def isolation(conn):
    cases = [
        ("dirty_read", "sp_dirty_read_error_T1", "sp_dirty_read_error_T2"),
        ("nonrepeatable_read", "sp_unrepeatable_read_T1", "sp_unrepeatable_read_T2"),
        ("phantom_read", "sp_phantom_error_T1", "sp_phantom_error_T2"),
        ("lost_update", "sp_chuyentien1", "sp_chuyentien2"),
    ]
    log = {"runs": [], "before": d.snapshot(conn)}
    try:
        check(not rows(conn, "SELECT is_read_committed_snapshot_on AS V FROM sys.databases WHERE database_id=DB_ID()")[0]["V"], "These lock demonstrations require RCSI OFF")
        for kind, t1, t2 in cases:
            for fix in [0, 1]:
                tag = "iso" + uuid.uuid4().hex[:16]
                d.execute(conn, "EXEC sc_isolation.sp_Fixture ?,'SETUP'", (tag,))
                item = {"phenomenon": kind, "fix": fix, "tag": tag}
                log["runs"].append(item)
                try:
                    item["pair"] = pair(conn, f"EXEC sc_isolation.{t1} ?,?", f"EXEC sc_isolation.{t2} ?,?", (tag,fix), (tag,fix))
                    first = item["pair"]["workers"]["T1"]["result"][0]["rows"][0]
                    second = item["pair"]["workers"]["T2"]["result"][0]["rows"][0]
                    item["final"] = rows(conn, "SELECT matk,sotien FROM sc_isolation.TaiKhoan WHERE RunTag=? ORDER BY matk", (tag,))
                    if kind == "dirty_read":
                        check(second["FirstValue"] == (1000 if fix else 9999) and second["SecondValue"] == 1000, item)
                    elif kind == "nonrepeatable_read":
                        check(first["FirstValue"] == 1000 and first["SecondValue"] == (1000 if fix else 1100), item)
                    elif kind == "phantom_read":
                        check(first["FirstValue"] == 1 and first["SecondValue"] == (1 if fix else 2), item)
                    else:
                        check(item["final"][0]["sotien"] == (700 if fix else 900) and item["final"][1]["sotien"] == 2300, item)
                    if fix:
                        check(item["pair"]["blocking"], "Expected blocking was not observed")
                    item["status"] = "PASS"
                    print("ISOLATION PASS", kind, "FIX" if fix else "ERROR", flush=True)
                finally:
                    item["cleanup"] = d.execute(conn, "EXEC sc_isolation.sp_Fixture ?,'CLEANUP'", (tag,))
                    d.save("isolation.json", log)
        log["after"] = d.snapshot(conn)
        check(log["before"] == log["after"], "Business data changed during isolation demos")
        log["status"] = "PASS"
    except Exception as error:
        log.update(status="FAIL", error=str(error))
        raise
    finally:
        d.save("isolation.json", log)


def runtime(conn, fault_injection=False):
    tag = "new" + uuid.uuid4().hex[:16]
    database = conn.getinfo(d.pyodbc.SQL_DATABASE_NAME)
    mode = lambda value: d.mode_sql(value, tag).replace("USE SwiftletCare;", f"USE [{database}];")
    log = {"database": database, "before": d.snapshot(conn), "checks": []}
    fixture = None

    def call(name, sql, params=(), expected="OK"):
        result = d.execute(conn, sql, params)
        check(len(result) == 1 and len(result[0]["rows"]) == 1, name)
        row = result[0]["rows"][0]
        check(row["Code"] == expected and row["Success"] == (expected == "OK"), (name,row))
        log["checks"].append({"name": name, "status": "PASS", "result": result})
        return row

    def sensor(name, device, temp, humidity, event=None, expected="OK"):
        return call(name, "EXEC dbo.sp_InsertSensorReading ?,?,?,?", (device,temp,humidity,event), expected)

    try:
        fixture = d.execute(conn, mode("SETUP"))[0]["rows"][0]
        zone, admin, staff, alert = [fixture[k] for k in ["ZoneId","AdminA","StaffA","AlertId"]]
        device = rows(conn, "SELECT DeviceId FROM dbo.Devices WHERE ZoneId=?", (zone,))[0]["DeviceId"]
        call("resolve_pending_rejected", "EXEC dbo.sp_ResolveAlert ?,?", (alert,staff), "INVALID_STATE")
        call("reopen_pending_rejected", "EXEC dbo.sp_ReopenAlert ?,?", (alert,staff), "INVALID_STATE")
        call("ack_initial", "EXEC dbo.sp_AcknowledgeAlert ?,?", (alert,staff))
        call("resolve_initial", "EXEC dbo.sp_ResolveAlert ?,?", (alert,staff))
        call("resolve_duplicate", "EXEC dbo.sp_ResolveAlert ?,?", (alert,staff), "INVALID_STATE")
        normal = sensor("normal",device,28,80,str(uuid.uuid4()))
        check(normal["AlertCount"] == 0 and normal["ThresholdStatus"] == "CONFIGURED", normal)
        boundary = sensor("inclusive_boundary",device,32,90)
        check(boundary["AlertCount"] == 0, boundary)
        event = str(uuid.uuid4())
        bad = sensor("high_temperature_and_humidity",device,35,95,event)
        check(bad["AlertCount"] == 2, bad)
        violations = rows(conn, "SELECT a.AlertType,a.ZoneId,d.ZoneId AS DeviceZone FROM dbo.Alerts a JOIN dbo.SensorReadings r ON r.ReadingId=a.ReadingId JOIN dbo.Devices d ON d.DeviceId=r.DeviceId WHERE a.ReadingId=?", (bad["ReadingId"],))
        check({r["AlertType"] for r in violations} == {"HIGH_TEMP","HIGH_HUMIDITY"} and all(r["ZoneId"] == r["DeviceZone"] == zone for r in violations), violations)
        check(sensor("suppress_open_incident",device,36,96)["AlertCount"] == 0, "Repeated violation created duplicate incidents")
        replay = sensor("retry_same_event",device,35,95,event)
        check(replay["ReadingId"] == bad["ReadingId"] and replay["Duplicate"] and replay["AlertCount"]==0, replay)
        sensor("retry_conflicting_payload",device,34,95,event,"IDEMPOTENCY_CONFLICT")
        call("reopen_open_incident_rejected", "EXEC dbo.sp_ReopenAlert ?,?", (alert,staff), "OPEN_ALERT_EXISTS")
        for name, args in [
            ("invalid_device",(0,28,80,"VALIDATION_ERROR")),
            ("missing_device",(2147483647,28,80,"DEVICE_NOT_FOUND")),
            ("null_temperature",(device,None,80,"VALIDATION_ERROR")),
            ("invalid_temperature",(device,101,80,"VALIDATION_ERROR")),
            ("invalid_humidity",(device,28,-1,"VALIDATION_ERROR")),
        ]:
            sensor(name,*args[:3],expected=args[3])
        for field,value,code in [("Status","INACTIVE","DEVICE_UNAVAILABLE"),("Status","MAINTENANCE","DEVICE_UNAVAILABLE"),("DeviceType","FAN","DEVICE_UNAVAILABLE")]:
            d.execute(conn,"BEGIN TRANSACTION")
            try:
                d.execute(conn,f"UPDATE dbo.Devices SET {field}=? WHERE DeviceId=?",(value,device))
                sensor("reject_"+value,device,28,80,expected=code)
                check(rows(conn,"SELECT @@TRANCOUNT AS N,XACT_STATE() AS S")[0] == {"N":1,"S":1},"Validation damaged ambient transaction")
            finally:
                d.execute(conn,"IF @@TRANCOUNT>0 ROLLBACK")
        d.execute(conn,"BEGIN TRANSACTION")
        try:
            d.execute(conn,"UPDATE dbo.Zones SET Status='INACTIVE' WHERE ZoneId=?",(zone,))
            sensor("inactive_zone",device,28,80,expected="ZONE_UNAVAILABLE")
        finally:
            d.execute(conn,"IF @@TRANCOUNT>0 ROLLBACK")

        d.execute(conn,"BEGIN TRANSACTION")
        try:
            d.execute(conn,"DELETE dbo.EnvironmentThresholds WHERE ZoneId=?",(zone,))
            unc = sensor("unconfigured_zone",device,35,95,str(uuid.uuid4()))
            check(unc["ThresholdStatus"] == "UNCONFIGURED" and unc["AlertCount"] == 0,unc)
            call("create_forbidden_staff_user","EXEC dbo.sp_CreateEnvironmentThreshold ?,26,32,70,90,?",(zone,staff),"FORBIDDEN")
            created = call("create_threshold","EXEC dbo.sp_CreateEnvironmentThreshold ?,26,32,70,90,?",(zone,admin))
            check(len(created["RowVer"]) == 8,created)
            call("create_duplicate","EXEC dbo.sp_CreateEnvironmentThreshold ?,26,32,70,90,?",(zone,admin),"THRESHOLD_EXISTS")
        finally:
            d.execute(conn,"IF @@TRANCOUNT>0 ROLLBACK")
        call("create_invalid_range","EXEC dbo.sp_CreateEnvironmentThreshold ?,34,32,70,90,?",(zone,admin),"VALIDATION_ERROR")
        call("create_missing_zone","EXEC dbo.sp_CreateEnvironmentThreshold 2147483647,26,32,70,90,?",(admin,),"ZONE_NOT_FOUND")
        for procedure in ["sp_ResolveAlert","sp_ReopenAlert"]:
            call(procedure+"_invalid",f"EXEC dbo.{procedure} 0,?",(staff,),"VALIDATION_ERROR")
            call(procedure+"_missing",f"EXEC dbo.{procedure} 9223372036854775807,?",(staff,),"ALERT_NOT_FOUND")
            call(procedure+"_unknown_user",f"EXEC dbo.{procedure} ?,2147483647",(alert,),"FORBIDDEN")
        d.execute(conn,"BEGIN TRANSACTION")
        try:
            d.execute(conn,"UPDATE dbo.Users SET IsActive=0 WHERE UserID=?",(staff,))
            call("resolve_inactive_user","EXEC dbo.sp_ResolveAlert ?,?",(alert,staff),"FORBIDDEN")
        finally:
            d.execute(conn,"IF @@TRANCOUNT>0 ROLLBACK")

        before = rows(conn,"SELECT COUNT(*) AS N FROM dbo.SensorReadings WHERE DeviceId=?",(device,))[0]["N"]
        d.execute(conn,"BEGIN TRANSACTION")
        try:
            sensor("caller_ingest",device,28,80,str(uuid.uuid4()))
            check(rows(conn,"SELECT @@TRANCOUNT AS N,XACT_STATE() AS S")[0] == {"N":1,"S":1},"Ingest committed caller transaction")
        finally:
            d.execute(conn,"IF @@TRANCOUNT>0 ROLLBACK")
        check(rows(conn,"SELECT COUNT(*) AS N FROM dbo.SensorReadings WHERE DeviceId=?",(device,))[0]["N"] == before,"Caller rollback failed")

        d.execute(conn,"BEGIN TRANSACTION")
        try:
            d.execute(conn,"DELETE dbo.EnvironmentThresholds WHERE ZoneId=?",(zone,))
            d.execute(conn,"EXECUTE AS USER='swiftlet_admin_demo'")
            call("create_as_sql_admin","EXEC dbo.sp_CreateEnvironmentThreshold ?,26,32,70,90,?",(zone,admin))
        finally:
            d.execute(conn,"REVERT; IF @@TRANCOUNT>0 ROLLBACK")

        for principal in ["swiftlet_staff_demo","swiftlet_admin_demo","swiftlet_ingest_demo"]:
            d.execute(conn,f"EXECUTE AS USER='{principal}'")
            try:
                check(rows(conn,"SELECT IS_MEMBER('db_owner') AS N")[0]["N"] == 0,"Privilege test ran as owner")
                if principal != "swiftlet_staff_demo":
                    sensor("ingest_as_"+principal,device,28,80,str(uuid.uuid4()))
                if principal != "swiftlet_ingest_demo":
                    role_alert=rows(conn,"SELECT AlertId FROM dbo.Alerts WHERE ZoneId=? AND AlertType='HIGH_HUMIDITY' AND Status='PENDING'",(zone,))[0]["AlertId"]
                    for procedure in ["sp_AcknowledgeAlert","sp_ResolveAlert","sp_ReopenAlert"]:
                        call(principal+"_"+procedure,f"EXEC dbo.{procedure} ?,?",(role_alert,staff if principal=='swiftlet_staff_demo' else admin))
                    for procedure in ["sp_GetLatestSensorReadings","sp_GetZoneDashboard","sp_GetUnresolvedAlerts"]:
                        result=d.execute(conn,f"EXEC dbo.{procedure} ?",(zone,))
                        check(result,"Dashboard result missing")
                        log["checks"].append({"name":principal+"_"+procedure,"status":"PASS","row_count":len(result[0]["rows"])})
                    history=d.execute(conn,"EXEC dbo.sp_GetSensorHistory ?, '2020-01-01','2100-01-01',1000",(device,))
                    check(history[0]["rows"],"History missing")
                for table in ["SensorReadings","Alerts","AlertActions","EnvironmentThresholds"]:
                    for perm in ["INSERT","UPDATE","DELETE"]:
                        check(rows(conn,"SELECT HAS_PERMS_BY_NAME(?,'OBJECT',?) AS V",("dbo."+table,perm))[0]["V"] == 0,(principal,table,perm))
                denied = ["sp_InsertSensorReading"] if principal == "swiftlet_staff_demo" else ["sp_ResolveAlert"] if principal == "swiftlet_ingest_demo" else []
                for procedure in denied:
                    try:
                        d.execute(conn,f"EXEC dbo.{procedure} NULL,NULL"+(",NULL" if procedure=="sp_InsertSensorReading" else ""))
                        raise AssertionError("Expected SQL EXECUTE denial")
                    except d.pyodbc.Error as error:
                        check("(229)" in str(error),str(error))
                        log["checks"].append({"name":principal+"_denied_"+procedure,"status":"PASS","sql_error":229})
            finally:
                d.execute(conn,"REVERT; IF @@TRANCOUNT>0 ROLLBACK")

        for procedure,expected_status in [("sp_ResolveAlert","RESOLVED"),("sp_ReopenAlert","PENDING")]:
            live = rows(conn,"SELECT TOP(1) AlertId FROM dbo.Alerts WHERE ZoneId=? AND Status='PENDING' ORDER BY AlertId",(zone,))
            if procedure=="sp_ResolveAlert":
                transition_alert=live[0]["AlertId"]
                call("ack_for_resolve_race","EXEC dbo.sp_AcknowledgeAlert ?,?",(transition_alert,staff))
            result=pair(conn,f"BEGIN TRANSACTION; EXEC dbo.{procedure} ?,?; WAITFOR DELAY '00:00:02'; COMMIT;",f"EXEC dbo.{procedure} ?,?",(transition_alert,staff),(transition_alert,admin))
            codes=[w["result"][0]["rows"][0]["Code"] for w in result["workers"].values()]
            check(sorted(codes)==["INVALID_STATE","OK"],codes)
            check(rows(conn,"SELECT Status FROM dbo.Alerts WHERE AlertId=?",(transition_alert,))[0]["Status"] == expected_status,procedure)
            log["checks"].append({"name":procedure+"_race","status":"PASS","pair":result})

        race_event=str(uuid.uuid4())
        result=pair(conn,"BEGIN TRANSACTION; EXEC dbo.sp_InsertSensorReading ?,28,80,?; WAITFOR DELAY '00:00:02'; COMMIT;","EXEC dbo.sp_InsertSensorReading ?,28,80,?",(device,race_event),(device,race_event))
        payloads=[w["result"][0]["rows"][0] for w in result["workers"].values()]
        check(all(r["Code"]=="OK" for r in payloads) and len({r["ReadingId"] for r in payloads})==1 and sum(r["Duplicate"] for r in payloads)==1,payloads)
        log["checks"].append({"name":"concurrent_same_event","status":"PASS","pair":result})

        second_device=rows(conn,"INSERT dbo.Devices(DeviceName,ZoneId,DeviceType) OUTPUT inserted.DeviceId VALUES ('fixture-second-sensor',?,'SENSOR')",(zone,))[0]["DeviceId"]
        result=pair(conn,"BEGIN TRANSACTION; EXEC dbo.sp_InsertSensorReading ?,25,69,?; WAITFOR DELAY '00:00:02'; COMMIT;","EXEC dbo.sp_InsertSensorReading ?,24,68,?",(device,str(uuid.uuid4())),(second_device,str(uuid.uuid4())))
        payloads=[w["result"][0]["rows"][0] for w in result["workers"].values()]
        check(all(r["Code"]=="OK" for r in payloads) and sorted(r["AlertCount"] for r in payloads)==[0,2],payloads)
        log["checks"].append({"name":"two_sensors_one_open_incident_per_type","status":"PASS","pair":result})

        d.execute(conn,"BEGIN TRANSACTION")
        try:
            call("ambient_ack","EXEC dbo.sp_AcknowledgeAlert ?,?",(transition_alert,staff))
            call("ambient_resolve","EXEC dbo.sp_ResolveAlert ?,?",(transition_alert,staff))
            call("ambient_reopen","EXEC dbo.sp_ReopenAlert ?,?",(transition_alert,staff))
            check(rows(conn,"SELECT @@TRANCOUNT AS N,XACT_STATE() AS S")[0]=={"N":1,"S":1},"Transition committed or damaged caller transaction")
        finally:
            d.execute(conn,"IF @@TRANCOUNT>0 ROLLBACK")
        check(rows(conn,"SELECT Status FROM dbo.Alerts WHERE AlertId=?",(transition_alert,))[0]["Status"]=="PENDING","Transition caller rollback failed")

        if fault_injection:
            check(database.startswith("SwiftletCare_Verify_"),"Fault injection is restricted to the isolated verification database")
            fault_event=str(uuid.uuid4())
            for current in rows(conn,"SELECT AlertId,Status FROM dbo.Alerts WHERE ZoneId=? AND AlertType='LOW_TEMP' AND Status IN ('PENDING','ACKNOWLEDGED')",(zone,)):
                if current["Status"]=="PENDING":
                    call("ack_before_fault","EXEC dbo.sp_AcknowledgeAlert ?,?",(current["AlertId"],staff))
                call("resolve_before_fault","EXEC dbo.sp_ResolveAlert ?,?",(current["AlertId"],staff))
            cutoff=rows(conn,"SELECT ISNULL(MAX(ReadingId),0) AS N FROM dbo.SensorReadings")[0]["N"]
            fault_sql=f"""SET XACT_ABORT ON;
            BEGIN TRY
                BEGIN TRANSACTION;
                UPDATE dbo.EnvironmentThresholds SET MinTemperature=10 WHERE ZoneId={zone};
                ALTER TABLE dbo.Alerts ADD CONSTRAINT CK_SC_Fault CHECK (ZoneId<>{zone} OR AlertType<>'LOW_TEMP' OR ReadingId<={cutoff});
                EXEC dbo.sp_InsertSensorReading ?,0,80,?;
                SELECT XACT_STATE() AS XactState,@@TRANCOUNT AS TranCount;
                ROLLBACK;
            END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH;"""
            result=d.execute(conn,fault_sql,(device,fault_event))
            failure=result[0]["rows"][0]
            check(failure["Code"]=="SYSTEM_ERROR" and failure["ErrorNumber"]==547 and failure["ReadingId"] is None,failure)
            check(result[1]["rows"][0]=={"XactState":-1,"TranCount":1},result)
            log["checks"].append({"name":"alert_failure_atomicity","status":"PASS","result":result})
            check(rows(conn,"SELECT COUNT(*) AS N FROM dbo.SensorReadings WHERE SourceEventId=?",(fault_event,))[0]["N"]==0,"Partial reading survived alert failure")
            call("ack_before_action_fault","EXEC dbo.sp_AcknowledgeAlert ?,?",(transition_alert,staff))
            cutoff=rows(conn,"SELECT ISNULL(MAX(ActionId),0) AS N FROM dbo.AlertActions")[0]["N"]
            result=d.execute(conn,f"""SET XACT_ABORT ON; BEGIN TRY BEGIN TRANSACTION;
                ALTER TABLE dbo.AlertActions ADD CONSTRAINT CK_SC_ActionFault CHECK (AlertId<>{transition_alert} OR ActionType<>'RESOLVE' OR ActionId<={cutoff});
                EXEC dbo.sp_ResolveAlert ?,?;
                SELECT XACT_STATE() AS XactState,@@TRANCOUNT AS TranCount;
                ROLLBACK; END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH;""",(transition_alert,staff))
            failure=result[0]["rows"][0]
            check(failure["Code"]=="SYSTEM_ERROR" and failure["ErrorNumber"]==547 and failure["ActionId"] is None,failure)
            log["checks"].append({"name":"resolve_action_failure_atomicity","status":"PASS","result":result})
            check(rows(conn,"SELECT Status FROM dbo.Alerts WHERE AlertId=?",(transition_alert,))[0]["Status"]=="ACKNOWLEDGED","Partial alert status survived action failure")
        log["status"]="PASS"
        print("RUNTIME PASS",database,len(log["checks"]),flush=True)
    except Exception as error:
        log.update(status="FAIL",error=str(error))
        raise
    finally:
        d.execute(conn,"REVERT; IF @@TRANCOUNT>0 ROLLBACK")
        if fixture:
            log["cleanup"]=d.execute(conn,mode("CLEANUP"))
        log["after"]=d.snapshot(conn)
        log["data_unchanged"]=log["before"]==log["after"]
        d.save("fresh_runtime.json" if fault_injection else "runtime.json",log)
    check(log["data_unchanged"],"Runtime fixture cleanup changed original data")


def fresh(conn):
    name="SwiftletCare_Verify_"+uuid.uuid4().hex[:12]
    log={"database":name,"created":False}
    isolated=None
    try:
        d.execute(conn,f"CREATE DATABASE [{name}]")
        log["created"]=True
        d.save("fresh.json",log)
        isolated=d.connect(name)
        deploy(isolated,name,backup=False)
        check(all(s["count"]==0 for s in d.snapshot(isolated).values()),"Fresh business tables were not empty")
        run_file(isolated,"seed_data.sql",name)
        first=d.snapshot(isolated)
        run_file(isolated,"seed_data.sql",name)
        check(first==d.snapshot(isolated),"Fresh second seed changed data")
        log["seed_counts"]={table:item["count"] for table,item in first.items()}
        runtime(isolated,fault_injection=True)
        log["status"]="PASS"
        print("FRESH PASS",name,flush=True)
    except Exception as error:
        log.update(status="FAIL",error=str(error))
        raise
    finally:
        if isolated is not None:
            log["transactions"]=d.execute(isolated,"SELECT @@TRANCOUNT AS TranCount,XACT_STATE() AS XactState")
            isolated.close()
        log["retained"]=True
        d.save("fresh.json",log)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=["preflight", "deploy", "isolation", "runtime", "regression", "fresh", "after"])
    args=parser.parse_args()
    stage=args.stage
    connection = d.connect()
    try:
        if stage in ["preflight","after"]:
            d.inspect(connection,"before" if stage=="preflight" else "after")
        elif stage=="regression":
            d.queries(connection)
            d.regression(connection)
            d.concurrency(connection)
            d.supplement(connection)
        else:
            globals()[stage](connection)
    finally:
        connection.close()


if __name__ == "__main__":
    main()
