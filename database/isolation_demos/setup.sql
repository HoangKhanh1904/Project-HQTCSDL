USE SwiftletCare;
GO
SET XACT_ABORT ON;

-- OWNERSHIP
IF SCHEMA_ID('sc_isolation') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sys.extended_properties WHERE class=3 AND major_id=SCHEMA_ID('sc_isolation')
    AND name=N'SwiftletCareIsolation' AND CONVERT(NVARCHAR(100),value)=N'v1'
)
    THROW 52601,N'Schema sc_isolation chưa xác minh nguồn gốc; không ghi đè.',1;
IF SCHEMA_ID('sc_isolation') IS NULL
BEGIN
    EXEC(N'CREATE SCHEMA sc_isolation AUTHORIZATION dbo;');
    EXEC sys.sp_addextendedproperty @name=N'SwiftletCareIsolation',@value=N'v1',
         @level0type=N'SCHEMA',@level0name=N'sc_isolation';
END;
IF OBJECT_ID('sc_isolation.TaiKhoan','U') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sys.extended_properties WHERE class=1 AND major_id=OBJECT_ID('sc_isolation.TaiKhoan')
    AND name=N'SwiftletCareIsolation' AND CONVERT(NVARCHAR(100),value)=N'v1'
)
    THROW 52602,N'Bảng demo chưa xác minh nguồn gốc; không ghi đè.',1;
GO

-- TABLE
IF OBJECT_ID('sc_isolation.TaiKhoan','U') IS NULL
BEGIN
    CREATE TABLE sc_isolation.TaiKhoan (
        RunTag NVARCHAR(24) NOT NULL,
        matk INT NOT NULL,
        tentk NVARCHAR(100) NOT NULL,
        sotien DECIMAL(18,2) NOT NULL,
        CONSTRAINT PK_SCIsolation_TaiKhoan PRIMARY KEY(RunTag,matk)
    );
    EXEC sys.sp_addextendedproperty @name=N'SwiftletCareIsolation',@value=N'v1',
         @level0type=N'SCHEMA',@level0name=N'sc_isolation',@level1type=N'TABLE',@level1name=N'TaiKhoan';
END;
GO
CREATE OR ALTER PROCEDURE sc_isolation.sp_Fixture @RunTag NVARCHAR(24),@Mode VARCHAR(12)='HELP'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Mode='HELP'
    BEGIN
        SELECT 'SETUP, RESET, VERIFY, CLEANUP' AS Modes; RETURN;
    END;
    IF @RunTag IS NULL OR @RunTag=N'' OR @RunTag LIKE N'%[^a-zA-Z0-9_-]%'
       OR @Mode NOT IN ('SETUP','RESET','VERIFY','CLEANUP') OR @@TRANCOUNT<>0
        THROW 52603,N'Tham số fixture không hợp lệ hoặc transaction chưa kết thúc.',1;
    IF @Mode='VERIFY'
    BEGIN
        SELECT * FROM sc_isolation.TaiKhoan WHERE RunTag=@RunTag ORDER BY matk;
        SELECT @@SPID AS SPID,@@TRANCOUNT AS TranCount,XACT_STATE() AS XactState; RETURN;
    END;
    BEGIN TRY
        BEGIN TRANSACTION;
        IF EXISTS(SELECT 1 FROM sc_isolation.TaiKhoan WITH (UPDLOCK,HOLDLOCK) WHERE RunTag=@RunTag AND tentk<>N'SC_ISOLATION_FIXTURE_V1')
            THROW 52604,N'Fixture có dữ liệu không rõ nguồn gốc; không reset.',1;
        IF @Mode='SETUP' AND EXISTS(SELECT 1 FROM sc_isolation.TaiKhoan WHERE RunTag=@RunTag)
            THROW 52605,N'RunTag đã tồn tại.',1;
        IF @Mode IN ('RESET','CLEANUP') DELETE FROM sc_isolation.TaiKhoan WHERE RunTag=@RunTag;
        IF @Mode IN ('SETUP','RESET')
            INSERT sc_isolation.TaiKhoan(RunTag,matk,tentk,sotien)
            VALUES(@RunTag,1,N'SC_ISOLATION_FIXTURE_V1',1000),(@RunTag,2,N'SC_ISOLATION_FIXTURE_V1',2000);
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
