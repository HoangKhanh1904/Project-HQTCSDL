USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_GetZoneDashboard @ZoneId INT=NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ZoneId IS NOT NULL AND @ZoneId<=0 THROW 52504,'Invalid ZoneId',1;
-- DASHBOARD
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
WHERE @ZoneId IS NULL OR z.ZoneId=@ZoneId
GROUP BY z.ZoneId, z.ZoneName, h.HouseName, t.ThresholdsId
ORDER BY h.HouseName, z.ZoneName;
END;
GO
