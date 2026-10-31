USE SwiftletCare;
GO

-- 1. Users
IF OBJECT_ID('dbo.Users', 'U') IS NULL
BEGIN
CREATE TABLE dbo.Users (
    UserID INT IDENTITY(1,1) PRIMARY KEY,
    UserName NVARCHAR(50) NOT NULL UNIQUE,
    PasswordHash NVARCHAR (255) NOT NULL,
    FullName NVARCHAR(100) NOT NULL,
    Role VARCHAR(20) NOT NULL DEFAULT 'STAFF',
    IsActive BIT NOT NULL DEFAULT 1,
    CreateAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),

    CONSTRAINT Ck_Users_Role
    CHECK (Role IN ('ADMIN', 'STAFF'))
);
END;
GO

-- 2. SWIFTLET HOUSES
IF OBJECT_ID('dbo.SwiftletHouses', 'U') IS NULL
BEGIN
CREATE TABLE dbo.SwiftletHouses (
    HouseId INT IDENTITY(1,1) PRIMARY KEY,
    HouseName NVARCHAR(100) NOT NULL,
    Address NVARCHAR(255) NULL,
    ManagerId INT NOT NULL,
    Status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    CreateAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),

    CONSTRAINT Fk_Houses_Users
    FOREIGN KEY (ManagerId) REFERENCES dbo.Users(UserID),

    CONSTRAINT Ck_Houses_Status
    CHECK (Status IN('ACTIVE', 'INACTIVE'))
);
END;
GO

-- 3. ZONES
IF OBJECT_ID('dbo.Zones', 'U') IS NULL
BEGIN
CREATE TABLE dbo.Zones (
    ZoneId INT IDENTITY(1,1) PRIMARY KEY,
    HouseId INT NOT NULL,
    ZoneName NVARCHAR(100) NOT NULL,
    Description NVARCHAR(255) NULL,
    Status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',

    CONSTRAINT Fk_Zones_Houses
    FOREIGN KEY (HouseId) REFERENCES dbo.SwiftletHouses(HouseId),

    CONSTRAINT UQ_Zones_House_Name
    UNIQUE (HouseId, ZoneName),

    CONSTRAINT CK_Zones_Status
    CHECK (Status IN ('ACTIVE', 'INACTIVE'))
);
END;
GO

-- 4. DEVICES
IF OBJECT_ID('dbo.Devices', 'U') IS NULL
BEGIN
CREATE TABLE dbo.Devices (
    DeviceId INT IDENTITY(1,1) PRIMARY KEY,
    DeviceName NVARCHAR(100) NOT NULL,
    ZoneId INT NOT NULL,
    DeviceType VARCHAR(30) NOT NULL,
    Status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    InstalledAt DATETIME2 NULL,

    CONSTRAINT Fk_Devices_Zones
    FOREIGN KEY (ZoneId) REFERENCES dbo.Zones(ZoneId),

    CONSTRAINT Ck_Devices_Type
    CHECK (DeviceType IN ('SENSOR', 'FAN', 'HUMIDIFIER', 'LIGHT')),

    CONSTRAINT Ck_Devices_Status
    CHECK (Status IN ('ACTIVE', 'INACTIVE', 'MAINTENANCE'))
);
END;
GO

-- 5. SENSOR READINGS
IF OBJECT_ID('dbo.SensorReadings', 'U') IS NULL
BEGIN
CREATE TABLE dbo.SensorReadings (
    ReadingId BIGINT IDENTITY(1,1) PRIMARY KEY,
    DeviceId INT NOT NULL,
    Temperature DECIMAL(5,2) NOT NULL,
    Humidity DECIMAL(5,2) NOT NULL,
    RecordeAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    SourceEventId UNIQUEIDENTIFIER NULL,

    CONSTRAINT Fk_Readings_Devices
    FOREIGN KEY (DeviceId) REFERENCES dbo.Devices(DeviceId),

    CONSTRAINT Ck_Readings_Temperature
    CHECK (Temperature BETWEEN -40 AND 100),

    CONSTRAINT Ck_Readings_Humidity
    CHECK (Humidity BETWEEN 0 AND 100)
);
END;
GO

-- INGEST IDEMPOTENCY
IF COL_LENGTH('dbo.SensorReadings', 'SourceEventId') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.SensorReadings') AND name='UX_Readings_Device_Event')
    EXEC sys.sp_executesql N'CREATE UNIQUE INDEX UX_Readings_Device_Event ON dbo.SensorReadings(DeviceId, SourceEventId) WHERE SourceEventId IS NOT NULL;';
GO


