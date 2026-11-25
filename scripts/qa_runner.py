"""TV4 nhanzza — SwiftletCare fixture-based SQL QA runner.

Run only against a dedicated database named *_QA or *_Test. No fixture is
committed: every automated test gets a fresh SQL transaction and rolls back.
Use the project's own stored procedures to test actual ingest/idempotency.
Missing manual two-session/API/role tests are NOT TESTED, never PASS.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import sys
import uuid
from collections import Counter
from datetime import datetime

try:
    import pyodbc
except ImportError:
    raise SystemExit("Install project requirements first: python -m pip install -r requirements.txt")

SQL_DIR = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def one(cursor, sql, *args):
    cursor.execute(sql, *args)
    row = cursor.fetchone()
    require(row is not None, "No row from SQL: " + sql[:80])
    return dict(zip((col[0] for col in cursor.description), row))


def scalar(cursor, sql, *args):
    cursor.execute(sql, *args)
    r = cursor.fetchone()
    return r[0] if r else None


def rows(cursor, sql, *args):
    cursor.execute(sql, *args)
    cols = [col[0] for col in cursor.description]
    return [dict(zip(cols, r)) for r in cursor.fetchall()]


def insert_id(cursor, sql, *args):
    return next(iter(one(cursor, sql, *args).values()))


def fixture(cursor, *, threshold=True, sensor=True):
    """Create a unique user/house/zone/(sensor)/threshold inside caller's txn."""
    username = "qa_" + uuid.uuid4().hex
    user_id = insert_id(cursor, """INSERT dbo.Users(UserName,PasswordHash,FullName,Role)
        OUTPUT inserted.UserID VALUES (?,N'TEST_ONLY',N'QA fixture','ADMIN')""", username)
    house_id = insert_id(cursor, """INSERT dbo.SwiftletHouses(HouseName,ManagerId)
        OUTPUT inserted.HouseId VALUES (N'QA isolated house',?)""", user_id)
    zone_id = insert_id(cursor, """INSERT dbo.Zones(HouseId,ZoneName)
        OUTPUT inserted.ZoneId VALUES (?,N'QA isolated zone')""", house_id)
    if threshold:
        cursor.execute("""INSERT dbo.EnvironmentThresholds
            (ZoneId,MinTemperature,MaxTemperature,MinHumidity,MaxHumidity)
            VALUES (?,25,33,65,95)""", zone_id)
    device_id = None
    if sensor:
        device_id = insert_id(cursor, """INSERT dbo.Devices(ZoneId,DeviceName,DeviceType)
            OUTPUT inserted.DeviceId VALUES (?,N'QA sensor','SENSOR')""", zone_id)
    return dict(user=user_id, house=house_id, zone=zone_id, device=device_id)


def reading(cursor, f, temp=28, hum=80, event=None, co2=None, light=None):
    return one(cursor, """EXEC dbo.sp_InsertSensorReading
        @DeviceId=?,@Temperature=?,@Humidity=?,@SourceEventId=?,@CO2Ppm=?,@LightLux=?""",
        f['device'], temp, hum, event, co2, light)


def bird(cursor, f, direction='IN', count=2, at='2026-01-15T10:00:00',
         source='SIMULATED', event=None, house=None):
    return one(cursor, """EXEC dbo.sp_InsertBirdMovement
        @HouseId=?,@Direction=?,@BirdCount=?,@ObservedAt=?,@SourceType=?,@SourceEventId=?""",
        f['house'] if house is None else house, direction, count, at, source, event)


def simulated(cursor, f, typ='PREDATOR_DETECTED', severity='WARNING',
              event=None, message='QA simulated event'):
    return one(cursor, """EXEC dbo.sp_InsertSimulatedSystemEvent
        @HouseId=?,@ZoneId=?,@EventType=?,@Severity=?,@EventAt=?,@Message=?,@SourceEventId=?""",
        f['house'], f['zone'], typ, severity, '2026-01-15T10:00:00', message, event)


def latest(cursor, f):
    return one(cursor, "SELECT * FROM dbo.fn_QALatestReadings(?,?,?,NULL,NULL)",
               f['house'], f['zone'], f['device'])


def test_01(c):
    db = scalar(c, 'SELECT DB_NAME()')
    require(db.lower().endswith(('_qa', '_test')), 'QA01: wrong DB ' + str(db))
    require(scalar(c,'SELECT 1') == 1,'QA01: lost SQL connection')


