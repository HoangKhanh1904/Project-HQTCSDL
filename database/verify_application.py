"""Terminal-only verification; writes fixtures only in newly created test DBs.

python -B database/verify_application.py --static
python -B database/verify_application.py
Keeps the isolated databases and verified server-side backup for inspection.
Does not deploy changes to SwiftletCare; use complete_database.py deploy for that.
"""
import argparse
import ast
import re
import sys
import uuid
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent


def require(value, message):
    if not value:
        raise AssertionError(message)


def static():
    for path in ROOT.rglob('*.py'):
        ast.parse(path.read_text(encoding='utf-8-sig'), filename=str(path))
    tree = ast.parse((ROOT / 'complete_database.py').read_text(encoding='utf-8-sig'))
    deploy = next(ast.literal_eval(n.value) for n in tree.body
                  if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'DEPLOY_FILES' for t in n.targets))
    for name in deploy:
        require((ROOT / name).is_file(), 'Missing deployment source: ' + name)
    require(deploy.index('application_extension.sql') < deploy.index('procedures/sp_insert_sensor_reading.sql'), 'Columns must precede ingest')
    for name in ROOT.joinpath('procedures').glob('*.sql'):
        require('procedures/' + name.name in deploy, 'Procedure omitted from deployment: ' + name.name)
        require(deploy.index('procedures/' + name.name) < deploy.index('security.sql'), 'Permissions must follow APIs')
    ingest = (ROOT / 'procedures/sp_insert_sensor_reading.sql').read_text(encoding='utf-8-sig')
    signature = ingest.split('\nAS\n')[0]
    names = re.findall(r'@(\w+)\s+(?:INT|DECIMAL|UNIQUEIDENTIFIER|VARCHAR)', signature)
    require(names == ['DeviceId','Temperature','Humidity','SourceEventId','ResultCode','CO2Ppm','LightLux'], 'Legacy positional ingest contract changed')
    require('@ResultCode VARCHAR(32) = NULL OUTPUT' in signature, 'Legacy OUTPUT contract changed')
    print('STATIC PASS: Python syntax, deployment manifest and legacy ingest signature')


