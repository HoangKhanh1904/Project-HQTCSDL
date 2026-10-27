USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_GetEnvironmentMetrics
    @HouseId INT=NULL,@ZoneId INT=NULL,@DeviceId INT=NULL,
    @From DATETIME2=NULL,@To DATETIME2=NULL,@Limit INT=500
AS
BEGIN
    SET NOCOUNT ON;
    -- No range: latest sample per sensor, including sensors with no sample.
    -- A range: history in [From,To), bounded by Limit across all selected sensors.
    IF (@HouseId IS NOT NULL AND @HouseId<=0) OR (@ZoneId IS NOT NULL AND @ZoneId<=0)
       OR (@DeviceId IS NOT NULL AND @DeviceId<=0) OR @Limit IS NULL OR @Limit NOT BETWEEN 1 AND 1000
       OR (@From IS NULL AND @To IS NOT NULL) OR (@From IS NOT NULL AND @To IS NULL)
       OR @From>=@To
        THROW 52712,'Invalid metrics filters, limit or half-open range.',1;
    IF @From IS NULL
        SELECT TOP(@Limit) z.HouseId,d.ZoneId,d.DeviceId,d.DeviceName,r.ReadingId,
            r.Temperature,r.Humidity,r.CO2Ppm,r.LightLux,r.RecordeAt,
            CASE WHEN r.ReadingId IS NULL THEN 'NO_DATA' ELSE 'AVAILABLE' END AS ReadingStatus
        FROM dbo.Devices d JOIN dbo.Zones z ON z.ZoneId=d.ZoneId
        OUTER APPLY(SELECT TOP(1) sr.ReadingId,sr.Temperature,sr.Humidity,sr.CO2Ppm,sr.LightLux,sr.RecordeAt
            FROM dbo.SensorReadings sr WHERE sr.DeviceId=d.DeviceId ORDER BY sr.RecordeAt DESC,sr.ReadingId DESC) r
        WHERE d.DeviceType='SENSOR' AND (@HouseId IS NULL OR z.HouseId=@HouseId)
          AND (@ZoneId IS NULL OR d.ZoneId=@ZoneId) AND (@DeviceId IS NULL OR d.DeviceId=@DeviceId)
        ORDER BY z.HouseId,d.ZoneId,d.DeviceId;
    ELSE
        SELECT TOP(@Limit) z.HouseId,d.ZoneId,d.DeviceId,d.DeviceName,r.ReadingId,
            r.Temperature,r.Humidity,r.CO2Ppm,r.LightLux,r.RecordeAt,CAST('AVAILABLE' AS VARCHAR(9)) AS ReadingStatus
        FROM dbo.SensorReadings r JOIN dbo.Devices d ON d.DeviceId=r.DeviceId
        JOIN dbo.Zones z ON z.ZoneId=d.ZoneId
        WHERE d.DeviceType='SENSOR' AND (@HouseId IS NULL OR z.HouseId=@HouseId)
          AND (@ZoneId IS NULL OR d.ZoneId=@ZoneId) AND (@DeviceId IS NULL OR d.DeviceId=@DeviceId)
          AND r.RecordeAt>=@From AND r.RecordeAt<@To
        ORDER BY r.RecordeAt DESC,r.ReadingId DESC;
END;
GO
