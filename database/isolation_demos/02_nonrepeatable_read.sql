USE SwiftletCare;
GO
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=3 AND major_id=SCHEMA_ID('sc_isolation') AND name=N'SwiftletCareIsolation' AND CONVERT(NVARCHAR(100),value)=N'v1') THROW 52611,'Deploy the owned isolation setup first.',1;
GO

-- SESSION T1
CREATE OR ALTER PROCEDURE sc_isolation.sp_unrepeatable_read_T1 @RunTag NVARCHAR(24),@Fix BIT=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 15000;
    IF @@TRANCOUNT<>0 OR @Fix IS NULL OR NOT EXISTS(SELECT 1 FROM sc_isolation.TaiKhoan WITH (READUNCOMMITTED) WHERE RunTag=@RunTag AND matk=1)
        THROW 52610,'Start with a fresh fixture and no ambient transaction.',1;
    DECLARE @First DECIMAL(18,2),@Second DECIMAL(18,2);
    BEGIN TRY
        IF @Fix=1 SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
        ELSE SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        BEGIN TRANSACTION;
        SELECT @First=sotien FROM sc_isolation.TaiKhoan WHERE RunTag=@RunTag AND matk=1;
        WAITFOR DELAY '00:00:04';
        SELECT @Second=sotien FROM sc_isolation.TaiKhoan WHERE RunTag=@RunTag AND matk=1;
        COMMIT;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        SELECT @@SPID AS SPID,@Fix AS Fix,@First AS FirstValue,@Second AS SecondValue,
               @@TRANCOUNT AS TranCount,XACT_STATE() AS XactState,SYSDATETIME() AS FinishedAt;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        THROW;
    END CATCH;
END;
GO

-- SESSION T2
CREATE OR ALTER PROCEDURE sc_isolation.sp_unrepeatable_read_T2 @RunTag NVARCHAR(24),@Fix BIT=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 15000;
    IF @@TRANCOUNT<>0 OR @Fix IS NULL OR NOT EXISTS(SELECT 1 FROM sc_isolation.TaiKhoan WITH (READUNCOMMITTED) WHERE RunTag=@RunTag AND matk=1)
        THROW 52610,'Start with a fresh fixture and no ambient transaction.',1;
    DECLARE @First DECIMAL(18,2),@Second DECIMAL(18,2);
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        BEGIN TRANSACTION;
        UPDATE sc_isolation.TaiKhoan SET sotien=sotien+100 WHERE RunTag=@RunTag AND matk=1;
        SELECT @Second=sotien FROM sc_isolation.TaiKhoan WHERE RunTag=@RunTag AND matk=1;
        COMMIT;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        SELECT @@SPID AS SPID,@Fix AS Fix,@First AS FirstValue,@Second AS SecondValue,
               @@TRANCOUNT AS TranCount,XACT_STATE() AS XactState,SYSDATETIME() AS FinishedAt;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        THROW;
    END CATCH;
END;
GO

-- RESET
-- EXEC sc_isolation.sp_Fixture N'my_demo','RESET';
-- SESSION T1
-- EXEC sc_isolation.sp_unrepeatable_read_T1 N'my_demo',0;
-- SESSION T2
-- EXEC sc_isolation.sp_unrepeatable_read_T2 N'my_demo',0;
-- FIX
-- EXEC sc_isolation.sp_unrepeatable_read_T1 N'my_demo',1;
-- EXEC sc_isolation.sp_unrepeatable_read_T2 N'my_demo',1;
-- CLEANUP
-- EXEC sc_isolation.sp_Fixture N'my_demo','CLEANUP';