def extension(conn, d, c):
    require(conn.getinfo(d.pyodbc.SQL_DATABASE_NAME).startswith('SwiftletCare_Verify_'), 'Fixtures require an isolated verification DB')
    tag = 'ext' + uuid.uuid4().hex[:16]
    before = d.snapshot(conn)
    fixture = None
    passed = 0

    def rows(sql, params=()):
        return c.rows(conn, sql, params)

    def call(sql, params=(), code='OK'):
        nonlocal passed
        result = d.execute(conn, sql, params)
        require(len(result) == 1 and len(result[0]['rows']) == 1, (sql, result))
        row = result[0]['rows'][0]
        require(row['Code'] == code and row['Success'] == (code == 'OK'), (sql, row, code))
        passed += 1
        return row

    def control(action, mode=None, on=None, reading=None, device=None, user=None, code='OK'):
        return call('EXEC dbo.sp_SimulateDeviceControl ?,?,?,?,?,?', (device or fan, user or staff, action, mode, on, reading), code)

    def bird(direction='IN', count=3, at='2026-01-01T00:00:00', source='SIMULATED', event=None, house=None, code='OK'):
        return call('EXEC dbo.sp_InsertBirdMovement ?,?,?,?,?,?', (house if house is not None else hid,direction,count,at,source,event), code)

    def threat(event=None, message='simulated event', kind='PREDATOR_DETECTED', severity='WARNING', house=None, zone=None, device=None, code='OK'):
        return call('EXEC dbo.sp_InsertSimulatedSystemEvent ?,?,?,?,\'2026-01-01\',?,?,?',
                    (hid if house is None else house,zid if zone is None else zone,kind,severity,message,device,event), code)

    def sensor(co2=None, lux=None, event=None, code='OK', temp=35, humidity=65):
        return call('EXEC dbo.sp_InsertSensorReading @DeviceId=?,@Temperature=?,@Humidity=?,@SourceEventId=?,@CO2Ppm=?,@LightLux=?',
                    (sid,temp,humidity,event,co2,lux), code)

    try:
        fixture = d.execute(conn, d.mode_sql('SETUP', tag))[0]['rows'][0]
        zid, staff, admin = (fixture[k] for k in ('ZoneId','StaffA','AdminA'))
        hid = rows('SELECT HouseId FROM dbo.Zones WHERE ZoneId=?',(zid,))[0]['HouseId']
        sid = rows('SELECT DeviceId FROM dbo.Devices WHERE ZoneId=?',(zid,))[0]['DeviceId']
        fan = rows("INSERT dbo.Devices(DeviceName,ZoneId,DeviceType) OUTPUT inserted.DeviceId VALUES ('ext-fan',?,'FAN')",(zid,))[0]['DeviceId']
        humidifier = rows("INSERT dbo.Devices(DeviceName,ZoneId,DeviceType) OUTPUT inserted.DeviceId VALUES ('ext-hum',?,'HUMIDIFIER')",(zid,))[0]['DeviceId']
        light = rows("INSERT dbo.Devices(DeviceName,ZoneId,DeviceType) OUTPUT inserted.DeviceId VALUES ('ext-light',?,'LIGHT')",(zid,))[0]['DeviceId']
        d.execute(conn,'BEGIN TRANSACTION')
        key = str(uuid.uuid4())
        first = bird(event=key)
        retry = bird(event=key)
        require(retry['Duplicate'] and retry['EventId'] == first['EventId'], 'Bird retry changed identity')
        bird(count=4,event=key,code='IDEMPOTENCY_CONFLICT')
        bird(direction='OUT',count=2,at='2026-01-01T23:59:59')
        bird(at='2026-01-02',source='MANUAL')
        # Same guid in another source is a distinct event.
        bird(event=key,source='MANUAL',at='2026-01-02')
        for count in (0,-1,None):
            bird(count=count,code='VALIDATION_ERROR')
        bird(direction=None,code='VALIDATION_ERROR')
        bird(direction='BAD',code='VALIDATION_ERROR')
        bird(source='AI',code='VALIDATION_ERROR')
        bird(at=None,code='VALIDATION_ERROR')
        bird(house=0,code='VALIDATION_ERROR')
        bird(house=2147483647,code='HOUSE_NOT_FOUND')
        daily = rows("EXEC dbo.sp_GetBirdMovementDaily ?,'2026-01-01','2026-01-02'",(hid,))
        require(len(daily)==1 and daily[0]['InCount']==3 and daily[0]['OutCount']==2 and daily[0]['EventCount']==2, daily)
        require(len(rows("EXEC dbo.sp_GetBirdMovementDaily ?,'2026-01-01','2026-01-03'",(hid,)))==2, 'Daily buckets')
        require(not rows("EXEC dbo.sp_GetBirdMovementDaily ?,'2027-01-01','2027-01-02'",(hid,)), 'Empty range')
        bird(count=2147483647,at='2026-02-01')
        bird(count=2147483647,at='2026-02-01')
        require(rows("EXEC dbo.sp_GetBirdMovementDaily ?,'2026-02-01','2026-02-02'",(hid,))[0]['InCount']==4294967294,'Daily SUM must use BIGINT')

        old = call('EXEC dbo.sp_InsertSensorReading ?,28,80',(sid,))
        call('EXEC dbo.sp_InsertSensorReading ?,28,80,NULL',(sid,))
        result = d.execute(conn,'DECLARE @C VARCHAR(32); EXEC dbo.sp_InsertSensorReading ?,28,80,NULL,@C OUTPUT; SELECT @C AS Code',(sid,))
        require(result[-1]['rows'][0]['Code']=='OK', 'Fifth positional OUTPUT compatibility')
        metrics = rows('EXEC dbo.sp_GetEnvironmentMetrics @DeviceId=?',(sid,))
        require(metrics[0]['CO2Ppm'] is None and metrics[0]['LightLux'] is None, 'NULL metrics became fake zero')
        missing_sensor = rows("INSERT dbo.Devices(DeviceName,ZoneId,DeviceType) OUTPUT inserted.DeviceId VALUES('ext-no-data',?,'SENSOR')",(zid,))[0]['DeviceId']
        missing = rows('EXEC dbo.sp_GetEnvironmentMetrics @DeviceId=?',(missing_sensor,))[0]
        require(missing['ReadingStatus']=='NO_DATA' and all(missing[k] is None for k in ('Temperature','Humidity','CO2Ppm','LightLux')), 'Missing sample is not NULL')
        for co2,lux in ((0,0),(100000,200000),(420,15),(None,15),(420,None),(None,None)):
            sensor(co2,lux)
        key = str(uuid.uuid4())
        first = sensor(420,15,key)
        duplicate = sensor(420,15,key)
        require(duplicate['Duplicate'] and duplicate['ReadingId']==first['ReadingId'], 'Sensor identity')
        for co2,lux in ((421,15),(420,16),(None,15),(420,None)):
            sensor(co2,lux,key,code='IDEMPOTENCY_CONFLICT')
        sensor(420,15,key,temp=34,code='IDEMPOTENCY_CONFLICT')
        sensor(420,15,key,humidity=66,code='IDEMPOTENCY_CONFLICT')
        for co2,lux in ((-0.01,0),(100000.01,0),(0,-0.01),(0,200000.01)):
            sensor(co2,lux,code='VALIDATION_ERROR')
        require(rows('EXEC dbo.sp_GetLatestSensorReadings ?',(zid,)) and rows("EXEC dbo.sp_GetSensorHistory ?,'2000-01-01','2100-01-01'",(sid,)), 'Legacy getters')
        history = rows("EXEC dbo.sp_GetEnvironmentMetrics @DeviceId=?,@From='2000-01-01',@To='2100-01-01'",(sid,))
        require(history and any(r['CO2Ppm']==420 for r in history), 'Four metric history')

        reading = sensor(500,1)['ReadingId']
        control('MANUAL',on=False)
        control('AUTO',reading=reading,code='MANUAL_OVERRIDE')
        control('SET_MODE',mode='AUTO')
        require(control('AUTO',reading=reading)['IsOn'], 'Hot fan should turn on')
        require(not control('AUTO',reading=reading)['Changed'], 'Same state should not duplicate logs')
        mid = sensor(temp=29,humidity=80)['ReadingId']
        require(control('AUTO',reading=mid)['IsOn'], 'Hysteresis should retain fan state')
        cold = sensor(temp=25,humidity=95)['ReadingId']
        require(not control('AUTO',reading=cold)['IsOn'], 'Cold fan should turn off')
        control('AUTO',reading=mid,code='STALE_READING')
        control('SET_MODE',mode='AUTO',device=humidifier)
        require(not control('AUTO',reading=cold,device=humidifier)['IsOn'], 'High humidity keeps humidifier off')
        dry = sensor(temp=35,humidity=65)['ReadingId']
        require(control('AUTO',reading=dry,device=humidifier)['IsOn'], 'Dry humidifier on')
        control('SET_MODE',mode='AUTO',device=light)
        control('AUTO',reading=dry,device=light,code='RULE_UNAVAILABLE')
        control('MANUAL',on=True,device=light)
        control('MANUAL',on=True,device=sid,code='DEVICE_UNAVAILABLE')
        control('MANUAL',on=True,device=2147483647,code='DEVICE_NOT_FOUND')
        control('MANUAL',on=True,user=2147483647,code='FORBIDDEN')
        control('SET_MODE',mode='WRONG',code='VALIDATION_ERROR')
        control('MANUAL',code='VALIDATION_ERROR')
        control('AUTO',code='VALIDATION_ERROR')
        require(rows("SELECT COUNT(*) AS N FROM dbo.ControlLogs WHERE DeviceId=? AND ExecutionKind='SIMULATED' AND ControlMode IS NOT NULL",(fan,))[0]['N']>=4,'Simulation audit missing')

        key = str(uuid.uuid4())
        first = threat(event=key)
        retry = threat(event=key)
        require(retry['Duplicate'] and retry['EventId']==first['EventId'], 'Threat retry')
        for change in (dict(message='different'),dict(message='Simulated event'),dict(device=sid),dict(severity='CRITICAL')):
            threat(event=key,code='IDEMPOTENCY_CONFLICT',**change)
        for kind in ('SPEAKER_FAILURE','ABNORMAL_SOUND','DEVICE_OFFLINE'):
            threat(kind=kind,device=sid)
        for change in (dict(message=' '),dict(kind='AI'),dict(severity='BAD')):
            threat(code='VALIDATION_ERROR',**change)
        threat(house=2147483647,code='HOUSE_NOT_FOUND')
        threat(zone=2147483647,code='ZONE_HOUSE_MISMATCH')
        threat(device=2147483647,code='DEVICE_ZONE_MISMATCH')
        event_id = first['EventId']
        require(len(rows('EXEC dbo.sp_GetSimulatedSystemEvents @HouseId=?,@ZoneId=?',(hid,zid)))==4, 'House/zone event list')
        call("EXEC dbo.sp_UpdateSimulatedEventStatus ?,?,'NEW','ACKNOWLEDGED'",(event_id,staff))
        require(not call("EXEC dbo.sp_UpdateSimulatedEventStatus ?,?,'NEW','ACKNOWLEDGED'",(event_id,admin))['Changed'], 'Duplicate ACK changed audit')
        call("EXEC dbo.sp_UpdateSimulatedEventStatus ?,?,'ACKNOWLEDGED','RESOLVED'",(event_id,staff))
        call("EXEC dbo.sp_UpdateSimulatedEventStatus ?,?,'NEW','ACKNOWLEDGED'",(event_id,staff),'CONCURRENCY_CONFLICT')
        call("EXEC dbo.sp_UpdateSimulatedEventStatus ?,?,'NEW','RESOLVED'",(event_id,staff),'VALIDATION_ERROR')
        call("EXEC dbo.sp_UpdateSimulatedEventStatus ?,2147483647,'NEW','ACKNOWLEDGED'",(event_id,),'FORBIDDEN')
        call("EXEC dbo.sp_UpdateSimulatedEventStatus 9223372036854775807,?,'NEW','ACKNOWLEDGED'",(staff,),'EVENT_NOT_FOUND')
        require(len(rows('EXEC dbo.sp_GetSimulatedSystemEvents @HouseId=?',(hid,)))==3, 'Resolved event was not filtered')
        require(len(rows("EXEC dbo.sp_GetSimulatedSystemEvents @HouseId=?,@Status='RESOLVED'",(hid,)))==1,'Resolved filter')
        require(rows('SELECT @@TRANCOUNT AS N,XACT_STATE() AS S')[0]=={'N':1,'S':1},'APIs committed/damaged caller transaction')
        d.execute(conn,'ROLLBACK')
        for table in ('BirdMovementEvents','SimulatedSystemEvents'):
            require(rows(f'SELECT COUNT(*) AS N FROM dbo.{table} WHERE HouseId=?',(hid,))[0]['N']==0,'Caller rollback failed: '+table)
        require(not rows('SELECT DeviceId FROM dbo.DeviceControlSettings WHERE DeviceId=?',(fan,)), 'Control rollback failed')

        # New API permission tests run as actual non-owner SQL principals.
        for principal in ('swiftlet_admin_demo','swiftlet_staff_demo','swiftlet_ingest_demo'):
            d.execute(conn,'BEGIN TRANSACTION')
            event = threat()['EventId']
            d.execute(conn,f"EXECUTE AS USER='{principal}'")
            try:
                require(rows("SELECT IS_MEMBER('db_owner') AS V")[0]['V']==0,'Owner invalidates permissions test')
                for table in ('BirdMovementEvents','DeviceControlSettings','SimulatedSystemEvents'):
                    for permission in ('INSERT','UPDATE','DELETE'):
                        require(rows("SELECT HAS_PERMS_BY_NAME(?,'OBJECT',?) AS V",('dbo.'+table,permission))[0]['V']==0,(principal,table,permission))
                require(rows("SELECT HAS_PERMS_BY_NAME('dbo.sp_TransitionAlert','OBJECT','EXECUTE') AS V")[0]['V']==0,'Helper exposed')
                bird()
                if principal != 'swiftlet_staff_demo':
                    event = threat()['EventId']
                if principal != 'swiftlet_ingest_demo':
                    control('MANUAL',on=True)
                    call("EXEC dbo.sp_UpdateSimulatedEventStatus ?,?,'NEW','ACKNOWLEDGED'",(event,staff))
                    require(rows('EXEC dbo.sp_GetSimulatedSystemEvents @HouseId=?',(hid,)), 'Events read denied')
                    rows('EXEC dbo.sp_GetEnvironmentMetrics @ZoneId=?',(zid,))
                    require(rows('EXEC dbo.sp_GetBirdMovementDaily ?,\'2026-01-01\',\'2026-01-02\'',(hid,)), 'Daily execute denied')
                denied = 'sp_InsertSimulatedSystemEvent' if principal=='swiftlet_staff_demo' else 'sp_SimulateDeviceControl' if principal=='swiftlet_ingest_demo' else None
                if denied:
                    require(rows("SELECT HAS_PERMS_BY_NAME(?,'OBJECT','EXECUTE') AS V",('dbo.'+denied,))[0]['V']==0,'Unexpected EXECUTE grant')
                    try:
                        d.execute(conn,f'EXEC dbo.{denied}')
                        raise AssertionError('Expected EXECUTE denial')
                    except d.pyodbc.Error as error:
                        require('(229)' in str(error), 'Expected permission error 229')
            finally:
                d.execute(conn,'REVERT; IF @@TRANCOUNT>0 ROLLBACK')

        # Idempotency and transitions under two independent sessions.
        for name, sql, params in (
            ('bird',"EXEC dbo.sp_InsertBirdMovement ?,'IN',3,'2026-01-01','SIMULATED',?",(hid,str(uuid.uuid4()))),
            ('event',"EXEC dbo.sp_InsertSimulatedSystemEvent ?,?,'ABNORMAL_SOUND','WARNING','2026-01-01','race',NULL,?",(hid,zid,str(uuid.uuid4()))),
        ):
            race = c.pair(conn,"BEGIN TRANSACTION; "+sql+"; WAITFOR DELAY '00:00:02'; COMMIT;",sql,params,params)
            values = [w['result'][0]['rows'][0] for w in race['workers'].values()]
            require(all(v['Code']=='OK' for v in values) and sum(v['Duplicate'] for v in values)==1 and len({v['EventId'] for v in values})==1, (name,values))
            print('CONCURRENCY PASS: extension',name)
        event = threat()['EventId']
        sql = "EXEC dbo.sp_UpdateSimulatedEventStatus ?,?,'NEW','ACKNOWLEDGED'"
        race = c.pair(conn,"BEGIN TRANSACTION; "+sql+"; WAITFOR DELAY '00:00:02'; COMMIT;",sql,(event,staff),(event,admin))
        values = [w['result'][0]['rows'][0] for w in race['workers'].values()]
        require(all(v['Code']=='OK' for v in values) and sum(v['Changed'] for v in values)==1,values)
        reading = sensor()['ReadingId']
        control('SET_MODE',mode='AUTO')
        race = c.pair(conn,"BEGIN TRANSACTION; EXEC dbo.sp_SimulateDeviceControl ?,?,'MANUAL',@IsOn=0; WAITFOR DELAY '00:00:02'; COMMIT;",
                      "EXEC dbo.sp_SimulateDeviceControl ?,?,'AUTO',@ReadingId=?",(fan,staff),(fan,admin,reading))
        require(race['workers']['T2']['result'][0]['rows'][0]['Code']=='MANUAL_OVERRIDE',race)
        require(rows('SELECT ControlMode,IsOn FROM dbo.DeviceControlSettings WHERE DeviceId=?',(fan,))[0]=={'ControlMode':'MANUAL','IsOn':False},'AUTO overwrote manual')
        print('CONCURRENCY PASS: event status and MANUAL/AUTO race')

        # Fault injection: force the log insert to fail after state update.
        # Restricted to this owned fixture, in a rollback-only DDL transaction.
        # Roll back in the same SQL batch: a doomed ambient transaction cannot
        # be left open at the batch boundary (SQL Server error 3998).
        fault = d.execute(conn,f"""BEGIN TRY BEGIN TRANSACTION;
            ALTER TABLE dbo.ControlLogs WITH NOCHECK ADD CONSTRAINT CK_ExtFixtureFault CHECK(DeviceId<>{fan} OR ExecutionKind IS NULL);
            EXEC dbo.sp_SimulateDeviceControl ?,?,'MANUAL',@IsOn=1;
            SELECT XACT_STATE() AS S,@@TRANCOUNT AS N;
            ROLLBACK;
            END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH;""",(fan,staff))
        failure = fault[0]['rows'][0]
        require(failure['Code']=='SYSTEM_ERROR' and not failure['Success'],'Fault must report failure')
        require(failure['ErrorNumber']==547 and failure['ControlLogId'] is None,'Fault should be CHECK 547')
        require(fault[1]['rows'][0]=={'S':-1,'N':1},'Caller must receive its doomed transaction')
        require(not rows('SELECT IsOn FROM dbo.DeviceControlSettings WHERE DeviceId=?',(fan,))[0]['IsOn'],'Partial simulated state survived failure')
        print('EXTENSION PASS:', passed, 'API assertions, boundaries, permissions, rollback, concurrency')
    finally:
        d.execute(conn,'REVERT; IF @@TRANCOUNT>0 ROLLBACK')
        if fixture:
            for table in ('BirdMovementEvents','SimulatedSystemEvents'):
                d.execute(conn,f'DELETE dbo.{table} WHERE HouseId=?',(hid,))
            d.execute(conn,'DELETE s FROM dbo.DeviceControlSettings s JOIN dbo.Devices d ON d.DeviceId=s.DeviceId WHERE d.ZoneId=?',(zid,))
            d.execute(conn,d.mode_sql('CLEANUP',tag))
        require(before==d.snapshot(conn),'Extension fixture changed original business rows')


