USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_InsertBirdMovement
    @HouseId INT,@Direction VARCHAR(3),@BirdCount INT,@ObservedAt DATETIME2,
    @SourceType VARCHAR(10)='SIMULATED',@SourceEventId UNIQUEIDENTIFIER=NULL,
    @ResultCode VARCHAR(32)=NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Entry INT=@@TRANCOUNT,@Saved BIT=0,@Success BIT=0,
        @Code VARCHAR(32)='SYSTEM_ERROR',@ErrorNumber INT,@EventId BIGINT,@Duplicate BIT=0,@LockedHouse INT;
    BEGIN TRY
        IF @Entry=0 BEGIN TRANSACTION;
        ELSE BEGIN SAVE TRANSACTION BirdSave; SET @Saved=1; END;
        IF @HouseId IS NULL OR @HouseId<=0 OR @Direction IS NULL OR @Direction NOT IN ('IN','OUT')
           OR @BirdCount IS NULL OR @BirdCount<=0 OR @ObservedAt IS NULL
           OR @SourceType IS NULL OR @SourceType NOT IN ('SIMULATED','MANUAL')
        BEGIN SET @Code='VALIDATION_ERROR'; GOTO BusinessFailure; END;
        -- A house lock serializes source-event retries, including missing keys.
        SELECT @LockedHouse=HouseId FROM dbo.SwiftletHouses WITH (UPDLOCK,HOLDLOCK) WHERE HouseId=@HouseId;
        IF @LockedHouse IS NULL BEGIN SET @Code='HOUSE_NOT_FOUND'; GOTO BusinessFailure; END;
        IF @SourceEventId IS NOT NULL
            SELECT @EventId=EventId FROM dbo.BirdMovementEvents
            WHERE HouseId=@HouseId AND SourceType=@SourceType AND SourceEventId=@SourceEventId;
        IF @EventId IS NOT NULL
        BEGIN
            IF EXISTS(SELECT Direction,BirdCount,ObservedAt FROM dbo.BirdMovementEvents WHERE EventId=@EventId
                      EXCEPT SELECT @Direction,@BirdCount,@ObservedAt)
            BEGIN SET @Code='IDEMPOTENCY_CONFLICT'; GOTO BusinessFailure; END;
            SET @Duplicate=1;
        END
        ELSE
        BEGIN
            INSERT dbo.BirdMovementEvents(HouseId,Direction,BirdCount,ObservedAt,SourceType,SourceEventId)
            VALUES(@HouseId,@Direction,@BirdCount,@ObservedAt,@SourceType,@SourceEventId);
            SET @EventId=CONVERT(BIGINT,SCOPE_IDENTITY());
        END;
        IF @Entry=0 COMMIT;
        SET @Success=1; SET @Code='OK';
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER();
        IF @Entry=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @Saved=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION BirdSave;
    END CATCH;
    GOTO Result;
    BusinessFailure:
    IF @Entry=0 AND XACT_STATE()<>0 ROLLBACK;
    ELSE IF @Saved=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION BirdSave;
    Result:
    IF @Success=0 BEGIN SET @EventId=NULL; SET @Duplicate=0; END;
    SET @ResultCode=@Code;
    SELECT @Success AS Success,@Code AS Code,@ErrorNumber AS ErrorNumber,@EventId AS EventId,@Duplicate AS Duplicate;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_GetBirdMovementDaily
    @HouseId INT,@From DATETIME2,@To DATETIME2
AS
BEGIN
    SET NOCOUNT ON;
    IF @HouseId IS NULL OR @HouseId<=0 OR @From IS NULL OR @To IS NULL OR @From>=@To
        THROW 52710,'Invalid house or half-open date range.',1;
    IF NOT EXISTS(SELECT 1 FROM dbo.SwiftletHouses WHERE HouseId=@HouseId)
        THROW 52711,'House does not exist.',1;
    -- ObservedAt is a local wall-clock time in Asia/Saigon, never relabelled UTC.
    -- Traffic totals describe movements, not the number of resident birds.
    SELECT @HouseId AS HouseId,CONVERT(DATE,ObservedAt) AS ObservedDate,
        SUM(CASE WHEN Direction='IN' THEN CONVERT(BIGINT,BirdCount) ELSE CONVERT(BIGINT,0) END) AS InCount,
        SUM(CASE WHEN Direction='OUT' THEN CONVERT(BIGINT,BirdCount) ELSE CONVERT(BIGINT,0) END) AS OutCount,
        COUNT_BIG(*) AS EventCount,CAST('Asia/Saigon' AS VARCHAR(32)) AS TimeZone
    FROM dbo.BirdMovementEvents
    WHERE HouseId=@HouseId AND ObservedAt>=@From AND ObservedAt<@To
    GROUP BY CONVERT(DATE,ObservedAt)
    ORDER BY ObservedDate;
END;
GO
