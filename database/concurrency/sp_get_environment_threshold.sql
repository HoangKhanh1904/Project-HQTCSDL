USE SwiftletCare;
GO

CREATE OR ALTER PROCEDURE dbo.sp_GetEnvironmentThreshold
    @ZoneId INT,
    @ResultCode VARCHAR(32) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Success BIT = 0;
    DECLARE @Code VARCHAR(32) = 'SYSTEM_ERROR';
    DECLARE @Message NVARCHAR(255);
    DECLARE @ErrorNumber INT;
    DECLARE @FoundZoneId INT;
    DECLARE @ThresholdsId INT;
    DECLARE @MinTemperature DECIMAL(5,2), @MaxTemperature DECIMAL(5,2);
    DECLARE @MinHumidity DECIMAL(5,2), @MaxHumidity DECIMAL(5,2);
    DECLARE @UpdatedAt DATETIME2;
    DECLARE @RowVer BINARY(8);

    BEGIN TRY
        -- VALIDATION
        IF @ZoneId IS NULL OR @ZoneId <= 0
            BEGIN
                SET @Code = 'VALIDATION_ERROR';
                SET @Message = N'ZoneId phải là số nguyên dương.';
                GOTO Result;
            END;

        SELECT @FoundZoneId = z.ZoneId, @ThresholdsId = t.ThresholdsId,
               @MinTemperature = t.MinTemperature, @MaxTemperature = t.MaxTemperature,
               @MinHumidity = t.MinHumidity, @MaxHumidity = t.MaxHumidity,
               @UpdatedAt = t.UpdateAt, @RowVer = t.RowVer
        FROM dbo.Zones AS z
        LEFT JOIN dbo.EnvironmentThresholds AS t ON t.ZoneId = z.ZoneId
        WHERE z.ZoneId = @ZoneId;

        IF @FoundZoneId IS NULL
            BEGIN
                SET @Code = 'ZONE_NOT_FOUND';
                SET @Message = N'Zone không tồn tại.';
                GOTO Result;
            END;
        IF @ThresholdsId IS NULL
            BEGIN
                SET @Code = 'THRESHOLD_NOT_FOUND';
                SET @Message = N'Zone chưa có cấu hình ngưỡng môi trường.';
                GOTO Result;
            END;

        SET @Success = 1;
        SET @Code = 'OK';
        SET @Message = N'Đã tải cấu hình ngưỡng môi trường.';
    END TRY
    BEGIN CATCH
        -- ERROR HANDLING
        SET @ErrorNumber = ERROR_NUMBER();
        SET @Message = ERROR_MESSAGE();
        SET @Code = 'SYSTEM_ERROR';
        SET @Message = N'Không thể tải cấu hình ngưỡng môi trường.';
    END CATCH;

    -- RESULT
    Result:
    SET @ResultCode = @Code;
    SELECT @Success AS Success, @Code AS Code, @Message AS Message,
           @ErrorNumber AS ErrorNumber, @ZoneId AS ZoneId, @ThresholdsId AS ThresholdsId,
           @MinTemperature AS MinTemperature, @MaxTemperature AS MaxTemperature,
           @MinHumidity AS MinHumidity, @MaxHumidity AS MaxHumidity,
           @UpdatedAt AS UpdatedAt, @RowVer AS RowVer;
END;
GO
