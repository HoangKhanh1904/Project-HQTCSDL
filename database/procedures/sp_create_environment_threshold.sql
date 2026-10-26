USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_CreateEnvironmentThreshold
    @ZoneId INT,@MinTemperature DECIMAL(5,2),@MaxTemperature DECIMAL(5,2),
    @MinHumidity DECIMAL(5,2),@MaxHumidity DECIMAL(5,2),@UserId INT,
    @ResultCode VARCHAR(32)=NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @EntryTranCount INT=@@TRANCOUNT,@SavepointCreated BIT=0,@LockedZone INT;
    DECLARE @Success BIT=0,@Code VARCHAR(32)='SYSTEM_ERROR',@Message NVARCHAR(255),@ErrorNumber INT;
    DECLARE @Changed TABLE(ThresholdsId INT,ZoneId INT,MinTemperature DECIMAL(5,2),MaxTemperature DECIMAL(5,2),
        MinHumidity DECIMAL(5,2),MaxHumidity DECIMAL(5,2),UpdatedAt DATETIME2,RowVer BINARY(8));
    BEGIN TRY
        IF @EntryTranCount=0 BEGIN TRANSACTION;
        ELSE BEGIN SAVE TRANSACTION CreateThresholdSave; SET @SavepointCreated=1; END;

        -- VALIDATION
        IF @ZoneId IS NULL OR @ZoneId<=0 OR @UserId IS NULL OR @UserId<=0
           OR @MinTemperature IS NULL OR @MaxTemperature IS NULL OR @MinHumidity IS NULL OR @MaxHumidity IS NULL
           OR @MinTemperature NOT BETWEEN -40 AND 100 OR @MaxTemperature NOT BETWEEN -40 AND 100
           OR @MinHumidity NOT BETWEEN 0 AND 100 OR @MaxHumidity NOT BETWEEN 0 AND 100
           OR @MinTemperature>@MaxTemperature OR @MinHumidity>@MaxHumidity
        BEGIN
            SET @Code='VALIDATION_ERROR'; SET @Message=N'Giá trị ngưỡng không hợp lệ.'; GOTO BusinessFailure;
        END;
        IF NOT EXISTS (SELECT 1 FROM dbo.Users WITH (HOLDLOCK) WHERE UserID=@UserId AND IsActive=1 AND Role='ADMIN')
        BEGIN
            SET @Code='FORBIDDEN'; SET @Message=N'Chỉ ADMIN đang hoạt động được tạo ngưỡng.'; GOTO BusinessFailure;
        END;
        SELECT @LockedZone=ZoneId FROM dbo.Zones WITH (UPDLOCK,HOLDLOCK) WHERE ZoneId=@ZoneId;
        IF @LockedZone IS NULL
        BEGIN
            SET @Code='ZONE_NOT_FOUND'; SET @Message=N'Zone không tồn tại.'; GOTO BusinessFailure;
        END;
        IF EXISTS (SELECT 1 FROM dbo.EnvironmentThresholds WHERE ZoneId=@ZoneId)
        BEGIN
            SET @Code='THRESHOLD_EXISTS'; SET @Message=N'Zone đã có cấu hình; dùng procedure cập nhật với RowVer.'; GOTO BusinessFailure;
        END;

        -- INSERT
        INSERT dbo.EnvironmentThresholds(ZoneId,MinTemperature,MaxTemperature,MinHumidity,MaxHumidity)
        OUTPUT inserted.ThresholdsId,inserted.ZoneId,inserted.MinTemperature,inserted.MaxTemperature,
               inserted.MinHumidity,inserted.MaxHumidity,inserted.UpdateAt,inserted.RowVer INTO @Changed
        VALUES (@ZoneId,@MinTemperature,@MaxTemperature,@MinHumidity,@MaxHumidity);
        IF @EntryTranCount=0 COMMIT;
        SET @Success=1; SET @Code='OK'; SET @Message=N'Đã tạo cấu hình ngưỡng.';
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER(); SET @Code='SYSTEM_ERROR'; SET @Message=N'Không thể tạo ngưỡng. Hãy rollback giao dịch.';
        IF @EntryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @SavepointCreated=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION CreateThresholdSave;
    END CATCH;
    GOTO Result;

    -- ROLLBACK
    BusinessFailure:
    IF @EntryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
    ELSE IF @SavepointCreated=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION CreateThresholdSave;

    -- RESULT
    Result:
    SET @ResultCode=@Code;
    SELECT @Success AS Success,@Code AS Code,@Message AS Message,@ErrorNumber AS ErrorNumber,
           @ZoneId AS ZoneId,c.ThresholdsId,c.MinTemperature,c.MaxTemperature,c.MinHumidity,c.MaxHumidity,c.UpdatedAt,c.RowVer
    FROM (VALUES(1)) r(N) LEFT JOIN @Changed c ON @Success=1;
END;
GO