def test_02(c):
    expected = ('Users','SwiftletHouses','Zones','Devices','SensorReadings',
                'EnvironmentThresholds','Alerts','AlertActions','ControlLogs',
                'BirdMovementEvents','SimulatedSystemEvents','DeviceControlSettings')
    for table in expected:
        require(scalar(c,'SELECT OBJECT_ID(?,\'U\')', 'dbo.' + table) is not None,
                'QA02 missing ' + table)
    require(scalar(c,"SELECT COUNT(*) FROM sys.foreign_keys WHERE parent_object_id=OBJECT_ID('dbo.SensorReadings')")>=1,
            'QA02 missing reading FK')
    require(scalar(c,"SELECT COUNT(*) FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID('dbo.SensorReadings')")>=2,
            'QA02 missing reading CHECK')
    require(scalar(c,"SELECT COUNT(*) FROM sys.key_constraints WHERE parent_object_id=OBJECT_ID('dbo.SensorReadings') AND type='PK'")==1,
            'QA02 missing PK')


def test_03(c):
    f = fixture(c)
    # XACT_ABORT OFF: constraint errors are statement-level and the enclosing
    # fixture transaction remains available for a COUNT assertion.
    for temperature, humidity in [(120,80),(28,120)]:
        rejected = False
        try:
            c.execute('INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity) VALUES (?,?,?)',
                      f['device'],temperature,humidity)
        except pyodbc.Error:
            rejected = True
        require(rejected, 'QA03 invalid reading accepted')
    require(scalar(c,'SELECT COUNT(*) FROM dbo.SensorReadings WHERE DeviceId=?',f['device'])==0,
            'QA03 invalid readings persisted')


def test_04(c):
    f = fixture(c)
    for t,h in ((25,65),(33,95)):
        out=reading(c,f,t,h,str(uuid.uuid4()))
        require(out['Code']=='OK' and out['AlertCount']==0, 'QA04 boundary alert: '+str(out))
    require(scalar(c,'SELECT COUNT(*) FROM dbo.Alerts WHERE ZoneId=?',f['zone'])==0,
            'QA04 alert persisted')


def test_05(c):
    f=fixture(c)
    for time,t in (('2026-01-15T09:00:00',27),('2026-01-15T10:00:00',28),('2026-01-15T10:00:00',29)):
        expect=insert_id(c,'INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity,RecordeAt) OUTPUT inserted.ReadingId VALUES (?,?,80,?)',f['device'],t,time)
    require(latest(c,f)['ReadingId']==expect,'QA05 latest ReadingId tie-break wrong')


def test_06(c):
    f=fixture(c)
    require(latest(c,f)['EnvironmentStatus']=='NO_DATA','QA06 no data marked NORMAL')


def test_07(c):
    f=fixture(c,threshold=False)
    out=reading(c,f,28,80,str(uuid.uuid4()))
    require(out['Code']=='OK' and out['ThresholdStatus']=='UNCONFIGURED','QA07 ingest without threshold wrong')
    require(latest(c,f)['EnvironmentStatus']=='UNCONFIGURED','QA07 analytics without threshold wrong')
    require(scalar(c,'SELECT COUNT(*) FROM dbo.Alerts WHERE ZoneId=?',f['zone'])==0,'QA07 false alert')


def test_08(c):
    f=fixture(c)
    for t,h in ((28,80),(40,80),(28,50)):
        c.execute('INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity) VALUES (?,?,?)',f['device'],t,h)
    res=rows(c,'SELECT EnvironmentStatus,IsHighTemp,IsLowHumidity FROM dbo.fn_QAReadings(?,?,?,NULL,NULL)',
             f['house'],f['zone'],f['device'])
    require(len(res)==3 and sum(r['EnvironmentStatus']=='WARNING' for r in res)==2,
            'QA08 incorrect abnormal CTE source')


def test_09(c):
    f=fixture(c)
    state=scalar(c,'SELECT EnvironmentStatus FROM dbo.fn_QAClassifyReading(NULL,80,25,33,65,95)')
    require(state=='NO_DATA','QA09 NULL incorrectly NORMAL')
    require(scalar(c,'SELECT dbo.fn_KiemTraMoiTruongTheoZone(?,NULL,80)',f['zone'])=='Chưa có dữ liệu',
            'QA09 scalar function incorrect')


