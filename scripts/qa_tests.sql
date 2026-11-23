SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() NOT LIKE '%[_]QA'
   AND DB_NAME() NOT LIKE '%[_]Test'
   AND NOT (
       DB_NAME() LIKE 'SwiftletCare[_]AppTest[_]%'
       AND LEN(DB_NAME()) = LEN('SwiftletCare_AppTest_') + 12
       AND RIGHT(DB_NAME(), 12) NOT LIKE '%[^0-9a-f]%'
   )
    THROW 53100, 'QA database name is not allowed.', 1;

DECLARE @Required TABLE (TableName SYSNAME PRIMARY KEY);
INSERT @Required(TableName) VALUES
 ('Users'),('SwiftletHouses'),('Zones'),('Devices'),('SensorReadings'),
 ('EnvironmentThresholds'),('Alerts'),('AlertActions'),('ControlLogs'),
 ('BirdMovementEvents'),('SimulatedSystemEvents'),('DeviceControlSettings');
IF EXISTS (SELECT 1 FROM @Required WHERE OBJECT_ID(N'dbo.'+TableName,'U') IS NULL)
BEGIN
    SELECT r.TableName,'FAIL: MISSING TABLE' AS Result
    FROM @Required r WHERE OBJECT_ID(N'dbo.'+r.TableName,'U') IS NULL;
    THROW 53101,'QA02 FAIL: required migration table missing',1;
END;
IF COL_LENGTH('dbo.SensorReadings','CO2Ppm') IS NULL
    OR COL_LENGTH('dbo.SensorReadings','LightLux') IS NULL
    OR COL_LENGTH('dbo.SensorReadings','SourceEventId') IS NULL
    THROW 53102,'QA02 FAIL: sensor migration columns missing',1;
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id=OBJECT_ID('dbo.SensorReadings')
                 AND referenced_object_id=OBJECT_ID('dbo.Devices'))
    OR NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID('dbo.SensorReadings'))
    OR NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id=OBJECT_ID('dbo.SensorReadings') AND type='PK')
    THROW 53103,'QA02 FAIL: expected reading PK/FK/CHECK missing',1;
PRINT 'QA02 BASELINE SCHEMA: PASS';

DECLARE @Expected TABLE (
    IndexName SYSNAME PRIMARY KEY,TableName SYSNAME NOT NULL,
    KeyColumns VARCHAR(400) NOT NULL,IncludeColumns VARCHAR(400) NOT NULL,
    IsUnique BIT NOT NULL, FilterNormalized VARCHAR(400) NOT NULL
);
INSERT @Expected VALUES
 ('IX_Readings_Device_Time','SensorReadings','DeviceId:0,RecordeAt:1,ReadingId:1','Humidity,Temperature',0,''),
 ('IX_Alerts_Zone_Status','Alerts','ZoneId:0,Status:0','',0,''),
 ('IX_AlertActions_Alert_Time','AlertActions','AlertId:0,ActionAt:0,ActionId:0','',0,''),
 ('UX_Readings_Device_Event','SensorReadings','DeviceId:0,SourceEventId:0','',1,'SOURCEEVENTIDISNOTNULL');

;WITH IndexMetadata AS (
    SELECT e.IndexName,e.TableName,e.KeyColumns,e.IncludeColumns,e.IsUnique,e.FilterNormalized,
           i.index_id,i.type,i.is_unique,i.is_disabled,i.is_hypothetical,i.has_filter,
           COALESCE(k.KeyList,'') AS ActualKeys,
           COALESCE(inc.IncludeList,'') AS ActualIncludes,
           UPPER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
               COALESCE(i.filter_definition,''),'[',''),']',''),'(',''),')',''),' ',''),CHAR(10),''),CHAR(13),'')) AS ActualFilter
    FROM @Expected e
    LEFT JOIN sys.indexes i
      ON i.object_id=OBJECT_ID(N'dbo.'+e.TableName) AND i.name=e.IndexName
    OUTER APPLY (
        SELECT STRING_AGG(CONCAT(c.name,':',ic.is_descending_key),',')
               WITHIN GROUP (ORDER BY ic.key_ordinal) AS KeyList
        FROM sys.index_columns ic JOIN sys.columns c
          ON c.object_id=ic.object_id AND c.column_id=ic.column_id
        WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.key_ordinal>0
    ) k
    OUTER APPLY (
        SELECT STRING_AGG(c.name,',') WITHIN GROUP (ORDER BY c.name) AS IncludeList
        FROM sys.index_columns ic JOIN sys.columns c
          ON c.object_id=ic.object_id AND c.column_id=ic.column_id
        WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=1
    ) inc
), Results AS (
    SELECT IndexName,TableName,ActualKeys,ActualIncludes,ActualFilter,
           CASE WHEN index_id IS NOT NULL AND type=2 AND is_unique=IsUnique
                AND is_disabled=0 AND is_hypothetical=0
                AND ActualKeys=KeyColumns AND ActualIncludes=IncludeColumns
                AND ActualFilter=FilterNormalized
                AND has_filter=CASE WHEN FilterNormalized='' THEN 0 ELSE 1 END
                THEN 'PASS' ELSE 'FAIL' END AS Result
    FROM IndexMetadata
)
SELECT * INTO #QA_IndexResults FROM Results;
SELECT * FROM #QA_IndexResults ORDER BY IndexName;
IF (SELECT COUNT(*) FROM #QA_IndexResults WHERE Result='PASS')<>4
BEGIN
    DROP TABLE #QA_IndexResults;
    THROW 53123,'QA23 FAIL: index absent or key/include/order/unique/filter wrong',1;
END;
DROP TABLE #QA_IndexResults;
PRINT 'QA23 INDEX STRUCTURE: PASS (4/4)';
GO
