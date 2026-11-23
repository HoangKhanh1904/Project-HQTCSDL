/*
TV4 - nhanzza | SwiftletCare Analytics & QA
Compatible with the baseline schema and database/application_extension.sql (2026).
Deploy in the TARGET database (sqlcmd -d SwiftletCare_QA -i ...), NO USE statement.
No DML, schema migration, procedure replacement, or hard-coded alert counts.
All time windows are half-open [StartAt, EndAt); the database's RecordeAt
is a legacy server-local timestamp; bird/event timestamps use Asia/Saigon.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* Retain legacy demo signature for callers; never use this fixed-threshold
   teaching function in production analytics. */
CREATE OR ALTER FUNCTION dbo.fn_KiemTraMoiTruong
(
    @NhietDo DECIMAL(5,2), @DoAm DECIMAL(5,2)
)
RETURNS NVARCHAR(30)
AS
BEGIN
    IF @NhietDo IS NULL OR @DoAm IS NULL RETURN N'Chưa có dữ liệu';
    IF @NhietDo NOT BETWEEN -40 AND 100 OR @DoAm NOT BETWEEN 0 AND 100
        RETURN N'Không hợp lệ';
    IF @NhietDo NOT BETWEEN 26 AND 32 OR @DoAm NOT BETWEEN 70 AND 90
        RETURN N'Bất thường';
    RETURN N'Bình thường';
END;
GO

/* Multi-flag classifier: preserves simultaneous T/H violations. */
CREATE OR ALTER FUNCTION dbo.fn_QAClassifyReading
(
    @Temperature DECIMAL(5,2), @Humidity DECIMAL(5,2),
    @MinT DECIMAL(5,2), @MaxT DECIMAL(5,2),
    @MinH DECIMAL(5,2), @MaxH DECIMAL(5,2)
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        CASE WHEN @Temperature IS NULL OR @Humidity IS NULL THEN 'NO_DATA'
             WHEN @Temperature NOT BETWEEN -40 AND 100 OR @Humidity NOT BETWEEN 0 AND 100
                  THEN 'INVALID_INPUT'
             WHEN @MinT IS NULL OR @MaxT IS NULL OR @MinH IS NULL OR @MaxH IS NULL
                  THEN 'UNCONFIGURED'
             WHEN @MinT > @MaxT OR @MinH > @MaxH THEN 'INVALID_THRESHOLD'
             WHEN @Temperature < @MinT OR @Temperature > @MaxT
                OR @Humidity < @MinH OR @Humidity > @MaxH THEN 'WARNING'
             ELSE 'NORMAL' END AS EnvironmentStatus,
        CONVERT(BIT, CASE WHEN @Temperature < @MinT THEN 1 ELSE 0 END) AS IsLowTemp,
        CONVERT(BIT, CASE WHEN @Temperature > @MaxT THEN 1 ELSE 0 END) AS IsHighTemp,
        CONVERT(BIT, CASE WHEN @Humidity < @MinH THEN 1 ELSE 0 END) AS IsLowHumidity,
        CONVERT(BIT, CASE WHEN @Humidity > @MaxH THEN 1 ELSE 0 END) AS IsHighHumidity
);
GO

/* Keep the existing function name for backward compatibility. */
CREATE OR ALTER FUNCTION dbo.fn_KiemTraMoiTruongTheoZone
(
    @ZoneId INT, @NhietDo DECIMAL(5,2), @DoAm DECIMAL(5,2)
)
RETURNS NVARCHAR(30)
AS
BEGIN
    DECLARE @MinT DECIMAL(5,2), @MaxT DECIMAL(5,2),
            @MinH DECIMAL(5,2), @MaxH DECIMAL(5,2), @State NVARCHAR(30);
    IF @NhietDo IS NULL OR @DoAm IS NULL RETURN N'Chưa có dữ liệu';
    IF @NhietDo NOT BETWEEN -40 AND 100 OR @DoAm NOT BETWEEN 0 AND 100
        RETURN N'Dữ liệu không hợp lệ';
    IF @ZoneId IS NULL RETURN N'Chưa cấu hình';
    SELECT @MinT=MinTemperature, @MaxT=MaxTemperature,
           @MinH=MinHumidity, @MaxH=MaxHumidity
    FROM dbo.EnvironmentThresholds WHERE ZoneId=@ZoneId;
    IF @MinT IS NULL OR @MaxT IS NULL OR @MinH IS NULL OR @MaxH IS NULL
        RETURN N'Chưa cấu hình';
    IF @MinT>@MaxT OR @MinH>@MaxH RETURN N'Dữ liệu không hợp lệ';
    SET @State = CASE WHEN @NhietDo<@MinT OR @NhietDo>@MaxT
                         OR @DoAm<@MinH OR @DoAm>@MaxH
                      THEN N'Bất thường' ELSE N'Bình thường' END;
    RETURN @State;
