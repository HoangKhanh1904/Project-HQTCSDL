USE SwiftletCare;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- MIGRATION
BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID('dbo.Devices', 'U') IS NULL
       OR OBJECT_ID('dbo.EnvironmentThresholds', 'U') IS NULL
        THROW 52001, N'Chạy create_tables.sql trước khi migration.', 1;

    IF COL_LENGTH('dbo.EnvironmentThresholds', 'UpdateAt') IS NULL
        THROW 52004, N'Schema cần cột UpdateAt; dừng để kiểm tra tương thích, không tự đổi tên cột.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM sys.default_constraints
        WHERE parent_object_id = OBJECT_ID('dbo.Devices')
          AND parent_column_id = COLUMNPROPERTY(OBJECT_ID('dbo.Devices'), 'Status', 'ColumnId')
    )
        ALTER TABLE dbo.Devices ADD CONSTRAINT DF_Devices_Status DEFAULT 'ACTIVE' FOR Status;

    IF COL_LENGTH('dbo.Devices', 'DeviceName') IS NULL
        EXEC sys.sp_executesql N'ALTER TABLE dbo.Devices ADD DeviceName NVARCHAR(100) NULL;';

    IF EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.Devices') AND name = 'DeviceName'
          AND (system_type_id <> 231 OR max_length <> 200)
    )
        THROW 52002, N'DeviceName có kiểu không tương thích; cần kiểm tra trước khi migration.', 1;

    EXEC sys.sp_executesql N'
        UPDATE dbo.Devices SET DeviceName = CONCAT(N''Thiết bị '', DeviceId)
        WHERE DeviceName IS NULL;';

    IF EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.Devices') AND name = 'DeviceName' AND is_nullable = 1
    )
        EXEC sys.sp_executesql N'ALTER TABLE dbo.Devices ALTER COLUMN DeviceName NVARCHAR(100) NOT NULL;';

    IF COL_LENGTH('dbo.EnvironmentThresholds', 'RowVer') IS NULL
        EXEC sys.sp_executesql N'ALTER TABLE dbo.EnvironmentThresholds ADD RowVer ROWVERSION NOT NULL;';

    IF EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.EnvironmentThresholds') AND name = 'RowVer'
          AND system_type_id <> 189
    )
        THROW 52003, N'RowVer phải có kiểu ROWVERSION.', 1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
