USE SwiftletCare;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Additive migration. Event/control times use Asia/Saigon (UTC+07:00).
-- Existing RecordeAt/ExecuteAt values keep their original server-local convention.
BEGIN TRY
    BEGIN TRANSACTION;
    IF OBJECT_ID('dbo.SensorReadings','U') IS NULL
        THROW 52700,'Deploy the baseline schema first.',1;

    IF COL_LENGTH('dbo.SensorReadings','CO2Ppm') IS NULL
        EXEC(N'ALTER TABLE dbo.SensorReadings ADD CO2Ppm DECIMAL(8,2) NULL;');
    IF COL_LENGTH('dbo.SensorReadings','LightLux') IS NULL
        EXEC(N'ALTER TABLE dbo.SensorReadings ADD LightLux DECIMAL(9,2) NULL;');
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.SensorReadings')
        AND ((name='CO2Ppm' AND (system_type_id<>106 OR precision<>8 OR scale<>2 OR is_nullable<>1))
          OR (name='LightLux' AND (system_type_id<>106 OR precision<>9 OR scale<>2 OR is_nullable<>1))))
        THROW 52701,'Incompatible CO2/lux columns; inspect before migrating.',1;
    IF OBJECT_ID('dbo.CK_Readings_CO2Ppm','C') IS NULL
        EXEC(N'ALTER TABLE dbo.SensorReadings WITH CHECK ADD CONSTRAINT CK_Readings_CO2Ppm CHECK(CO2Ppm BETWEEN 0 AND 100000);');
    IF OBJECT_ID('dbo.CK_Readings_LightLux','C') IS NULL
        EXEC(N'ALTER TABLE dbo.SensorReadings WITH CHECK ADD CONSTRAINT CK_Readings_LightLux CHECK(LightLux BETWEEN 0 AND 200000);');

    -- Candidate keys let FKs enforce house/zone/device consistency, including
    -- subsequent reparenting/type changes through existing administration APIs.
    IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.Zones') AND name='UX_Zones_House_Zone')
        CREATE UNIQUE INDEX UX_Zones_House_Zone ON dbo.Zones(HouseId,ZoneId);
    IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.Devices') AND name='UX_Devices_Zone_Device')
        CREATE UNIQUE INDEX UX_Devices_Zone_Device ON dbo.Devices(ZoneId,DeviceId);
    IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.Devices') AND name='UX_Devices_Id_Type')
        CREATE UNIQUE INDEX UX_Devices_Id_Type ON dbo.Devices(DeviceId,DeviceType);

    -- House-level traffic only; no optional zone that could contradict HouseId.
    IF OBJECT_ID('dbo.BirdMovementEvents','U') IS NULL
        CREATE TABLE dbo.BirdMovementEvents (
            EventId BIGINT IDENTITY PRIMARY KEY,
            HouseId INT NOT NULL REFERENCES dbo.SwiftletHouses(HouseId),
            Direction VARCHAR(3) NOT NULL CHECK(Direction IN ('IN','OUT')),
            BirdCount INT NOT NULL CHECK(BirdCount>0),
            ObservedAt DATETIME2 NOT NULL,
            CreatedAt DATETIME2 NOT NULL DEFAULT DATEADD(HOUR,7,SYSUTCDATETIME()),
            SourceType VARCHAR(10) NOT NULL CHECK(SourceType IN ('SIMULATED','MANUAL')),
            SourceEventId UNIQUEIDENTIFIER NULL
        );
    IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.BirdMovementEvents') AND name='UX_Birds_Source_Event')
        CREATE UNIQUE INDEX UX_Birds_Source_Event ON dbo.BirdMovementEvents(HouseId,SourceType,SourceEventId) WHERE SourceEventId IS NOT NULL;
    IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.BirdMovementEvents') AND name='IX_Birds_House_Time')
        CREATE INDEX IX_Birds_House_Time ON dbo.BirdMovementEvents(HouseId,ObservedAt) INCLUDE(Direction,BirdCount);

    IF OBJECT_ID('dbo.DeviceControlSettings','U') IS NULL
        CREATE TABLE dbo.DeviceControlSettings (
            DeviceId INT NOT NULL PRIMARY KEY,
            DeviceType VARCHAR(30) NOT NULL CHECK(DeviceType IN ('FAN','HUMIDIFIER','LIGHT')),
            ControlMode VARCHAR(6) NOT NULL DEFAULT 'MANUAL' CHECK(ControlMode IN ('AUTO','MANUAL')),
            IsOn BIT NOT NULL DEFAULT 0,
            UpdatedAt DATETIME2 NOT NULL DEFAULT DATEADD(HOUR,7,SYSUTCDATETIME()),
            CONSTRAINT FK_ControlSettings_Actuator FOREIGN KEY(DeviceId,DeviceType) REFERENCES dbo.Devices(DeviceId,DeviceType)
        );
    -- Preserve old columns, checks and result shapes. NULL identifies legacy logs.
    IF COL_LENGTH('dbo.ControlLogs','ControlMode') IS NULL
        EXEC(N'ALTER TABLE dbo.ControlLogs ADD ControlMode VARCHAR(6) NULL;');
    IF COL_LENGTH('dbo.ControlLogs','ExecutionKind') IS NULL
        EXEC(N'ALTER TABLE dbo.ControlLogs ADD ExecutionKind VARCHAR(9) NULL;');
    IF OBJECT_ID('dbo.CK_ControlLogs_Simulation','C') IS NULL
        EXEC(N'ALTER TABLE dbo.ControlLogs WITH CHECK ADD CONSTRAINT CK_ControlLogs_Simulation CHECK
            ((ControlMode IS NULL AND ExecutionKind IS NULL) OR
             (ControlMode IS NOT NULL AND ControlMode IN (''AUTO'',''MANUAL'') AND ExecutionKind IS NOT NULL AND ExecutionKind=''SIMULATED''));');

    IF OBJECT_ID('dbo.SimulatedSystemEvents','U') IS NULL
        CREATE TABLE dbo.SimulatedSystemEvents (
            EventId BIGINT IDENTITY PRIMARY KEY,
            HouseId INT NOT NULL REFERENCES dbo.SwiftletHouses(HouseId),
            ZoneId INT NOT NULL,
            DeviceId INT NULL,
            EventType VARCHAR(30) NOT NULL CHECK(EventType IN ('PREDATOR_DETECTED','SPEAKER_FAILURE','ABNORMAL_SOUND','DEVICE_OFFLINE')),
            Severity VARCHAR(8) NOT NULL CHECK(Severity IN ('INFO','WARNING','CRITICAL')),
            EventAt DATETIME2 NOT NULL,
            CreatedAt DATETIME2 NOT NULL DEFAULT DATEADD(HOUR,7,SYSUTCDATETIME()),
            SourceType VARCHAR(9) NOT NULL DEFAULT 'SIMULATED' CHECK(SourceType='SIMULATED'),
            Message NVARCHAR(255) NOT NULL CHECK(LEN(LTRIM(RTRIM(Message)))>0),
            Status VARCHAR(12) NOT NULL DEFAULT 'NEW' CHECK(Status IN ('NEW','ACKNOWLEDGED','RESOLVED')),
            SourceEventId UNIQUEIDENTIFIER NULL,
            UpdatedAt DATETIME2 NULL,
            UpdatedBy INT NULL REFERENCES dbo.Users(UserID),
            CONSTRAINT CK_SystemEvents_State CHECK
                ((Status='NEW' AND UpdatedAt IS NULL AND UpdatedBy IS NULL) OR
                 (Status<>'NEW' AND UpdatedAt IS NOT NULL AND UpdatedBy IS NOT NULL)),
            CONSTRAINT FK_SystemEvents_Zone FOREIGN KEY(HouseId,ZoneId) REFERENCES dbo.Zones(HouseId,ZoneId),
            CONSTRAINT FK_SystemEvents_Device FOREIGN KEY(ZoneId,DeviceId) REFERENCES dbo.Devices(ZoneId,DeviceId)
        );
    IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.SimulatedSystemEvents') AND name='UX_SystemEvents_Source_Event')
        CREATE UNIQUE INDEX UX_SystemEvents_Source_Event ON dbo.SimulatedSystemEvents(HouseId,SourceType,SourceEventId) WHERE SourceEventId IS NOT NULL;
    IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.SimulatedSystemEvents') AND name='IX_SystemEvents_House_Time')
        CREATE INDEX IX_SystemEvents_House_Time ON dbo.SimulatedSystemEvents(HouseId,EventAt DESC,EventId DESC) INCLUDE(ZoneId,Status);
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
GO