END;
GO

/* History / abnormal CTE source. Requires application_extension.sql.
   NULL CO2Ppm/LightLux denotes no measurement (never substitute 0). */
CREATE OR ALTER FUNCTION dbo.fn_QAReadings
(
    @HouseId INT, @ZoneId INT, @DeviceId INT,
    @StartAt DATETIME2, @EndAt DATETIME2
)
RETURNS TABLE
AS
RETURN
(
    SELECT h.HouseId, h.HouseName, z.ZoneId, z.ZoneName,
           d.DeviceId, d.DeviceName, r.ReadingId, r.RecordeAt,
           r.Temperature, r.Humidity, r.CO2Ppm, r.LightLux,
           c.EnvironmentStatus, c.IsLowTemp, c.IsHighTemp,
           c.IsLowHumidity, c.IsHighHumidity
    FROM dbo.SensorReadings r
    JOIN dbo.Devices d ON d.DeviceId=r.DeviceId AND d.DeviceType='SENSOR'
    JOIN dbo.Zones z ON z.ZoneId=d.ZoneId
    JOIN dbo.SwiftletHouses h ON h.HouseId=z.HouseId
    LEFT JOIN dbo.EnvironmentThresholds t ON t.ZoneId=z.ZoneId
    CROSS APPLY dbo.fn_QAClassifyReading(r.Temperature,r.Humidity,
        t.MinTemperature,t.MaxTemperature,t.MinHumidity,t.MaxHumidity) c
    WHERE (@HouseId IS NULL OR h.HouseId=@HouseId)
      AND (@ZoneId IS NULL OR z.ZoneId=@ZoneId)
      AND (@DeviceId IS NULL OR d.DeviceId=@DeviceId)
      AND (@StartAt IS NULL OR r.RecordeAt>=@StartAt)
      AND (@EndAt IS NULL OR r.RecordeAt<@EndAt)
      AND (@StartAt IS NULL OR @EndAt IS NULL OR @StartAt<@EndAt)
);
GO

/* Latest reading per sensor. Sensors with no measurements remain visible.
   Deterministic tie-break is ReadingId DESC. */
CREATE OR ALTER FUNCTION dbo.fn_QALatestReadings
(
    @HouseId INT, @ZoneId INT, @DeviceId INT,
    @StartAt DATETIME2, @EndAt DATETIME2
)
RETURNS TABLE
AS
RETURN
(
    WITH Ranked AS (
        SELECT r.DeviceId,r.ReadingId,r.RecordeAt,r.Temperature,r.Humidity,
               r.CO2Ppm,r.LightLux,
               ROW_NUMBER() OVER (PARTITION BY r.DeviceId
                   ORDER BY r.RecordeAt DESC,r.ReadingId DESC) AS rn
        FROM dbo.SensorReadings r
        WHERE (@StartAt IS NULL OR r.RecordeAt>=@StartAt)
          AND (@EndAt IS NULL OR r.RecordeAt<@EndAt)
    )
    SELECT h.HouseId,z.ZoneId,d.DeviceId,d.DeviceName,
           r.ReadingId,r.RecordeAt,r.Temperature,r.Humidity,r.CO2Ppm,r.LightLux,
           CASE WHEN r.ReadingId IS NULL THEN 'NO_DATA'
                ELSE c.EnvironmentStatus END AS EnvironmentStatus,
           c.IsLowTemp,c.IsHighTemp,c.IsLowHumidity,c.IsHighHumidity
    FROM dbo.Devices d
    JOIN dbo.Zones z ON z.ZoneId=d.ZoneId
    JOIN dbo.SwiftletHouses h ON h.HouseId=z.HouseId
    LEFT JOIN Ranked r ON r.DeviceId=d.DeviceId AND r.rn=1
    LEFT JOIN dbo.EnvironmentThresholds t ON t.ZoneId=z.ZoneId
    CROSS APPLY dbo.fn_QAClassifyReading(r.Temperature,r.Humidity,
        t.MinTemperature,t.MaxTemperature,t.MinHumidity,t.MaxHumidity) c
    WHERE d.DeviceType='SENSOR'
      AND (@HouseId IS NULL OR h.HouseId=@HouseId)
      AND (@ZoneId IS NULL OR z.ZoneId=@ZoneId)
      AND (@DeviceId IS NULL OR d.DeviceId=@DeviceId)
      AND (@StartAt IS NULL OR @EndAt IS NULL OR @StartAt<@EndAt)
);
GO