def test_10(c):
    r=one(c,'SELECT * FROM dbo.fn_QAClassifyReading(20,100,25,33,65,95)')
    require(r['EnvironmentStatus']=='WARNING' and r['IsLowTemp']==1 and r['IsHighHumidity']==1,
            'QA10 lost simultaneous temperature/humidity flags')


def test_11(c):
    f=fixture(c)
    require(reading(c,f,40,100,str(uuid.uuid4()))['Code']=='OK','QA11 ingest failed')
    found=rows(c,'SELECT AlertType,Status,IncidentCount FROM dbo.fn_QAAlertSummary(?,?,NULL,NULL)',f['house'],f['zone'])
    types={(r['AlertType'],r['Status']):r['IncidentCount'] for r in found}
    require(types=={('HIGH_TEMP','PENDING'):1,('HIGH_HUMIDITY','PENDING'):1},
            'QA11 alert type/status summary mismatch: '+str(types))


def test_12(c):
    f=fixture(c)
    for _ in range(3):
        require(reading(c,f,40,80,str(uuid.uuid4()))['Code']=='OK','QA12 ingest failed')
    require(scalar(c,'SELECT COUNT(*) FROM dbo.SensorReadings WHERE DeviceId=?',f['device'])==3,
            'QA12 expected three readings')
    require(scalar(c,"SELECT COUNT(*) FROM dbo.Alerts WHERE ZoneId=? AND AlertType='HIGH_TEMP' AND Status IN ('PENDING','ACKNOWLEDGED')",f['zone'])==1,
            'QA12 duplicate open incidents')


def test_13(c):
    f=fixture(c)
    event=str(uuid.uuid4())
    first=reading(c,f,29,80,event)
    again=reading(c,f,29,80,event)
    conflict=reading(c,f,31,80,event)
    require(first['Code']=='OK' and first['Duplicate']==0,'QA13 first submit')
    require(again['Code']=='OK' and again['Duplicate']==1 and first['ReadingId']==again['ReadingId'],
            'QA13 exact retry duplicated')
    require(conflict['Code']=='IDEMPOTENCY_CONFLICT','QA13 conflicting retry accepted')
    require(scalar(c,'SELECT COUNT(*) FROM dbo.SensorReadings WHERE SourceEventId=CONVERT(uniqueidentifier,?)',event)==1,
            'QA13 database contains duplicates')


def test_14(c):
    f=fixture(c,sensor=False)
    for direction,count,at in (('IN',5,'2026-01-15T12:00:00'),('OUT',2,'2026-01-15T13:00:00'),('IN',3,'2026-01-15T23:59:59')):
        require(bird(c,f,direction,count,at,event=str(uuid.uuid4()))['Code']=='OK','QA14 bird ingest')
    daily=rows(c,'SELECT * FROM dbo.fn_QABirdDaily(?,?,?,?) ORDER BY ObservedDate',f['house'],'2026-01-15','2026-01-17','SIMULATED')
    require(len(daily)==2,'QA14 must include empty day')
    require((daily[0]['InCount'],daily[0]['OutCount'],daily[0]['NetMovement'])==(8,2,6),
            'QA14 incorrect IN/OUT')
    require(daily[1]['InCount']==0 and daily[1]['EventCount']==0,'QA14 empty day not zero')


def test_15(c):
    f=fixture(c,sensor=False)
    bad=[('IN',0,f['house']),('DOWN',2,f['house']),('OUT',-2,f['house']),('IN',2,2147483647)]
    for direction,count,house in bad:
        out=bird(c,f,direction,count,house=house)
        require(out['Code'] in ('VALIDATION_ERROR','HOUSE_NOT_FOUND'),
                'QA15 invalid bird accepted: '+str(out))
    require(scalar(c,'SELECT COUNT(*) FROM dbo.BirdMovementEvents WHERE HouseId=?',f['house'])==0,
            'QA15 invalid events stored')


