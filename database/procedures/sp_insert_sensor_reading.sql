USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_InsertSensorReading
    @DeviceId INT,
    @Temperature DECIMAL(5,2),
    @Humidity DECIMAL(5,2),
    @SourceEventId UNIQUEIDENTIFIER = NULL,
    @ResultCode VARCHAR(32) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @EntryTranCount INT=@@TRANCOUNT, @SavepointCreated BIT=0;
    DECLARE @Success BIT=0, @Code VARCHAR(32)='SYSTEM_ERROR', @Message NVARCHAR(255), @ErrorNumber INT;
    DECLARE @ZoneId INT, @DeviceType VARCHAR(30), @DeviceStatus VARCHAR(20), @ZoneStatus VARCHAR(20);
    DECLARE @ReadingId BIGINT, @RecordeAt DATETIME2, @Duplicate BIT=0, @AlertCount INT=0;
    DECLARE @ThresholdStatus VARCHAR(20), @ThresholdsId INT;
    DECLARE @MinT DECIMAL(5,2), @MaxT DECIMAL(5,2), @MinH DECIMAL(5,2), @MaxH DECIMAL(5,2);
    DECLARE @OldT DECIMAL(5,2), @OldH DECIMAL(5,2);
    DECLARE @Inserted TABLE(ReadingId BIGINT, RecordeAt DATETIME2);
    BEGIN TRY
        IF @EntryTranCount=0 BEGIN TRANSACTION;
        ELSE BEGIN SAVE TRANSACTION InsertReadingSave; SET @SavepointCreated=1; END;

        -- VALIDATION
        IF @DeviceId IS NULL OR @DeviceId<=0 OR @Temperature IS NULL OR @Humidity IS NULL
           OR @Temperature NOT BETWEEN -40 AND 100 OR @Humidity NOT BETWEEN 0 AND 100
        BEGIN
            SET @Code='VALIDATION_ERROR'; SET @Message=N'Số đo hoặc DeviceId không hợp lệ.';
            GOTO BusinessFailure;
        END;
        SELECT @ZoneId=ZoneId, @DeviceType=DeviceType, @DeviceStatus=Status
        FROM dbo.Devices WITH (UPDLOCK,HOLDLOCK) WHERE DeviceId=@DeviceId;
        IF @ZoneId IS NULL
        BEGIN
            SET @Code='DEVICE_NOT_FOUND'; SET @Message=N'Thiết bị không tồn tại.'; GOTO BusinessFailure;
        END;
        IF @DeviceType<>'SENSOR' OR @DeviceStatus<>'ACTIVE'
        BEGIN
            SET @Code='DEVICE_UNAVAILABLE'; SET @Message=N'Thiết bị phải là SENSOR đang ACTIVE.'; GOTO BusinessFailure;
        END;
        SELECT @ZoneStatus=Status FROM dbo.Zones WITH (UPDLOCK,HOLDLOCK) WHERE ZoneId=@ZoneId;
        IF @ZoneStatus<>'ACTIVE' OR @ZoneStatus IS NULL
        BEGIN
            SET @Code='ZONE_UNAVAILABLE'; SET @Message=N'Zone không hoạt động.'; GOTO BusinessFailure;
        END;

        -- REPLAY
        IF @SourceEventId IS NOT NULL
        BEGIN
            SELECT @ReadingId=ReadingId, @RecordeAt=RecordeAt, @OldT=Temperature, @OldH=Humidity
            FROM dbo.SensorReadings WHERE DeviceId=@DeviceId AND SourceEventId=@SourceEventId;
            IF @ReadingId IS NOT NULL
            BEGIN
                IF @OldT<>@Temperature OR @OldH<>@Humidity
                BEGIN
                    SET @Code='IDEMPOTENCY_CONFLICT'; SET @Message=N'Mã số đo đã dùng cho dữ liệu khác.'; GOTO BusinessFailure;
                END;
                SET @Duplicate=1;
                SET @ThresholdStatus='REPLAY';
                GOTO CommitSuccess;
            END;
        END;

        -- READING
        SELECT @ThresholdsId=ThresholdsId,@MinT=MinTemperature,@MaxT=MaxTemperature,
               @MinH=MinHumidity,@MaxH=MaxHumidity
        FROM dbo.EnvironmentThresholds WITH (HOLDLOCK) WHERE ZoneId=@ZoneId;
        SET @ThresholdStatus=CASE WHEN @ThresholdsId IS NULL THEN 'UNCONFIGURED' ELSE 'CONFIGURED' END;
        INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity,SourceEventId)
        OUTPUT inserted.ReadingId,inserted.RecordeAt INTO @Inserted
        VALUES (@DeviceId,@Temperature,@Humidity,@SourceEventId);
        SELECT @ReadingId=ReadingId,@RecordeAt=RecordeAt FROM @Inserted;

        -- ALERTS
        IF @ThresholdsId IS NOT NULL
        BEGIN
            INSERT dbo.Alerts(ZoneId,ReadingId,AlertType,Message,Status)
            SELECT @ZoneId,@ReadingId,v.AlertType,v.Message,'PENDING'
            FROM (VALUES
                ('HIGH_TEMP',CASE WHEN @Temperature>@MaxT THEN N'Nhiệt độ vượt ngưỡng tối đa' END),
                ('LOW_TEMP',CASE WHEN @Temperature<@MinT THEN N'Nhiệt độ dưới ngưỡng tối thiểu' END),
                ('HIGH_HUMIDITY',CASE WHEN @Humidity>@MaxH THEN N'Độ ẩm vượt ngưỡng tối đa' END),
                ('LOW_HUMIDITY',CASE WHEN @Humidity<@MinH THEN N'Độ ẩm dưới ngưỡng tối thiểu' END)
            ) v(AlertType,Message)
            WHERE v.Message IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM dbo.Alerts a WHERE a.ZoneId=@ZoneId AND a.AlertType=v.AlertType
                  AND a.Status IN ('PENDING','ACKNOWLEDGED')
            );
            SET @AlertCount=@@ROWCOUNT;
        END;

        -- COMMIT
        CommitSuccess:
        IF @EntryTranCount=0 COMMIT;
        SET @Success=1; SET @Code='OK';
        SET @Message=CASE WHEN @Duplicate=1 THEN N'Số đo đã được tiếp nhận trước đó.'
                          WHEN @ThresholdsId IS NULL THEN N'Đã lưu số đo; Zone chưa cấu hình ngưỡng.'
                          ELSE N'Đã lưu số đo và kiểm tra cảnh báo.' END;
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER(); SET @Code='SYSTEM_ERROR';
        SET @Message=N'Không thể lưu số đo. Hãy rollback giao dịch và kiểm tra lại.';
        IF @EntryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @SavepointCreated=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION InsertReadingSave;
    END CATCH;
    GOTO Result;

    -- ROLLBACK
    BusinessFailure:
    IF @EntryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
    ELSE IF @SavepointCreated=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION InsertReadingSave;

    -- RESULT
    Result:
    IF @Success=0
    BEGIN
        SET @ReadingId=NULL; SET @RecordeAt=NULL; SET @AlertCount=0;
        SET @Duplicate=0; SET @ThresholdStatus=NULL;
    END;
    SET @ResultCode=@Code;
    SELECT @Success AS Success,@Code AS Code,@Message AS Message,@ErrorNumber AS ErrorNumber,
           @DeviceId AS DeviceId,@ZoneId AS ZoneId,@ReadingId AS ReadingId,@RecordeAt AS RecordeAt,
           @AlertCount AS AlertCount,@ThresholdStatus AS ThresholdStatus,@Duplicate AS Duplicate;
END;
GO
