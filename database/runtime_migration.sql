USE SwiftletCare;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- MIGRATION
BEGIN TRY
    BEGIN TRANSACTION;
    IF OBJECT_ID('dbo.SensorReadings', 'U') IS NULL
        THROW 52401, N'Chạy create_tables.sql trước migration.', 1;
    IF COL_LENGTH('dbo.SensorReadings', 'SourceEventId') IS NULL
        EXEC sys.sp_executesql N'ALTER TABLE dbo.SensorReadings ADD SourceEventId UNIQUEIDENTIFIER NULL;';
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.SensorReadings')
               AND name='SourceEventId' AND (system_type_id<>36 OR is_nullable<>1))
        THROW 52402, N'SourceEventId không tương thích; không tự thay đổi cột.', 1;
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.SensorReadings') AND name='UX_Readings_Device_Event')
        EXEC sys.sp_executesql N'CREATE UNIQUE INDEX UX_Readings_Device_Event ON dbo.SensorReadings(DeviceId, SourceEventId) WHERE SourceEventId IS NOT NULL;';
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.SensorReadings')
               AND name='IX_Readings_Device_Time' AND (type<>2 OR is_unique=1 OR has_filter=1))
        THROW 52403,N'Index lịch sử không đúng dạng dự kiến; cần kiểm tra thủ công.',1;
    IF EXISTS (SELECT 1 FROM sys.index_columns ic
               JOIN sys.indexes i ON i.object_id=ic.object_id AND i.index_id=ic.index_id
               JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
               WHERE i.object_id=OBJECT_ID('dbo.SensorReadings') AND i.name='IX_Readings_Device_Time' AND ic.key_ordinal>0
                 AND NOT ((ic.key_ordinal=1 AND c.name='DeviceId' AND ic.is_descending_key=0)
                       OR (ic.key_ordinal=2 AND c.name='RecordeAt' AND ic.is_descending_key=1)
                       OR (ic.key_ordinal=3 AND c.name='ReadingId' AND ic.is_descending_key=1)))
        THROW 52404,N'Khóa index lịch sử khác thiết kế; không tự ghi đè.',1;

    -- HISTORY INDEX
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.SensorReadings') AND name='IX_Readings_Device_Time')
        EXEC sys.sp_executesql N'CREATE INDEX IX_Readings_Device_Time ON dbo.SensorReadings(DeviceId,RecordeAt DESC,ReadingId DESC) INCLUDE(Temperature,Humidity);';
    ELSE IF (SELECT COUNT(*) FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id=ic.object_id AND i.index_id=ic.index_id
             WHERE i.object_id=OBJECT_ID('dbo.SensorReadings') AND i.name='IX_Readings_Device_Time' AND ic.key_ordinal>0)<>3
         OR (SELECT COUNT(*) FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id=ic.object_id AND i.index_id=ic.index_id
             JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
             WHERE i.object_id=OBJECT_ID('dbo.SensorReadings') AND i.name='IX_Readings_Device_Time'
               AND ic.is_included_column=1 AND c.name IN ('Temperature','Humidity'))<>2
        EXEC sys.sp_executesql N'CREATE INDEX IX_Readings_Device_Time ON dbo.SensorReadings(DeviceId,RecordeAt DESC,ReadingId DESC) INCLUDE(Temperature,Humidity) WITH(DROP_EXISTING=ON);';
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
GO