/* Aggregate readings, including a sensor without readings. */
CREATE OR ALTER FUNCTION dbo.fn_QAEnvironmentSummary
(
    @HouseId INT, @ZoneId INT, @DeviceId INT,
    @StartAt DATETIME2, @EndAt DATETIME2
)
RETURNS TABLE
AS
RETURN
(
    SELECT h.HouseId,z.ZoneId,d.DeviceId,d.DeviceName,
           COUNT_BIG(r.ReadingId) AS ReadingCount,
           AVG(CONVERT(DECIMAL(18,4),r.Temperature)) AS AvgTemperature,
           MIN(r.Temperature) AS MinTemperature, MAX(r.Temperature) AS MaxTemperature,
           AVG(CONVERT(DECIMAL(18,4),r.Humidity)) AS AvgHumidity,
           MIN(r.Humidity) AS MinHumidity, MAX(r.Humidity) AS MaxHumidity,
           AVG(CONVERT(DECIMAL(18,4),r.CO2Ppm)) AS AvgCO2Ppm,
           AVG(CONVERT(DECIMAL(18,4),r.LightLux)) AS AvgLightLux,
           MAX(r.RecordeAt) AS LastRecordedAt,
           SUM(CASE WHEN c.EnvironmentStatus='WARNING' THEN CONVERT(BIGINT,1) ELSE CONVERT(BIGINT,0) END) AS AbnormalReadingCount,
           CONVERT(DECIMAL(8,2),CASE WHEN COUNT_BIG(r.ReadingId)=0 THEN NULL
               ELSE 100.0*SUM(CASE WHEN c.EnvironmentStatus='WARNING' THEN 1 ELSE 0 END)/COUNT_BIG(r.ReadingId) END) AS AbnormalRatePct,
           CASE WHEN COUNT_BIG(r.ReadingId)=0 THEN 'NO_DATA'
                WHEN t.ZoneId IS NULL THEN 'UNCONFIGURED'
                WHEN SUM(CASE WHEN c.EnvironmentStatus='WARNING' THEN 1 ELSE 0 END)>0 THEN 'WARNING'
                ELSE 'NORMAL' END AS SummaryStatus
    FROM dbo.Devices d
    JOIN dbo.Zones z ON z.ZoneId=d.ZoneId
    JOIN dbo.SwiftletHouses h ON h.HouseId=z.HouseId
    LEFT JOIN dbo.EnvironmentThresholds t ON t.ZoneId=z.ZoneId
    LEFT JOIN dbo.SensorReadings r ON r.DeviceId=d.DeviceId
        AND (@StartAt IS NULL OR r.RecordeAt>=@StartAt)
        AND (@EndAt IS NULL OR r.RecordeAt<@EndAt)
    CROSS APPLY dbo.fn_QAClassifyReading(r.Temperature,r.Humidity,
        t.MinTemperature,t.MaxTemperature,t.MinHumidity,t.MaxHumidity) c
    WHERE d.DeviceType='SENSOR'
      AND (@HouseId IS NULL OR h.HouseId=@HouseId)
      AND (@ZoneId IS NULL OR z.ZoneId=@ZoneId)
      AND (@DeviceId IS NULL OR d.DeviceId=@DeviceId)
      AND (@StartAt IS NULL OR @EndAt IS NULL OR @StartAt<@EndAt)
    GROUP BY h.HouseId,z.ZoneId,d.DeviceId,d.DeviceName,t.ZoneId
);
GO