def run():
    import run_database_demo as d
    import complete_database as c
    original_connect, original_file_sql = d.connect, d.file_sql
    primary = original_connect()
    isolated = None
    try:
        d.inspect(primary,'before_verification')
        original = d.snapshot(primary)
        tag = uuid.uuid4().hex[:12]
        copy_name = 'SwiftletCare_Verify_Copy_' + tag
        fresh_name = 'SwiftletCare_Verify_Fresh_' + tag
        backup = '/var/opt/mssql/data/SwiftletCare_extension_' + tag + '.bak'
        d.execute(primary,'BACKUP DATABASE SwiftletCare TO DISK=? WITH COPY_ONLY,CHECKSUM,COMPRESSION',(backup,))
        d.execute(primary,'RESTORE VERIFYONLY FROM DISK=? WITH CHECKSUM',(backup,))
        files = c.rows(primary,'RESTORE FILELISTONLY FROM DISK=?',(backup,))
        moves, params = [], [backup]
        for index, item in enumerate(files):
            moves.append('MOVE ? TO ?')
            params += [item['LogicalName'],f'/var/opt/mssql/data/{copy_name}_{index}.'+('ldf' if item['Type']=='L' else 'mdf')]
        d.execute(primary,f'RESTORE DATABASE [{copy_name}] FROM DISK=? WITH '+','.join(moves),tuple(params))
        print('BACKUP VERIFIED; restored isolated copy:', copy_name, flush=True)
        d.execute(primary,f'CREATE DATABASE [{fresh_name}]')
        for database in (copy_name,fresh_name):
            # Legacy regression has USE SwiftletCare/default connect calls.
            # Redirect both in memory; the legacy SQL source stays untouched.
            d.connect = lambda name=None: original_connect(name or database)
            d.file_sql = lambda path: original_file_sql(path).replace('USE SwiftletCare;',f'USE [{database}];')
            isolated = original_connect(database)
            old = d.snapshot(isolated)
            c.deploy(isolated,database,backup=False)
            if database==copy_name:
                require(old==d.snapshot(isolated),'Migration changed existing business rows')
            else:
                require(all(v['count']==0 for v in d.snapshot(isolated).values()),'Fresh deploy seeded unexpectedly')
            deployed = d.snapshot(isolated)
            c.deploy(isolated,database,backup=False)
            require(deployed==d.snapshot(isolated),'Second deploy changed business rows')
            if database==fresh_name:
                c.run_file(isolated,'seed_data.sql',database)
            d.seed(isolated)
            d.queries(isolated)
            d.regression(isolated)
            d.concurrency(isolated)
            d.supplement(isolated)
            c.runtime(isolated,fault_injection=True)
            c.isolation(isolated)
            extension(isolated,d,c)
            print('SUITE PASS:',database,flush=True)
            isolated.close(); isolated=None
        require(original==d.snapshot(primary),'Verification modified primary business data')
        print('ALL PASS; primary unchanged; retained test DBs:',copy_name,fresh_name,flush=True)
    finally:
        d.connect,d.file_sql = original_connect,original_file_sql
        if isolated is not None:
            d.execute(isolated,'REVERT; IF @@TRANCOUNT>0 ROLLBACK'); isolated.close()
        primary.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--static', action='store_true')
    args = parser.parse_args()
    static()
    if not args.static:
        run()


if __name__=='__main__':
    main()