def test_16(c):
    f=fixture(c,sensor=False)
    key=str(uuid.uuid4())
    first=bird(c,f,'IN',4,event=key)
    again=bird(c,f,'IN',4,event=key)
    conflict=bird(c,f,'IN',7,event=key)
    require(first['Code']=='OK' and again['Code']=='OK' and again['Duplicate']==1,
            'QA16 bird retry not idempotent')
    require(conflict['Code']=='IDEMPOTENCY_CONFLICT','QA16 bird conflict not blocked')
    daily=rows(c,'SELECT * FROM dbo.fn_QABirdDaily(?,?,?,?)',f['house'],'2026-01-15','2026-01-16','SIMULATED')
    require(len(daily)==1 and daily[0]['InCount']==4 and daily[0]['EventCount']==1,
            'QA16 double-counted retry')


def test_17(c):
    f=fixture(c)
    for co2,light in ((None,None),(0,0),(100000,200000)):
        require(reading(c,f,28,80,str(uuid.uuid4()),co2,light)['Code']=='OK',
                'QA17 valid boundary rejected')
    for co2,light in ((-1,5),(5,-1),(100001,5),(5,200001)):
        require(reading(c,f,28,80,str(uuid.uuid4()),co2,light)['Code']=='VALIDATION_ERROR',
                'QA17 invalid CO2/light accepted')
    rec=one(c,'SELECT COUNT(*) AS Total,COUNT(CO2Ppm) AS CO2NotNull,COUNT(LightLux) AS LuxNotNull FROM dbo.SensorReadings WHERE DeviceId=?',f['device'])
    require((rec['Total'],rec['CO2NotNull'],rec['LuxNotNull'])==(3,2,2),
            'QA17 NULL/co2/light aggregation wrong')


def test_18(c):
    f=fixture(c,sensor=False)
    key=str(uuid.uuid4())
    a=simulated(c,f,event=key)
    b=simulated(c,f,event=key)
    conflict=simulated(c,f,typ='SPEAKER_FAILURE',event=key)
    require(a['Code']=='OK' and b['Code']=='OK' and b['Duplicate']==1,
            'QA18 retry did not work')
    require(conflict['Code']=='IDEMPOTENCY_CONFLICT','QA18 conflicting retry accepted')
    records=rows(c,'SELECT EventType,EventCount FROM dbo.fn_QASimulatedEventSummary(?,?,?,?)',
                 f['house'],f['zone'],'2026-01-15','2026-01-16')
    require(len(records)==1 and records[0]['EventType']=='PREDATOR_DETECTED' and records[0]['EventCount']==1,
            'QA18 source/event double counted')
    require(scalar(c,'SELECT COUNT(*) FROM dbo.SimulatedSystemEvents WHERE HouseId=? AND SourceType=\'SIMULATED\'',f['house'])==1,
            'QA18 missing SIMULATED label')


def test_19(c):
    # P0 (nhanh update_application): audit mode-only thanh test tu dong.
    # Doi ControlMode (SET_MODE) khi IsOn khong doi thi KHONG duoc ghi log
    # TURN_ON/TURN_OFF gia vao dbo.ControlLogs. Chi khi trang thai ON/OFF
    # thuc su doi (MANUAL/AUTO) thi moi ghi log. Fixture rieng, rollback
    # sau khi kiem tra (runner rollback moi test).
    f = fixture(c, sensor=False)
    dev = insert_id(c, "INSERT dbo.Devices(ZoneId,DeviceName,DeviceType) OUTPUT inserted.DeviceId VALUES (?,N'QA19 fan','FAN')", f['zone'])
    # SP yeu cau zone/device ACTIVE; dat ro de khong phu thuoc gia tri mac dinh.
    c.execute("UPDATE dbo.Zones SET Status='ACTIVE' WHERE ZoneId=?", f['zone'])
    c.execute("UPDATE dbo.Devices SET Status='ACTIVE' WHERE DeviceId=?", dev)
    # Trang thai ban dau: MANUAL, OFF.
    c.execute("INSERT dbo.DeviceControlSettings(DeviceId,DeviceType,ControlMode,IsOn) VALUES (?,N'FAN',N'MANUAL',0)", dev)
    before = scalar(c, 'SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?', dev)
    # 1. Doi mode MANUAL -> AUTO, IsOn khong doi (van OFF).
    out = one(c, """EXEC dbo.sp_SimulateDeviceControl
        @DeviceId=?,@UserId=?,@Action='SET_MODE',@ControlMode='AUTO'""",
        dev, f['user'])
    require(out['Success'] == 1 and out['Code'] == 'OK'
            and out['ModeChanged'] == 1 and out['StateChanged'] == 0,
            'QA19 SET_MODE must report ModeChanged=1/StateChanged=0: ' + str(out))
    require(scalar(c, 'SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?', dev) == before,
            'QA19 mode-only change wrote a fake TURN_ON/TURN_OFF log')
    row = one(c, 'SELECT ControlMode,IsOn FROM dbo.DeviceControlSettings WHERE DeviceId=?', dev)
    require(row['ControlMode'] == 'AUTO' and row['IsOn'] == 0,
            'QA19 settings not AUTO/OFF: ' + str(row))
    # 2. Kiem chung duong: MANUAL bat len thi PHAI ghi dung 1 log TURN_ON.
    out = one(c, """EXEC dbo.sp_SimulateDeviceControl
        @DeviceId=?,@UserId=?,@Action='MANUAL',@IsOn=1""",
        dev, f['user'])
    require(out['Success'] == 1 and out['Code'] == 'OK' and out['StateChanged'] == 1,
            'QA19 MANUAL ON must report StateChanged=1: ' + str(out))
    require(scalar(c, 'SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?', dev) == before + 1,
            'QA19 MANUAL ON did not write exactly one log')
    require(scalar(c, "SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=? AND Command='TURN_ON'", dev) == 1,
            'QA19 TURN_ON log missing')