/* Alerts count INCIDENTS, NOT number of abnormal readings. */
CREATE OR ALTER FUNCTION dbo.fn_QAAlertSummary
(
    @HouseId INT, @ZoneId INT, @StartAt DATETIME2, @EndAt DATETIME2
)
RETURNS TABLE
AS
RETURN
(
    SELECT h.HouseId,z.ZoneId,a.AlertType,a.Status,
           CONVERT(DATE,a.CreatedAt) AS AlertDate,
           COUNT_BIG(*) AS IncidentCount
    FROM dbo.Alerts a
    JOIN dbo.Zones z ON z.ZoneId=a.ZoneId
    JOIN dbo.SwiftletHouses h ON h.HouseId=z.HouseId
    WHERE (@HouseId IS NULL OR h.HouseId=@HouseId)
      AND (@ZoneId IS NULL OR z.ZoneId=@ZoneId)
      AND (@StartAt IS NULL OR a.CreatedAt>=@StartAt)
      AND (@EndAt IS NULL OR a.CreatedAt<@EndAt)
      AND (@StartAt IS NULL OR @EndAt IS NULL OR @StartAt<@EndAt)
    GROUP BY h.HouseId,z.ZoneId,a.AlertType,a.Status,CONVERT(DATE,a.CreatedAt)
);
GO

/* Bird events are local Asia/Saigon wall-clock; zero-traffic days included.
   At most 3661 days; intentionally no fake resident bird estimates. */
CREATE OR ALTER FUNCTION dbo.fn_QABirdDaily
(
    @HouseId INT, @StartAt DATETIME2, @EndAt DATETIME2,
    @SourceType VARCHAR(10)
)
RETURNS TABLE
AS
RETURN
(
    WITH Dates AS (
        SELECT TOP (
            CASE WHEN @StartAt IS NULL OR @EndAt IS NULL OR @StartAt>=@EndAt
                   OR DATEDIFF(DAY,@StartAt,@EndAt)>3660 THEN 0
                 ELSE DATEDIFF(DAY,CONVERT(DATE,@StartAt),CONVERT(DATE,@EndAt))+1 END
        ) ROW_NUMBER() OVER (ORDER BY a.object_id,b.object_id)-1 AS DayNo
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    ),
    Calendar AS (
        SELECT CONVERT(DATE,DATEADD(DAY,CONVERT(INT,DayNo),CONVERT(DATE,@StartAt))) AS ObservedDate
        FROM Dates
        WHERE DATEADD(DAY,CONVERT(INT,DayNo),CONVERT(DATE,@StartAt)) < @EndAt
    ),
    Aggregated AS (
        SELECT b.HouseId,CONVERT(DATE,b.ObservedAt) AS ObservedDate,
               SUM(CASE WHEN b.Direction='IN' THEN CONVERT(BIGINT,b.BirdCount) ELSE CONVERT(BIGINT,0) END) AS InCount,
               SUM(CASE WHEN b.Direction='OUT' THEN CONVERT(BIGINT,b.BirdCount) ELSE CONVERT(BIGINT,0) END) AS OutCount,
               COUNT_BIG(*) AS EventCount
        FROM dbo.BirdMovementEvents b
        WHERE b.ObservedAt>=@StartAt AND b.ObservedAt<@EndAt
          AND (@HouseId IS NULL OR b.HouseId=@HouseId)
          AND (@SourceType IS NULL OR b.SourceType=@SourceType)
        GROUP BY b.HouseId,CONVERT(DATE,b.ObservedAt)
    )
    SELECT h.HouseId,h.HouseName,c.ObservedDate,
           COALESCE(a.InCount,CONVERT(BIGINT,0)) AS InCount,
           COALESCE(a.OutCount,CONVERT(BIGINT,0)) AS OutCount,
           COALESCE(a.InCount,CONVERT(BIGINT,0))-COALESCE(a.OutCount,CONVERT(BIGINT,0)) AS NetMovement,
           COALESCE(a.EventCount,CONVERT(BIGINT,0)) AS EventCount,
           CONVERT(VARCHAR(32),'Asia/Saigon') AS TimeZone
    FROM dbo.SwiftletHouses h CROSS JOIN Calendar c
    LEFT JOIN Aggregated a ON a.HouseId=h.HouseId AND a.ObservedDate=c.ObservedDate
    WHERE (@HouseId IS NULL OR h.HouseId=@HouseId)
);
GO

CREATE OR ALTER FUNCTION dbo.fn_QASimulatedEventSummary
(
    @HouseId INT,@ZoneId INT,@StartAt DATETIME2,@EndAt DATETIME2
)
RETURNS TABLE
AS
RETURN
(
    SELECT h.HouseId,e.ZoneId,e.EventType,e.Status,e.Severity,
           CONVERT(DATE,e.EventAt) AS EventDate,COUNT_BIG(*) AS EventCount
    FROM dbo.SimulatedSystemEvents e
    JOIN dbo.SwiftletHouses h ON h.HouseId=e.HouseId
    WHERE e.SourceType='SIMULATED'
      AND (@HouseId IS NULL OR e.HouseId=@HouseId)
      AND (@ZoneId IS NULL OR e.ZoneId=@ZoneId)
      AND (@StartAt IS NULL OR e.EventAt>=@StartAt)
      AND (@EndAt IS NULL OR e.EventAt<@EndAt)
      AND (@StartAt IS NULL OR @EndAt IS NULL OR @StartAt<@EndAt)
    GROUP BY h.HouseId,e.ZoneId,e.EventType,e.Status,e.Severity,CONVERT(DATE,e.EventAt)
);
GO

