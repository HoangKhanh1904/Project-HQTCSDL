USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_GetLatestSensorReadings @ZoneId INT=NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ZoneId IS NOT NULL AND @ZoneId<=0 THROW 52501,N'ZoneId phải dương.',1;
    SELECT d.DeviceId,d.DeviceName,d.ZoneId,d.Status AS DeviceStatus,
           r.ReadingId,r.Temperature,r.Humidity,r.RecordeAt,
           CASE WHEN r.ReadingId IS NULL THEN 'NO_DATA' ELSE 'AVAILABLE' END AS ReadingStatus
    FROM dbo.Devices d
    OUTER APPLY (SELECT TOP(1) sr.ReadingId,sr.Temperature,sr.Humidity,sr.RecordeAt
                 FROM dbo.SensorReadings sr WHERE sr.DeviceId=d.DeviceId
                 ORDER BY sr.RecordeAt DESC,sr.ReadingId DESC) r
    WHERE d.DeviceType='SENSOR' AND (@ZoneId IS NULL OR d.ZoneId=@ZoneId)
    ORDER BY d.ZoneId,d.DeviceId;
END;
GO