def test_23(c):
    content=(SQL_DIR/'qa_tests.sql').read_text(encoding='utf-8-sig')
    batches=re.split(r'(?im)^\s*GO\s*(?:--[^\n]*)?$',content)
    for batch in batches:
        if not batch.strip():
            continue
        c.execute(batch)
        # THROW can be deferred until nextset() for multi-result batches.
        while True:
            if c.description:
                c.fetchall()
            if not c.nextset():
                break


def test_25(c):
    f=fixture(c,sensor=False)
    dev=insert_id(c,"INSERT dbo.Devices(ZoneId,DeviceName,DeviceType) OUTPUT inserted.DeviceId VALUES (?,N'QA25 sensor','SENSOR')",f['zone'])
    for at in ('2026-01-15T09:59:59','2026-01-15T10:00:00','2026-01-15T11:00:00'):
        c.execute('INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity,RecordeAt) VALUES (?,28,80,?)',dev,at)
    total=scalar(c,'SELECT COUNT(*) FROM dbo.fn_QAReadings(?,?,?, ?, ?)',
                 f['house'],f['zone'],dev,'2026-01-15T10:00:00','2026-01-15T11:00:00')
    require(total==1,'QA25 [Start,End) read window wrong')
    # End midnight is exclusive; a day without events must still be reported.
    require(bird(c,f,'IN',1,'2026-01-16T00:00:00')['Code']=='OK','QA25 bird insert')
    before=rows(c,'SELECT * FROM dbo.fn_QABirdDaily(?,?,?,?)',f['house'],'2026-01-15T00:00:00','2026-01-16T00:00:00','SIMULATED')
    require(len(before)==1 and before[0]['EventCount']==0,
            'QA25 included event at exclusive End')


