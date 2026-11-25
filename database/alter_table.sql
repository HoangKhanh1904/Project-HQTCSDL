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

    -- P1: ngưỡng ánh sáng cho quy tắc LIGHT AUTO. Không có giá trị mặc định:
    -- hàng cũ giữ cả hai cột NULL, nghĩa là "chưa cấu hình ngưỡng sáng".
    IF COL_LENGTH('dbo.EnvironmentThresholds', 'MinLightLux') IS NULL
        EXEC sys.sp_executesql N'ALTER TABLE dbo.EnvironmentThresholds ADD MinLightLux DECIMAL(9,2) NULL;';

    IF COL_LENGTH('dbo.EnvironmentThresholds', 'MaxLightLux') IS NULL
        EXEC sys.sp_executesql N'ALTER TABLE dbo.EnvironmentThresholds ADD MaxLightLux DECIMAL(9,2) NULL;';

    IF EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.EnvironmentThresholds')
          AND name IN ('MinLightLux', 'MaxLightLux')
          AND (system_type_id <> 106 OR precision <> 9 OR scale <> 2)
    )
        THROW 52800, N'MinLightLux/MaxLightLux phải có kiểu DECIMAL(9,2); dừng để kiểm tra tương thích, không tự đổi kiểu cột.', 1;

    -- Cột mới chỉ được tham chiếu trong batch động: cùng batch sẽ được biên
    -- dịch trước khi ALTER TABLE ở trên chạy, nên tham chiếu trực tiếp báo lỗi 207.
    DECLARE @InvalidLightRows INT = 0;
    EXEC sys.sp_executesql N'
        SELECT @Count = COUNT(*) FROM dbo.EnvironmentThresholds
        WHERE (MinLightLux IS NULL AND MaxLightLux IS NOT NULL)
           OR (MinLightLux IS NOT NULL AND MaxLightLux IS NULL)
           OR MinLightLux NOT BETWEEN 0 AND 200000
           OR MaxLightLux NOT BETWEEN 0 AND 200000
           OR MinLightLux > MaxLightLux;',
        N'@Count INT OUTPUT', @Count = @InvalidLightRows OUTPUT;
    IF @InvalidLightRows > 0
        THROW 52801, N'Dữ liệu ngưỡng sáng hiện có không hợp lệ (cần cả hai cột, 0..200000, Min <= Max); sửa tay trước khi migration.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM sys.check_constraints
        WHERE parent_object_id = OBJECT_ID('dbo.EnvironmentThresholds')
          AND name = 'Ck_Thresholds_Light'
    )
    BEGIN TRY
        EXEC sys.sp_executesql N'
            ALTER TABLE dbo.EnvironmentThresholds WITH CHECK
            ADD CONSTRAINT Ck_Thresholds_Light CHECK (
                (MinLightLux IS NULL AND MaxLightLux IS NULL)
                OR (MinLightLux IS NOT NULL AND MaxLightLux IS NOT NULL
                    AND MinLightLux BETWEEN 0 AND 200000
                    AND MaxLightLux BETWEEN 0 AND 200000
                    AND MinLightLux <= MaxLightLux)
            );';
    END TRY
    BEGIN CATCH
        THROW 52802, N'Không thể tạo CHECK Ck_Thresholds_Light; dữ liệu ngưỡng sáng hiện có chưa thỏa điều kiện.', 1;
    END CATCH;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
