
USE SwiftletCare;
GO

-- Q01
SELECT
    h.HouseId,
    h.HouseName,
    h.Address,
    u.FullName AS ManagerName,
    h.Status
FROM dbo.SwiftletHouses h
INNER JOIN dbo.Users u ON h.ManagerId = u.UserID
ORDER BY h.HouseName;

-- Q02
SELECT
    z.ZoneId,
    z.ZoneName,
    h.HouseName,
    z.Description,
    z.Status
FROM dbo.Zones z
INNER JOIN dbo.SwiftletHouses h ON z.HouseId = h.HouseId
WHERE h.HouseId = 1;

-- Q03
SELECT
    d.DeviceId,
    d.DeviceName,
    d.DeviceType,
    d.Status,
    z.ZoneName,
    h.HouseName
FROM dbo.Devices d
INNER JOIN dbo.Zones z ON d.ZoneId = z.ZoneId
INNER JOIN dbo.SwiftletHouses h ON z.HouseId = h.HouseId;

-- Q04
SELECT
    u.UserID,
    u.UserName,
    u.FullName,
    u.Role
FROM dbo.Users u
LEFT JOIN dbo.SwiftletHouses h ON u.UserID = h.ManagerId
WHERE h.HouseId IS NULL;

-- Q05
SELECT
    z.ZoneId,
    z.ZoneName,
    h.HouseName
FROM dbo.Zones z
INNER JOIN dbo.SwiftletHouses h ON z.HouseId = h.HouseId
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.Devices d
    WHERE d.ZoneId = z.ZoneId
      AND d.DeviceType = 'SENSOR'
);

-- Q06
SELECT TOP 10
    r.ReadingId,
    r.DeviceId,
    r.Temperature,
    r.Humidity,
    r.RecordeAt
FROM dbo.SensorReadings r
INNER JOIN dbo.Devices d ON r.DeviceId = d.DeviceId
WHERE r.DeviceId = 1
  AND d.DeviceType = 'SENSOR'
ORDER BY r.RecordeAt DESC, r.ReadingId DESC;

-- Q07
WITH LatestReadings AS (
    SELECT
        d.DeviceId,
        d.DeviceName,
        r.Temperature,
        r.Humidity,
        r.RecordeAt,
        ROW_NUMBER() OVER (
            PARTITION BY d.DeviceId
            ORDER BY r.RecordeAt DESC, r.ReadingId DESC
        ) AS RowNum
    FROM dbo.Devices d
    INNER JOIN dbo.SensorReadings r ON d.DeviceId = r.DeviceId
    WHERE d.DeviceType = 'SENSOR'
)
SELECT
    DeviceId,
    DeviceName,
    Temperature,
    Humidity,
    RecordeAt
FROM LatestReadings
WHERE RowNum = 1;


-- Q08
DECLARE @DeviceId INT = 1;
DECLARE @StartTime DATETIME2 = DATEADD(DAY, -7, SYSDATETIME());
DECLARE @EndTime DATETIME2 = SYSDATETIME();

SELECT
    r.ReadingId,
    r.DeviceId,
    r.Temperature,
    r.Humidity,
    r.RecordeAt
FROM dbo.SensorReadings AS r
WHERE r.DeviceId = @DeviceId
  AND r.RecordeAt >= @StartTime
  AND r.RecordeAt < @EndTime
ORDER BY r.RecordeAt ASC, r.ReadingId ASC;


-- Q09
SELECT
    d.DeviceId,
    d.DeviceName,
    AVG(r.Temperature) AS AvgTemperature,
    MIN(r.Temperature) AS MinTemperature,
    MAX(r.Temperature) AS MaxTemperature,
    AVG(r.Humidity) AS AvgHumidity,
    MIN(r.Humidity) AS MinHumidity,
    MAX(r.Humidity) AS MaxHumidity
FROM dbo.Devices d
INNER JOIN dbo.SensorReadings r ON d.DeviceId = r.DeviceId
WHERE d.DeviceType = 'SENSOR'
GROUP BY d.DeviceId, d.DeviceName;

-- Q10
SELECT
    r.ReadingId,
    d.DeviceName,
    z.ZoneName,
    r.Temperature,
    r.Humidity,
    r.RecordeAt
FROM dbo.SensorReadings r
INNER JOIN dbo.Devices d ON r.DeviceId = d.DeviceId
INNER JOIN dbo.Zones z ON d.ZoneId = z.ZoneId
INNER JOIN dbo.EnvironmentThresholds t ON z.ZoneId = t.ZoneId
WHERE r.Temperature < t.MinTemperature
   OR r.Temperature > t.MaxTemperature
   OR r.Humidity < t.MinHumidity
   OR r.Humidity > t.MaxHumidity;