def test_26(c):
    # P1: LIGHT AUTO theo nguong anh sang (MinLightLux/MaxLightLux).
    # Fixture rieng + rollback nhu moi test khac.
    columns=['MinLightLux','MaxLightLux']
    missing=[col for col in columns
             if scalar(c,"SELECT COL_LENGTH('dbo.EnvironmentThresholds',?)",col) is None]
    require(not missing,'QA26: thieu cot '+','.join(missing)+
            ' trong dbo.EnvironmentThresholds - hay chay database/alter_table.sql '
            '(migration P1) truoc khi test')
    f=fixture(c)
    c.execute("UPDATE dbo.Zones SET Status='ACTIVE' WHERE ZoneId=?",f['zone'])
    c.execute("UPDATE dbo.Devices SET Status='ACTIVE' WHERE DeviceId=?",f['device'])
    light=insert_id(c,"INSERT dbo.Devices(ZoneId,DeviceName,DeviceType) OUTPUT inserted.DeviceId VALUES (?,N'QA26 light','LIGHT')",f['zone'])
    c.execute("UPDATE dbo.Devices SET Status='ACTIVE' WHERE DeviceId=?",light)

    # 1. Nguong sang luu/doc lai dung qua 2 procedure nguong.
    token=scalar(c,'SELECT RowVer FROM dbo.EnvironmentThresholds WHERE ZoneId=?',f['zone'])
    updated=one(c,"""EXEC dbo.sp_UpdateEnvironmentThreshold
        @ZoneId=?,@MinTemperature=25,@MaxTemperature=33,@MinHumidity=65,@MaxHumidity=95,
        @ExpectedRowVer=?,@UserId=?,@MinLightLux=100,@MaxLightLux=500""",
        f['zone'],token,f['user'])
    require(updated['Success']==1 and updated['Code']=='OK',
            'QA26 cap nhat nguong sang that bai: '+str(updated))
    stored=one(c,'SELECT MinLightLux,MaxLightLux FROM dbo.EnvironmentThresholds WHERE ZoneId=?',f['zone'])
    require((float(stored['MinLightLux']),float(stored['MaxLightLux']))==(100.0,500.0),
            'QA26 nguong sang khong duoc luu: '+str(stored))
    got=one(c,'EXEC dbo.sp_GetEnvironmentThreshold @ZoneId=?',f['zone'])
    require(got['Code']=='OK' and (float(got['MinLightLux']),float(got['MaxLightLux']))==(100.0,500.0),
            'QA26 getter khong tra nguong sang: '+str(got))

    c.execute("INSERT dbo.DeviceControlSettings(DeviceId,DeviceType,ControlMode,IsOn) VALUES (?,N'LIGHT',N'AUTO',0)",light)

    def auto(lux):
        rid=reading(c,f,28,80,str(uuid.uuid4()),None,lux)['ReadingId']
        return one(c,"""EXEC dbo.sp_SimulateDeviceControl
            @DeviceId=?,@UserId=?,@Action='AUTO',@ReadingId=?""",light,f['user'],rid)

    def logs():
        return scalar(c,'SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=?',light)

    # 2. Toi (lux < Min): bat den va ghi dung 1 log TURN_ON.
    dark=auto(50)
    require(dark['Success']==1 and dark['Code']=='OK' and dark['IsOn']==1
            and dark['StateChanged']==1 and dark['Changed']==1,
            'QA26 lux=50 phai bat den: '+str(dark))
    require(logs()==1 and scalar(c,"SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=? AND Command='TURN_ON'",light)==1,
            'QA26 TURN_ON phai duoc ghi dung 1 lan')

    # 3. Trong khoang (Min < lux < Max): giu ON, khong ghi them log.
    middle=auto(300)
    require(middle['Code']=='OK' and middle['IsOn']==1
            and middle['StateChanged']==0 and middle['Changed']==0,
            'QA26 lux=300 phai giu ON (hysteresis): '+str(middle))
    require(logs()==1,'QA26 hysteresis khong duoc ghi them log')

    # 4. Sang (lux > Max): tat den va ghi dung 1 log TURN_OFF.
    bright=auto(800)
    require(bright['Code']=='OK' and bright['IsOn']==0
            and bright['StateChanged']==1 and bright['Changed']==1,
            'QA26 lux=800 phai tat den: '+str(bright))
    require(logs()==2 and scalar(c,"SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId=? AND Command='TURN_OFF'",light)==1,
            'QA26 TURN_OFF phai duoc ghi dung 1 lan')

    # 5. Bang nguong thi giu nguyen trang thai.
    require(auto(50)['IsOn']==1,'QA26 chuan bi ON truoc khi test bien')
    at_max=auto(500)
    require(at_max['IsOn']==1 and at_max['StateChanged']==0,
            'QA26 lux=Max khi dang ON phai giu ON: '+str(at_max))
    require(auto(800)['IsOn']==0,'QA26 chuan bi OFF truoc khi test bien')
    at_min=auto(100)
    require(at_min['IsOn']==0 and at_min['StateChanged']==0,
            'QA26 lux=Min khi dang OFF phai giu OFF: '+str(at_min))
    require(logs()==4,'QA26 chi 4 lan doi trang thai duoc ghi log')
    after_thresholds=logs()

    # 6. Moi lan AUTO phai dung reading moi nhat (chong STALE_READING).
    old=reading(c,f,28,80,str(uuid.uuid4()),None,800)['ReadingId']
    fresh=reading(c,f,28,80,str(uuid.uuid4()),None,50)['ReadingId']
    stale=one(c,"""EXEC dbo.sp_SimulateDeviceControl
        @DeviceId=?,@UserId=?,@Action='AUTO',@ReadingId=?""",light,f['user'],old)
    require(stale['Code']=='STALE_READING',
            'QA26 reading cu phai bi tu choi STALE_READING: '+str(stale))
    applied=one(c,"""EXEC dbo.sp_SimulateDeviceControl
        @DeviceId=?,@UserId=?,@Action='AUTO',@ReadingId=?""",light,f['user'],fresh)
    require(applied['Code']=='OK' and applied['IsOn']==1,
            'QA26 phai dung reading moi nhat: '+str(applied))
    require(logs()==after_thresholds+1,'QA26 reading moi nhat phai ghi dung 1 log')

    # Thieu so do anh sang (NULL) la READING_UNAVAILABLE, khong phai 0 lux.
    no_lux=auto(None)
    require(no_lux['Code']=='READING_UNAVAILABLE' and no_lux['Success']==0,
            'QA26 NULL lux phai la READING_UNAVAILABLE: '+str(no_lux))


