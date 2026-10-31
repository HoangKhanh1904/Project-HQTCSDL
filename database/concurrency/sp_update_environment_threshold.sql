USE SwiftletCare;
GO

CREATE OR ALTER PROCEDURE dbo.sp_UpdateEnvironmentThreshold
    @ZoneId INT,
    @MinTemperature DECIMAL(5,2),
    @MaxTemperature DECIMAL(5,2),
    @MinHumidity DECIMAL(5,2),
    @MaxHumidity DECIMAL(5,2),
    @ExpectedRowVer VARBINARY(MAX),
    @UserId INT,
    @ResultCode VARCHAR(32) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @EntryTranCount INT = @@TRANCOUNT;
    DECLARE @SavepointCreated BIT = 0;
    DECLARE @Success BIT = 0;
    DECLARE @Code VARCHAR(32) = 'SYSTEM_ERROR';
    DECLARE @Message NVARCHAR(255);
    DECLARE @ErrorNumber INT;
    DECLARE @Changed TABLE (
        ThresholdsId INT, ZoneId INT,
        MinTemperature DECIMAL(5,2), MaxTemperature DECIMAL(5,2),
        MinHumidity DECIMAL(5,2), MaxHumidity DECIMAL(5,2),
        UpdatedAt DATETIME2, RowVer BINARY(8)
    );

    BEGIN TRY
        IF @EntryTranCount = 0
            BEGIN TRANSACTION;
        ELSE
        BEGIN
            SAVE TRANSACTION UpdateThresholdSave;
            SET @SavepointCreated = 1;
        END;

        -- VALIDATION
        IF @ZoneId IS NULL OR @ZoneId <= 0 OR @UserId IS NULL OR @UserId <= 0
           OR @MinTemperature IS NULL OR @MaxTemperature IS NULL
           OR @MinHumidity IS NULL OR @MaxHumidity IS NULL
           OR @MinTemperature NOT BETWEEN -40 AND 100
           OR @MaxTemperature NOT BETWEEN -40 AND 100
           OR @MinHumidity NOT BETWEEN 0 AND 100
           OR @MaxHumidity NOT BETWEEN 0 AND 100
           OR @MinTemperature > @MaxTemperature OR @MinHumidity > @MaxHumidity
           OR @ExpectedRowVer IS NULL OR DATALENGTH(@ExpectedRowVer) <> 8
            BEGIN
                SET @Code = 'VALIDATION_ERROR';
                SET @Message = N'Giá trị ngưỡng hoặc RowVer không hợp lệ.';
                GOTO BusinessFailure;
            END;

        IF NOT EXISTS (
            SELECT 1 FROM dbo.Users WITH (HOLDLOCK)
            WHERE UserID = @UserId AND IsActive = 1 AND Role = 'ADMIN'
        )
            BEGIN
                SET @Code = 'FORBIDDEN';
                SET @Message = N'Chỉ quản trị viên đang hoạt động được sửa ngưỡng.';
                GOTO BusinessFailure;
            END;

        IF NOT EXISTS (SELECT 1 FROM dbo.Zones WITH (HOLDLOCK) WHERE ZoneId = @ZoneId)
            BEGIN
                SET @Code = 'ZONE_NOT_FOUND';
                SET @Message = N'Zone không tồn tại.';
                GOTO BusinessFailure;
            END;

        -- TRANSACTION
        UPDATE dbo.EnvironmentThresholds WITH (UPDLOCK, HOLDLOCK)
        SET MinTemperature = @MinTemperature, MaxTemperature = @MaxTemperature,
            MinHumidity = @MinHumidity, MaxHumidity = @MaxHumidity,
            UpdateAt = SYSDATETIME()
        OUTPUT inserted.ThresholdsId, inserted.ZoneId,
               inserted.MinTemperature, inserted.MaxTemperature,
               inserted.MinHumidity, inserted.MaxHumidity, inserted.UpdateAt, inserted.RowVer
        INTO @Changed
        WHERE ZoneId = @ZoneId AND RowVer = CONVERT(BINARY(8), @ExpectedRowVer);

        IF @@ROWCOUNT = 0
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId)
                BEGIN
                    SET @Code = 'THRESHOLD_NOT_FOUND';
                    SET @Message = N'Zone chưa có cấu hình ngưỡng môi trường.';
                    GOTO BusinessFailure;
                END;
            BEGIN
                SET @Code = 'CONCURRENCY_CONFLICT';
                SET @Message = N'Cấu hình đã được thay đổi. Hãy tải lại trước khi lưu.';
                GOTO BusinessFailure;
            END;
        END;

        IF @EntryTranCount = 0
            COMMIT TRANSACTION;
        SET @Success = 1;
        SET @Code = 'OK';
        SET @Message = N'Cập nhật ngưỡng môi trường thành công.';
    END TRY
    BEGIN CATCH
        -- ERROR HANDLING
        SET @ErrorNumber = ERROR_NUMBER();
        SET @Message = ERROR_MESSAGE();
        IF @EntryTranCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @SavepointCreated = 1 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION UpdateThresholdSave;

        SET @Code = 'SYSTEM_ERROR';
        SET @Message = N'Không thể cập nhật ngưỡng. Hãy rollback giao dịch và thử lại.';
    END CATCH;

    GOTO Result;

    -- BUSINESS FAILURE
    BusinessFailure:
    IF @EntryTranCount = 0 AND XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    ELSE IF @SavepointCreated = 1 AND XACT_STATE() = 1
        ROLLBACK TRANSACTION UpdateThresholdSave;

    -- RESULT
    Result:
    SET @ResultCode = @Code;
    SELECT @Success AS Success, @Code AS Code, @Message AS Message,
           @ErrorNumber AS ErrorNumber, @ZoneId AS ZoneId, c.ThresholdsId,
           c.MinTemperature, c.MaxTemperature, c.MinHumidity, c.MaxHumidity,
           c.UpdatedAt, c.RowVer
    FROM (VALUES (1)) AS result(OneRow)
    LEFT JOIN @Changed AS c ON @Success = 1;
END;
GO