-- Q11
WITH LatestReadings AS (
    SELECT
        d.DeviceId,
        d.DeviceName,
        z.ZoneName,
        r.Temperature,
        r.Humidity,
        r.RecordeAt,
        t.MinTemperature,
        t.MaxTemperature,
        t.MinHumidity,
        t.MaxHumidity,
        ROW_NUMBER() OVER (
            PARTITION BY d.DeviceId
            ORDER BY r.RecordeAt DESC, r.ReadingId DESC
        ) AS RowNum
    FROM dbo.Devices d
    INNER JOIN dbo.Zones z ON d.ZoneId = z.ZoneId
    INNER JOIN dbo.SensorReadings r ON d.DeviceId = r.DeviceId
    INNER JOIN dbo.EnvironmentThresholds t ON z.ZoneId = t.ZoneId
    WHERE d.DeviceType = 'SENSOR'
)
SELECT
    DeviceId,
    DeviceName,
    ZoneName,
    Temperature,
    Humidity,
    RecordeAt,
    CASE
        WHEN Temperature < MinTemperature THEN 'LOW_TEMP'
        WHEN Temperature > MaxTemperature THEN 'HIGH_TEMP'
        WHEN Humidity < MinHumidity THEN 'LOW_HUMIDITY'
        WHEN Humidity > MaxHumidity THEN 'HIGH_HUMIDITY'
        ELSE 'NORMAL'
    END AS EnvironmentStatus
FROM LatestReadings
WHERE RowNum = 1;

-- Q12
SELECT
    d.DeviceId,
    d.DeviceName,
    MAX(r.RecordeAt) AS LastRecordedAt
FROM dbo.Devices d
LEFT JOIN dbo.SensorReadings r ON d.DeviceId = r.DeviceId
WHERE d.DeviceType = 'SENSOR'
GROUP BY d.DeviceId, d.DeviceName
HAVING MAX(r.RecordeAt) IS NULL
    OR MAX(r.RecordeAt) < DATEADD(MINUTE, -30, SYSDATETIME());

-- Q13
SELECT
    a.AlertId,
    a.AlertType,
    a.Message,
    a.Status,
    a.CreatedAt,
    z.ZoneName,
    h.HouseName
FROM dbo.Alerts a
INNER JOIN dbo.Zones z ON a.ZoneId = z.ZoneId
INNER JOIN dbo.SwiftletHouses h ON z.HouseId = h.HouseId
ORDER BY a.CreatedAt DESC;

-- Q14
SELECT *
FROM dbo.Alerts
WHERE Status = 'PENDING';

-- Q15
SELECT *
FROM dbo.Alerts
WHERE Status IN ('PENDING', 'ACKNOWLEDGED');

-- Q16
SELECT
    AlertType,
    COUNT(*) AS TotalAlerts
FROM dbo.Alerts
GROUP BY AlertType;

-- Q17
SELECT
    Status,
    COUNT(*) AS TotalAlerts
FROM dbo.Alerts
GROUP BY Status;

-- Q18
SELECT TOP 5 *
FROM dbo.Alerts
ORDER BY CreatedAt DESC, AlertId DESC;

-- Q19
SELECT TOP (1) WITH TIES
    z.ZoneId,
    z.ZoneName,
    h.HouseName,
    COUNT(a.AlertId) AS TotalAlerts
FROM dbo.Zones AS z
INNER JOIN dbo.SwiftletHouses AS h
    ON z.HouseId = h.HouseId
LEFT JOIN dbo.Alerts AS a
    ON z.ZoneId = a.ZoneId
GROUP BY
    z.ZoneId,
    z.ZoneName,
    h.HouseName
ORDER BY COUNT(a.AlertId) DESC;

-- Q20
SELECT
    z.ZoneId,
    z.ZoneName,
    COUNT(a.AlertId) AS TotalAlerts
FROM dbo.Zones z
INNER JOIN dbo.Alerts a ON z.ZoneId = a.ZoneId
GROUP BY z.ZoneId, z.ZoneName
HAVING COUNT(a.AlertId) > 5;

-- Q21
SELECT
    aa.ActionId,
    a.AlertId,
    a.AlertType,
    u.FullName,
    aa.ActionType,
    aa.Note,
    aa.ActionAt
FROM dbo.AlertActions aa
INNER JOIN dbo.Alerts a ON aa.AlertId = a.AlertId
INNER JOIN dbo.Users u ON aa.UserId = u.UserID
ORDER BY aa.ActionAt DESC;

-- Q22
SELECT
    aa.ActionId,
    aa.AlertId,
    u.FullName,
    aa.ActionType,
    aa.Note,
    aa.ActionAt
FROM dbo.AlertActions aa
INNER JOIN dbo.Users u ON aa.UserId = u.UserID
WHERE aa.AlertId = 1
ORDER BY aa.ActionAt;

