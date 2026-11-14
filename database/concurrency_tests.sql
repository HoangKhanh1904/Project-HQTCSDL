USE SwiftletCare;
GO
SET NOCOUNT ON;

-- DEPLOYMENT CHECK
IF OBJECT_ID('dbo.sp_AcknowledgeAlert', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_GetEnvironmentThreshold', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_UpdateEnvironmentThreshold', 'P') IS NULL
    THROW 52101, N'Triển khai ba procedure trong database/concurrency trước khi kiểm thử.', 1;

SELECT name AS ProcedureName
FROM sys.procedures
WHERE schema_id = SCHEMA_ID('dbo')
  AND name IN ('sp_AcknowledgeAlert', 'sp_GetEnvironmentThreshold', 'sp_UpdateEnvironmentThreshold');

-- LEGACY INVENTORY
SELECT name AS LegacyDemoTable
FROM sys.tables
WHERE schema_id = SCHEMA_ID('dbo')
  AND name IN ('ConcurrencyDemoValue', 'ConcurrencyDemoItems');
GO