AUTOMATED={
    1:test_01,2:test_02,3:test_03,4:test_04,5:test_05,6:test_06,
    7:test_07,8:test_08,9:test_09,10:test_10,11:test_11,12:test_12,
    13:test_13,14:test_14,15:test_15,16:test_16,17:test_17,18:test_18,
    19:test_19,
    23:test_23,25:test_25,26:test_26,
}
MANUAL={
    20:'Use separate STAFF/ADMIN/Ingest logins; never simulate permissions with an admin connection',
    21:'Two simultaneous SQL sessions must race to ACK a committed QA incident',
    22:'Two independent sessions must demonstrate stale RowVer (CONCURRENCY_CONFLICT)',
    24:'Requires live simulator -> API -> database -> UI and screenshots/HTTP outcomes',
}


def main():
    p=argparse.ArgumentParser(description='TV4 SQL QA (22 automated + 4 NOT TESTED/manual)')
    p.add_argument('--strict',action='store_true',help='non-zero if any NOT TESTED')
    args=p.parse_args()
    connection_string=os.getenv('QA_CONN_STR')
    if not connection_string:
        print('Set QA_CONN_STR to a SQL Server ODBC connection string to your *_QA or *_Test database.',file=sys.stderr)
        return 2
    summary=Counter()
    print('TV4 QA | started at',datetime.now().isoformat(timespec='seconds'))
    try:
        guard=pyodbc.connect(connection_string,autocommit=False,timeout=10)
        try:
            db=scalar(guard.cursor(),'SELECT DB_NAME()')
            if not db.lower().endswith(('_qa','_test')):
                raise ValueError('Refusing to run on '+db+'; use a separate *_QA or *_Test database')
            print('Database:',db,'| code tests use per-test ROLLBACK')
        finally:
            guard.rollback()
            guard.close()
    except Exception as e:
        print('PREFLIGHT FAIL:',type(e).__name__,e,file=sys.stderr)
        return 2
    for number in range(1,27):
        name=f'QA{number:02d}'
        if number in MANUAL:
            summary['NOT TESTED']+=1
            print(name,'NOT TESTED —',MANUAL[number]); continue
        conn=None
        try:
            conn=pyodbc.connect(connection_string,autocommit=False,timeout=20)
            cur=conn.cursor()
            cur.execute('SET XACT_ABORT OFF; SET NOCOUNT ON; SET LOCK_TIMEOUT 15000;')
            AUTOMATED[number](cur)
            summary['PASS']+=1
            print(name,'PASS')
        except Exception as e:
            summary['FAIL']+=1
            print(name,'FAIL —',type(e).__name__,str(e).replace('\n',' ')[:400])
        finally:
            if conn is not None:
                try:
                    conn.rollback()
                finally:
                    conn.close()
    print(f"TOTAL: PASS={summary['PASS']} FAIL={summary['FAIL']} NOT TESTED={summary['NOT TESTED']}")
    print('This is code-prepared QA; actual PASS is only established by running in your environment.')
    if summary['FAIL']:
        return 1
    if args.strict and summary['NOT TESTED']:
        return 2
    return 0


if __name__=='__main__':
    sys.exit(main())