-- 6. ENVIRONMENT THRESHOLDS
IF OBJECT_ID('dbo.EnvironmentThresholds', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.EnvironmentThresholds (
        ThresholdsId INT IDENTITY(1,1) PRIMARY KEY,
        ZoneId INT NOT NULL UNIQUE,
        MinTemperature DECIMAL(5,2) NOT NULL,
        MaxTemperature DECIMAL(5,2) NOT NULL,
        MinHumidity DECIMAL(5,2) NOT NULL,
        MaxHumidity DECIMAL(5,2) NOT NULL,
        UpdateAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),

        RowVer ROWVERSION NOT NULL,

        CONSTRAINT Fk_Thresholds_Zones
            FOREIGN KEY (ZoneId) REFERENCES dbo.Zones(ZoneId),

        CONSTRAINT Ck_Thresholds_Temperature
            CHECK (
                MinTemperature BETWEEN -40 AND 100
                AND MaxTemperature BETWEEN -40 AND 100
                AND MinTemperature <= MaxTemperature
            ),

        CONSTRAINT Ck_Thresholds_Humidity
            CHECK (
                MinHumidity BETWEEN 0 AND 100
                AND MaxHumidity BETWEEN 0 AND 100
                AND MinHumidity <= MaxHumidity
            )
    );
END;
GO


-- 7. ALERTS
IF OBJECT_ID('dbo.Alerts', 'U') IS NULL
BEGIN
CREATE TABLE dbo.Alerts (
    AlertId BIGINT IDENTITY(1,1) PRIMARY KEY,
    ZoneId INT NOT NULL,
    ReadingId BIGINT NOT NULL,
    AlertType VARCHAR(30) NOT NULL,
    Message NVARCHAR(255) NOT NULL,
    Status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    ResolvedAt DATETIME2 NULL,

    CONSTRAINT Fk_Alerts_Zones
    FOREIGN KEY (ZoneId) REFERENCES dbo.Zones(ZoneId),

    CONSTRAINT Fk_Alerts_Readings
    FOREIGN KEY (ReadingId) REFERENCES dbo.SensorReadings(ReadingId),

    CONSTRAINT Ck_Alerts_Type
    CHECK (AlertType IN (
        'HIGH_TEMP', 'LOW_TEMP', 'HIGH_HUMIDITY', 'LOW_HUMIDITY'
    ) ),

    CONSTRAINT Ck_Alerts_Status
    CHECK (Status IN ('PENDING', 'ACKNOWLEDGED', 'RESOLVED')),

    CONSTRAINT Ck_Alerts_ResolvedAt
    CHECK ((Status = 'RESOLVED' AND ResolvedAt IS NOT NULL)
    OR
    (Status <> 'RESOLVED' AND ResolvedAt IS NULL))
);
END;
GO

-- 8. ALERT ACTIONS
IF OBJECT_ID('dbo.AlertActions', 'U') IS NULL
BEGIN
CREATE TABLE dbo.AlertActions (
    ActionId BIGINT IDENTITY(1,1) PRIMARY KEY,
    AlertId BIGINT NOT NULL,
    UserId INT NOT NULL,
    ActionType VARCHAR(30) NOT NULL,
    Note NVARCHAR(255) NULL,
    ActionAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),

    CONSTRAINT Fk_Actions_Alerts
    FOREIGN KEY (AlertId) REFERENCES dbo.Alerts(AlertId),

    CONSTRAINT Fk_Actions_Users
    FOREIGN KEY (UserId) REFERENCES dbo.Users(UserID),

    CONSTRAINT Ck_Actions_Type
    CHECK (ActionType IN ('ACKNOWLEDGE', 'RESOLVE', 'REOPEN'))
);
END;
GO

-- 9. CONTROL LOGS
IF OBJECT_ID('dbo.ControlLogs', 'U') IS NULL
BEGIN
CREATE TABLE dbo.ControlLogs (
    ControlLogId BIGINT IDENTITY(1,1) PRIMARY KEY,
    DeviceId INT NOT NULL,
    UserId INT NOT NULL,
    Command VARCHAR(20) NOT NULL,
    Result VARCHAR(20) NOT NULL,
    ExecuteAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),

    CONSTRAINT Fk_ControlLogs_Devices
    FOREIGN KEY (DeviceId) REFERENCES dbo.Devices(DeviceId),

    CONSTRAINT Fk_ControlLogs_Users
    FOREIGN KEY (UserId) REFERENCES dbo.Users(UserID),

    CONSTRAINT Ck_ControlLogs_Command
    CHECK (Command IN ('TURN_ON', 'TURN_OFF')),

    CONSTRAINT Ck_ControlLogs_Result
    CHECK (Result IN ('SUCCESS','FAILED'))
);
END;
GO

-- 10. INDEXES FOR COMMON QUERIES
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Readings_Device_Time'
    AND object_id = OBJECT_ID('dbo.SensorReadings')
)
BEGIN
CREATE INDEX IX_Readings_Device_Time
ON dbo.SensorReadings(DeviceId, RecordeAt DESC, ReadingId DESC)
INCLUDE (Temperature, Humidity);
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Alerts_Zone_Status'
    AND object_id = OBJECT_ID('dbo.Alerts')
)
BEGIN
CREATE INDEX IX_Alerts_Zone_Status
ON dbo.Alerts(ZoneId, Status);
END;
GO
-- ALERT HISTORY INDEX
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.AlertActions') AND name = 'IX_AlertActions_Alert_Time'
)
    CREATE INDEX IX_AlertActions_Alert_Time
    ON dbo.AlertActions(AlertId, ActionAt, ActionId);
GO
