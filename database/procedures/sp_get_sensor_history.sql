USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_GetSensorHistory
    @DeviceId INT,@StartTime DATETIME2,@EndTime DATETIME2,@Limit INT=500
AS
BEGIN
    SET NOCOUNT ON;
    IF @DeviceId IS NULL OR @DeviceId<=0 OR @StartTime IS NULL OR @EndTime IS NULL
       OR @StartTime>=@EndTime OR @Limit IS NULL OR @Limit NOT BETWEEN 1 AND 1000
        THROW 52502,N'Tham số lịch sử không hợp lệ.',1;
    SELECT TOP(@Limit) r.ReadingId,r.DeviceId,r.Temperature,r.Humidity,r.RecordeAt
    FROM dbo.SensorReadings r JOIN dbo.Devices d ON d.DeviceId=r.DeviceId AND d.DeviceType='SENSOR'
    WHERE r.DeviceId=@DeviceId AND r.RecordeAt>=@StartTime AND r.RecordeAt<@EndTime
    ORDER BY r.RecordeAt DESC,r.ReadingId DESC;
END;
GO
