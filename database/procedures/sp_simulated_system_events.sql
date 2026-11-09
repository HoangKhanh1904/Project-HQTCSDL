USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_InsertSimulatedSystemEvent
    @HouseId INT,@ZoneId INT,@EventType VARCHAR(30),@Severity VARCHAR(8),
    @EventAt DATETIME2,@Message NVARCHAR(255),@DeviceId INT=NULL,
    @SourceEventId UNIQUEIDENTIFIER=NULL,@ResultCode VARCHAR(32)=NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Entry INT=@@TRANCOUNT,@Saved BIT=0,@Success BIT=0,@Code VARCHAR(32)='SYSTEM_ERROR',
        @ErrorNumber INT,@EventId BIGINT,@Duplicate BIT=0,@LockedHouse INT,@LockedZone INT,@LockedDevice INT;
    BEGIN TRY
        IF @Entry=0 BEGIN TRANSACTION;
        ELSE BEGIN SAVE TRANSACTION SystemEventSave; SET @Saved=1; END;
        IF @HouseId IS NULL OR @HouseId<=0 OR @ZoneId IS NULL OR @ZoneId<=0
           OR @EventType IS NULL OR @EventType NOT IN ('PREDATOR_DETECTED','SPEAKER_FAILURE','ABNORMAL_SOUND','DEVICE_OFFLINE')
           OR @Severity IS NULL OR @Severity NOT IN ('INFO','WARNING','CRITICAL')
           OR @EventAt IS NULL OR NULLIF(LTRIM(RTRIM(@Message)),N'') IS NULL
           OR (@DeviceId IS NOT NULL AND @DeviceId<=0)
        BEGIN SET @Code='VALIDATION_ERROR'; GOTO BusinessFailure; END;
        -- Source id is scoped to the house and the fixed SIMULATED source.
        SELECT @LockedHouse=HouseId FROM dbo.SwiftletHouses WITH (UPDLOCK,HOLDLOCK) WHERE HouseId=@HouseId;
        IF @LockedHouse IS NULL BEGIN SET @Code='HOUSE_NOT_FOUND'; GOTO BusinessFailure; END;
        IF @SourceEventId IS NOT NULL
            SELECT @EventId=EventId FROM dbo.SimulatedSystemEvents
            WHERE HouseId=@HouseId AND SourceType='SIMULATED' AND SourceEventId=@SourceEventId;
        IF @EventId IS NOT NULL
        BEGIN
            IF EXISTS(SELECT ZoneId,EventType,Severity,EventAt,CONVERT(VARBINARY(510),Message),DeviceId FROM dbo.SimulatedSystemEvents WHERE EventId=@EventId
                      EXCEPT SELECT @ZoneId,@EventType,@Severity,@EventAt,CONVERT(VARBINARY(510),@Message),@DeviceId)
            BEGIN SET @Code='IDEMPOTENCY_CONFLICT'; GOTO BusinessFailure; END;
            SET @Duplicate=1;
        END
        ELSE
        BEGIN
            -- Match ingest/control lock order: device before zone. No sensor is
            -- read after holding a zone lock, which avoids a lock-order cycle.
            IF @DeviceId IS NOT NULL
            BEGIN
                SELECT @LockedDevice=DeviceId FROM dbo.Devices WITH (UPDLOCK,HOLDLOCK)
                WHERE DeviceId=@DeviceId AND ZoneId=@ZoneId;
                IF @LockedDevice IS NULL BEGIN SET @Code='DEVICE_ZONE_MISMATCH'; GOTO BusinessFailure; END;
            END;
            SELECT @LockedZone=ZoneId FROM dbo.Zones WITH (UPDLOCK,HOLDLOCK) WHERE ZoneId=@ZoneId AND HouseId=@HouseId;
            IF @LockedZone IS NULL BEGIN SET @Code='ZONE_HOUSE_MISMATCH'; GOTO BusinessFailure; END;
            INSERT dbo.SimulatedSystemEvents(HouseId,ZoneId,EventType,Severity,EventAt,Message,DeviceId,SourceEventId)
            VALUES(@HouseId,@ZoneId,@EventType,@Severity,@EventAt,@Message,@DeviceId,@SourceEventId);
            SET @EventId=CONVERT(BIGINT,SCOPE_IDENTITY());
        END;
        IF @Entry=0 COMMIT;
        SET @Success=1; SET @Code='OK';
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER();
        IF @Entry=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @Saved=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION SystemEventSave;
    END CATCH;
    GOTO Result;
    BusinessFailure:
    IF @Entry=0 AND XACT_STATE()<>0 ROLLBACK;
    ELSE IF @Saved=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION SystemEventSave;
    Result:
    IF @Success=0 BEGIN SET @EventId=NULL; SET @Duplicate=0; END;
    SET @ResultCode=@Code;
    SELECT @Success AS Success,@Code AS Code,@ErrorNumber AS ErrorNumber,@EventId AS EventId,@Duplicate AS Duplicate,
           CAST('SIMULATED' AS VARCHAR(9)) AS SourceType;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_UpdateSimulatedEventStatus
    @EventId BIGINT,@UserId INT,@ExpectedStatus VARCHAR(12),@NewStatus VARCHAR(12),
    @ResultCode VARCHAR(32)=NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Entry INT=@@TRANCOUNT,@Saved BIT=0,@Success BIT=0,@Code VARCHAR(32)='SYSTEM_ERROR',
        @ErrorNumber INT,@Current VARCHAR(12),@Changed BIT=0;
    BEGIN TRY
        IF @Entry=0 BEGIN TRANSACTION;
        ELSE BEGIN SAVE TRANSACTION EventStatusSave; SET @Saved=1; END;
        IF @EventId IS NULL OR @EventId<=0 OR @UserId IS NULL OR @UserId<=0
           OR @ExpectedStatus IS NULL OR @NewStatus IS NULL
           OR NOT ((@ExpectedStatus='NEW' AND @NewStatus='ACKNOWLEDGED')
                OR (@ExpectedStatus='ACKNOWLEDGED' AND @NewStatus='RESOLVED'))
        BEGIN SET @Code='VALIDATION_ERROR'; GOTO BusinessFailure; END;
        IF NOT EXISTS(SELECT 1 FROM dbo.Users WITH(HOLDLOCK) WHERE UserID=@UserId AND IsActive=1 AND Role IN ('ADMIN','STAFF'))
        BEGIN SET @Code='FORBIDDEN'; GOTO BusinessFailure; END;
        SELECT @Current=Status FROM dbo.SimulatedSystemEvents WITH(UPDLOCK,HOLDLOCK) WHERE EventId=@EventId;
        IF @Current IS NULL BEGIN SET @Code='EVENT_NOT_FOUND'; GOTO BusinessFailure; END;
        -- An exact retry is harmless; no timestamp/user is overwritten.
        IF @Current<>@NewStatus
        BEGIN
            IF @Current<>@ExpectedStatus BEGIN SET @Code='CONCURRENCY_CONFLICT'; GOTO BusinessFailure; END;
            UPDATE dbo.SimulatedSystemEvents SET Status=@NewStatus,UpdatedAt=DATEADD(HOUR,7,SYSUTCDATETIME()),UpdatedBy=@UserId
            WHERE EventId=@EventId;
            SET @Changed=1;
        END;
        IF @Entry=0 COMMIT;
        SET @Success=1; SET @Code='OK'; SET @Current=@NewStatus;
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER();
        IF @Entry=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @Saved=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION EventStatusSave;
    END CATCH;
    GOTO Result;
    BusinessFailure:
    IF @Entry=0 AND XACT_STATE()<>0 ROLLBACK;
    ELSE IF @Saved=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION EventStatusSave;
    Result:
    IF @Success=0 BEGIN SET @Current=NULL; SET @Changed=0; END;
    SET @ResultCode=@Code;
    SELECT @Success AS Success,@Code AS Code,@ErrorNumber AS ErrorNumber,@EventId AS EventId,@Current AS Status,@Changed AS Changed;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_GetSimulatedSystemEvents
    @HouseId INT=NULL,@ZoneId INT=NULL,@Status VARCHAR(12)=NULL,@Limit INT=100
AS
BEGIN
    SET NOCOUNT ON;
    IF (@HouseId IS NOT NULL AND @HouseId<=0) OR (@ZoneId IS NOT NULL AND @ZoneId<=0)
       OR (@Status IS NOT NULL AND @Status NOT IN ('NEW','ACKNOWLEDGED','RESOLVED'))
       OR @Limit IS NULL OR @Limit NOT BETWEEN 1 AND 1000
        THROW 52713,'Invalid event filters or limit.',1;
    -- NULL status means unresolved. Explicit RESOLVED retrieves resolved events.
    SELECT TOP(@Limit) EventId,HouseId,ZoneId,DeviceId,EventType,Severity,EventAt,CreatedAt,
        SourceType,Message,Status,SourceEventId,UpdatedAt,UpdatedBy
    FROM dbo.SimulatedSystemEvents
    WHERE (@HouseId IS NULL OR HouseId=@HouseId) AND (@ZoneId IS NULL OR ZoneId=@ZoneId)
      AND ((@Status IS NULL AND Status IN ('NEW','ACKNOWLEDGED')) OR Status=@Status)
    ORDER BY EventAt DESC,EventId DESC;
END;
GO