-- Q23
SELECT
    u.UserID,
    u.FullName,
    COUNT(aa.ActionId) AS TotalActions
FROM dbo.Users u
LEFT JOIN dbo.AlertActions aa ON u.UserID = aa.UserId
GROUP BY u.UserID, u.FullName;

-- Q24
SELECT
    cl.ControlLogId,
    d.DeviceName,
    z.ZoneName,
    h.HouseName,
    u.FullName,
    cl.Command,
    cl.Result,
    cl.ExecuteAt
FROM dbo.ControlLogs cl
INNER JOIN dbo.Devices d ON cl.DeviceId = d.DeviceId
INNER JOIN dbo.Zones z ON d.ZoneId = z.ZoneId
INNER JOIN dbo.SwiftletHouses h ON z.HouseId = h.HouseId
INNER JOIN dbo.Users u ON cl.UserId = u.UserID
ORDER BY cl.ExecuteAt DESC;

-- Q25
SELECT
    Result,
    COUNT(*) AS TotalCommands
FROM dbo.ControlLogs
GROUP BY Result;

-- Q26
SELECT
    COUNT(*) AS TotalActiveHouses
FROM dbo.SwiftletHouses
WHERE Status = 'ACTIVE';

-- Q27
SELECT
    Status,
    COUNT(*) AS TotalDevices
FROM dbo.Devices
GROUP BY Status;

-- Q28
SELECT
    h.HouseId,
    h.HouseName,
    COUNT(a.AlertId) AS UnresolvedAlerts
FROM dbo.SwiftletHouses h
LEFT JOIN dbo.Zones z ON h.HouseId = z.HouseId
LEFT JOIN dbo.Alerts a
    ON z.ZoneId = a.ZoneId
   AND a.Status IN ('PENDING', 'ACKNOWLEDGED')
GROUP BY h.HouseId, h.HouseName;

-- Q29
SELECT
    CAST(r.RecordeAt AS DATE) AS ReadingDate,
    AVG(r.Temperature) AS AvgTemperature,
    AVG(r.Humidity) AS AvgHumidity
FROM dbo.SensorReadings r
GROUP BY CAST(r.RecordeAt AS DATE)
ORDER BY ReadingDate;

-- Q30
WITH LatestReadings AS (
    SELECT d.ZoneId, d.DeviceId, r.ReadingId,
           r.Temperature, r.Humidity, r.RecordeAt
    FROM dbo.Devices AS d
    OUTER APPLY (
        SELECT TOP (1) sr.ReadingId, sr.Temperature, sr.Humidity, sr.RecordeAt
        FROM dbo.SensorReadings AS sr
        WHERE sr.DeviceId = d.DeviceId
        ORDER BY sr.RecordeAt DESC, sr.ReadingId DESC
    ) AS r
    WHERE d.DeviceType = 'SENSOR'
)
SELECT z.ZoneId, z.ZoneName, h.HouseName,
       COUNT(r.DeviceId) AS SensorCount,
       AVG(r.Temperature) AS AvgTemperature,
       AVG(r.Humidity) AS AvgHumidity,
       SUM(CASE WHEN r.Temperature < t.MinTemperature OR r.Temperature > t.MaxTemperature
                     OR r.Humidity < t.MinHumidity OR r.Humidity > t.MaxHumidity
                THEN 1 ELSE 0 END) AS WarningSensorCount,
       CASE
           WHEN t.ThresholdsId IS NULL THEN 'UNCONFIGURED'
           WHEN COUNT(r.ReadingId) = 0 THEN 'NO_DATA'
           WHEN MAX(CASE WHEN r.Temperature < t.MinTemperature OR r.Temperature > t.MaxTemperature
                              OR r.Humidity < t.MinHumidity OR r.Humidity > t.MaxHumidity
                         THEN 1 ELSE 0 END) = 1 THEN 'WARNING'
           WHEN COUNT(r.ReadingId) < COUNT(r.DeviceId) THEN 'INCOMPLETE_DATA'
           ELSE 'NORMAL'
       END AS EnvironmentStatus,
       COUNT(r.ReadingId) AS ReadingSensorCount,
       MAX(r.RecordeAt) AS LastRecordedAt
FROM dbo.Zones AS z
JOIN dbo.SwiftletHouses AS h ON h.HouseId = z.HouseId
LEFT JOIN LatestReadings AS r ON r.ZoneId = z.ZoneId
LEFT JOIN dbo.EnvironmentThresholds AS t ON t.ZoneId = z.ZoneId
GROUP BY z.ZoneId, z.ZoneName, h.HouseName, t.ThresholdsId
ORDER BY h.HouseName, z.ZoneName;