/* Runnable analytics examples; adjust these variables to filter.
   History CTE and ranking CTE are genuine business queries. */
DECLARE @HouseId INT=NULL,@ZoneId INT=NULL,@DeviceId INT=NULL;
DECLARE @StartAt DATETIME2=DATEADD(DAY,-7,SYSDATETIME()), @EndAt DATETIME2=SYSDATETIME();
IF @StartAt>=@EndAt THROW 53001,'Invalid analytics time window',1;

SELECT * FROM dbo.fn_QAEnvironmentSummary(@HouseId,@ZoneId,@DeviceId,@StartAt,@EndAt)
ORDER BY HouseId,ZoneId,DeviceId;

SELECT * FROM dbo.fn_QALatestReadings(@HouseId,@ZoneId,@DeviceId,@StartAt,@EndAt)
ORDER BY HouseId,ZoneId,DeviceId;

;WITH AbnormalHistory AS (
    SELECT * FROM dbo.fn_QAReadings(@HouseId,@ZoneId,@DeviceId,@StartAt,@EndAt)
    WHERE EnvironmentStatus='WARNING'
)
SELECT ReadingId,ZoneId,DeviceId,RecordeAt,Temperature,Humidity,
       IsLowTemp,IsHighTemp,IsLowHumidity,IsHighHumidity
FROM AbnormalHistory ORDER BY RecordeAt DESC,ReadingId DESC;

SELECT * FROM dbo.fn_QAAlertSummary(@HouseId,@ZoneId,@StartAt,@EndAt)
ORDER BY IncidentCount DESC,ZoneId,AlertType,Status;

;WITH ZoneIncidentCounts AS (
    SELECT h.HouseId,h.HouseName,z.ZoneId,z.ZoneName,
           COUNT_BIG(a.AlertId) AS IncidentCount,
           SUM(CASE WHEN a.Status='PENDING' THEN CONVERT(BIGINT,1) ELSE CONVERT(BIGINT,0) END) AS PendingCount,
           SUM(CASE WHEN a.Status='RESOLVED' THEN CONVERT(BIGINT,1) ELSE CONVERT(BIGINT,0) END) AS ResolvedCount
    FROM dbo.Zones z
    JOIN dbo.SwiftletHouses h ON h.HouseId=z.HouseId
    LEFT JOIN dbo.Alerts a ON a.ZoneId=z.ZoneId
        AND (@StartAt IS NULL OR a.CreatedAt>=@StartAt)
        AND (@EndAt IS NULL OR a.CreatedAt<@EndAt)
    WHERE (@HouseId IS NULL OR h.HouseId=@HouseId)
      AND (@ZoneId IS NULL OR z.ZoneId=@ZoneId)
    GROUP BY h.HouseId,h.HouseName,z.ZoneId,z.ZoneName
), RankedZones AS (
    SELECT *,DENSE_RANK() OVER(PARTITION BY HouseId ORDER BY IncidentCount DESC) AS RankInHouse
    FROM ZoneIncidentCounts
)
SELECT * FROM RankedZones ORDER BY HouseId,RankInHouse,ZoneId;

-- Bird times are Asia/Saigon; use explicit day boundaries instead of server-local SYSDATETIME.
DECLARE @BirdStart DATETIME2=CONVERT(DATE,DATEADD(DAY,-6,DATEADD(HOUR,7,SYSUTCDATETIME())));
DECLARE @BirdEnd DATETIME2=DATEADD(DAY,7,@BirdStart);
SELECT * FROM dbo.fn_QABirdDaily(@HouseId,@BirdStart,@BirdEnd,'SIMULATED')
ORDER BY HouseId,ObservedDate;
SELECT * FROM dbo.fn_QASimulatedEventSummary(@HouseId,@ZoneId,@BirdStart,@BirdEnd)
ORDER BY HouseId,ZoneId,EventDate;
GO
