USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_SimulateDeviceControl
    @DeviceId INT,@UserId INT,@Action VARCHAR(8),
    @ControlMode VARCHAR(6)=NULL,@IsOn BIT=NULL,@ReadingId BIGINT=NULL,
    @ResultCode VARCHAR(32)=NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Entry INT=@@TRANCOUNT,@Saved BIT=0,@Success BIT=0,@Code VARCHAR(32)='SYSTEM_ERROR',@ErrorNumber INT;
    DECLARE @ZoneId INT,@Type VARCHAR(30),@DeviceStatus VARCHAR(20),@ZoneStatus VARCHAR(20),
        @OldMode VARCHAR(6),@OldOn BIT,@NewMode VARCHAR(6),@NewOn BIT,@Changed BIT=0,@ControlLogId BIGINT;
    DECLARE @SensorId INT,@SensorZone INT,@SensorType VARCHAR(30),@SensorStatus VARCHAR(20),
        @Temp DECIMAL(5,2),@Humidity DECIMAL(5,2),@ReadingTime DATETIME2,
        @MinT DECIMAL(5,2),@MaxT DECIMAL(5,2),@MinH DECIMAL(5,2),@MaxH DECIMAL(5,2);
    BEGIN TRY
        IF @Entry=0 BEGIN TRANSACTION;
        ELSE BEGIN SAVE TRANSACTION SimControlSave; SET @Saved=1; END;
        IF @DeviceId IS NULL OR @DeviceId<=0 OR @UserId IS NULL OR @UserId<=0
           OR @Action IS NULL OR @Action NOT IN ('SET_MODE','MANUAL','AUTO')
           OR (@Action='SET_MODE' AND (@ControlMode IS NULL OR @ControlMode NOT IN ('AUTO','MANUAL') OR @IsOn IS NOT NULL OR @ReadingId IS NOT NULL))
           OR (@Action='MANUAL' AND (@IsOn IS NULL OR @ControlMode IS NOT NULL OR @ReadingId IS NOT NULL))
           OR (@Action='AUTO' AND (@ReadingId IS NULL OR @ReadingId<=0 OR @IsOn IS NOT NULL OR @ControlMode IS NOT NULL))
        BEGIN SET @Code='VALIDATION_ERROR'; GOTO BusinessFailure; END;
        -- The backend supplies its authenticated, active application user. For
        -- AUTO this is the operator running the simulation, never an invented id.
        IF NOT EXISTS(SELECT 1 FROM dbo.Users WITH(HOLDLOCK) WHERE UserID=@UserId AND IsActive=1 AND Role IN ('ADMIN','STAFF'))
        BEGIN SET @Code='FORBIDDEN'; GOTO BusinessFailure; END;

        IF @Action='AUTO'
        BEGIN
            SELECT @SensorId=DeviceId FROM dbo.SensorReadings WHERE ReadingId=@ReadingId;
            IF @SensorId IS NULL BEGIN SET @Code='READING_NOT_FOUND'; GOTO BusinessFailure; END;
            -- Same order as ingest: sensor, then zone. All actuator requests also
            -- lock their device row, so MANUAL and AUTO cannot interleave writes.
            SELECT @SensorZone=ZoneId,@SensorType=DeviceType,@SensorStatus=Status
            FROM dbo.Devices WITH(UPDLOCK,HOLDLOCK) WHERE DeviceId=@SensorId;
            SELECT @Temp=Temperature,@Humidity=Humidity,@ReadingTime=RecordeAt
            FROM dbo.SensorReadings WITH(HOLDLOCK) WHERE ReadingId=@ReadingId AND DeviceId=@SensorId;
            IF @Temp IS NULL OR @SensorType<>'SENSOR' OR @SensorStatus<>'ACTIVE'
            BEGIN SET @Code='READING_UNAVAILABLE'; GOTO BusinessFailure; END;
            IF EXISTS(SELECT 1 FROM dbo.SensorReadings WHERE DeviceId=@SensorId
                AND (RecordeAt>@ReadingTime OR (RecordeAt=@ReadingTime AND ReadingId>@ReadingId)))
            BEGIN SET @Code='STALE_READING'; GOTO BusinessFailure; END;
        END;
        SELECT @ZoneId=ZoneId,@Type=DeviceType,@DeviceStatus=Status
        FROM dbo.Devices WITH(UPDLOCK,HOLDLOCK) WHERE DeviceId=@DeviceId;
        IF @ZoneId IS NULL BEGIN SET @Code='DEVICE_NOT_FOUND'; GOTO BusinessFailure; END;
        IF @Type NOT IN ('FAN','HUMIDIFIER','LIGHT') OR @DeviceStatus<>'ACTIVE'
        BEGIN SET @Code='DEVICE_UNAVAILABLE'; GOTO BusinessFailure; END;
        SELECT @ZoneStatus=Status FROM dbo.Zones WITH(UPDLOCK,HOLDLOCK) WHERE ZoneId=@ZoneId;
        IF @ZoneStatus IS NULL OR @ZoneStatus<>'ACTIVE'
        BEGIN SET @Code='ZONE_UNAVAILABLE'; GOTO BusinessFailure; END;
        SELECT @OldMode=ControlMode,@OldOn=IsOn FROM dbo.DeviceControlSettings WITH(UPDLOCK,HOLDLOCK) WHERE DeviceId=@DeviceId;
        SET @NewMode=COALESCE(@OldMode,'MANUAL'); SET @NewOn=COALESCE(@OldOn,0);
        IF @Action='SET_MODE' SET @NewMode=@ControlMode;
        IF @Action='MANUAL' BEGIN SET @NewMode='MANUAL'; SET @NewOn=@IsOn; END;
        IF @Action='AUTO'
        BEGIN
            IF @NewMode='MANUAL' BEGIN SET @Code='MANUAL_OVERRIDE'; GOTO BusinessFailure; END;
            IF @SensorZone<>@ZoneId BEGIN SET @Code='READING_ZONE_MISMATCH'; GOTO BusinessFailure; END;
            IF @Type='LIGHT' BEGIN SET @Code='RULE_UNAVAILABLE'; GOTO BusinessFailure; END;
            SELECT @MinT=MinTemperature,@MaxT=MaxTemperature,@MinH=MinHumidity,@MaxH=MaxHumidity
            FROM dbo.EnvironmentThresholds WITH(HOLDLOCK) WHERE ZoneId=@ZoneId;
            IF @MinT IS NULL BEGIN SET @Code='THRESHOLD_NOT_FOUND'; GOTO BusinessFailure; END;
            -- Hysteresis uses configured min/max, with equality retaining state
            -- when min=max. No biological thresholds, PID or hardware feedback.
            IF @Type='FAN'
                SET @NewOn=CASE WHEN @Temp>@MaxT THEN 1 WHEN @Temp<@MinT THEN 0 ELSE @NewOn END;
            IF @Type='HUMIDIFIER'
                SET @NewOn=CASE WHEN @Humidity<@MinH THEN 1 WHEN @Humidity>@MaxH THEN 0 ELSE @NewOn END;
        END;
        IF @OldMode IS NULL OR @NewMode<>@OldMode OR @NewOn<>@OldOn
        BEGIN
            IF @OldMode IS NULL
                INSERT dbo.DeviceControlSettings(DeviceId,DeviceType,ControlMode,IsOn)
                VALUES(@DeviceId,@Type,@NewMode,@NewOn);
            ELSE
                UPDATE dbo.DeviceControlSettings SET ControlMode=@NewMode,IsOn=@NewOn,UpdatedAt=DATEADD(HOUR,7,SYSUTCDATETIME())
                WHERE DeviceId=@DeviceId;
            -- SUCCESS means the SQL simulation state was applied. Metadata
            -- distinguishes these rows from legacy commands/hardware claims.
            INSERT dbo.ControlLogs(DeviceId,UserId,Command,Result,ControlMode,ExecutionKind)
            VALUES(@DeviceId,@UserId,CASE WHEN @NewOn=1 THEN 'TURN_ON' ELSE 'TURN_OFF' END,'SUCCESS',@NewMode,'SIMULATED');
            SET @ControlLogId=CONVERT(BIGINT,SCOPE_IDENTITY()); SET @Changed=1;
        END;
        IF @Entry=0 COMMIT;
        SET @Success=1; SET @Code='OK';
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER();
        IF @Entry=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @Saved=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION SimControlSave;
    END CATCH;
    GOTO Result;
    BusinessFailure:
    IF @Entry=0 AND XACT_STATE()<>0 ROLLBACK;
    ELSE IF @Saved=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION SimControlSave;
    Result:
    IF @Success=0 BEGIN SET @NewMode=NULL; SET @NewOn=NULL; SET @Changed=0; SET @ControlLogId=NULL; END;
    SET @ResultCode=@Code;
    SELECT @Success AS Success,@Code AS Code,@ErrorNumber AS ErrorNumber,@DeviceId AS DeviceId,
        @NewMode AS ControlMode,@NewOn AS IsOn,@Changed AS Changed,@ControlLogId AS ControlLogId,
        CAST('SIMULATED' AS VARCHAR(9)) AS ExecutionKind,
        CASE WHEN @Success=0 THEN 'REJECTED' WHEN @Changed=1 THEN 'APPLIED' ELSE 'NO_CHANGE' END AS ExecutionStatus;
END;
GO
