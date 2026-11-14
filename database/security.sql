USE SwiftletCare;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- VALIDATION
IF OBJECT_ID('dbo.sp_AcknowledgeAlert', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_GetEnvironmentThreshold', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_UpdateEnvironmentThreshold', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_InsertSensorReading', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_ResolveAlert', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_ReopenAlert', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_CreateEnvironmentThreshold', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_GetLatestSensorReadings', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_GetSensorHistory', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_GetUnresolvedAlerts', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_GetZoneDashboard', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_InsertBirdMovement', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_GetBirdMovementDaily', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_GetEnvironmentMetrics', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_InsertSimulatedSystemEvent', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_UpdateSimulatedEventStatus', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_GetSimulatedSystemEvents', 'P') IS NULL
   OR OBJECT_ID('dbo.sp_SimulateDeviceControl', 'P') IS NULL
    THROW 52201, N'Triển khai các procedure trước security.sql.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    -- ROLES
    IF DATABASE_PRINCIPAL_ID('SwiftletAdmin') IS NULL
        CREATE ROLE SwiftletAdmin AUTHORIZATION dbo;
    IF DATABASE_PRINCIPAL_ID('SwiftletStaff') IS NULL
        CREATE ROLE SwiftletStaff AUTHORIZATION dbo;
    IF DATABASE_PRINCIPAL_ID('SwiftletIngest') IS NULL
        CREATE ROLE SwiftletIngest AUTHORIZATION dbo;

    -- ADMIN
    REVOKE SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo FROM SwiftletAdmin;
    REVOKE EXECUTE ON SCHEMA::dbo FROM SwiftletAdmin;

    GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.Users TO SwiftletAdmin;
    GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.SwiftletHouses TO SwiftletAdmin;
    GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.Zones TO SwiftletAdmin;
    GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.Devices TO SwiftletAdmin;
    REVOKE INSERT, UPDATE, DELETE ON dbo.SensorReadings FROM SwiftletAdmin;
    GRANT SELECT ON dbo.SensorReadings TO SwiftletAdmin;
    GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.ControlLogs TO SwiftletAdmin;
    GRANT SELECT ON dbo.Alerts TO SwiftletAdmin;
    GRANT SELECT ON dbo.AlertActions TO SwiftletAdmin;
    GRANT SELECT ON dbo.EnvironmentThresholds TO SwiftletAdmin;

    DENY INSERT, UPDATE, DELETE ON dbo.Alerts TO SwiftletAdmin;
    DENY INSERT, UPDATE, DELETE ON dbo.AlertActions TO SwiftletAdmin;
    DENY INSERT, UPDATE, DELETE ON dbo.EnvironmentThresholds TO SwiftletAdmin;
    DENY INSERT, UPDATE, DELETE ON dbo.SensorReadings TO SwiftletAdmin;

    GRANT EXECUTE ON OBJECT::dbo.sp_AcknowledgeAlert TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetEnvironmentThreshold TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_UpdateEnvironmentThreshold TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_InsertSensorReading TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_ResolveAlert TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_ReopenAlert TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_CreateEnvironmentThreshold TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetLatestSensorReadings TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetSensorHistory TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetUnresolvedAlerts TO SwiftletAdmin;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetZoneDashboard TO SwiftletAdmin;

    -- STAFF
    REVOKE SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo FROM SwiftletStaff;
    REVOKE EXECUTE ON SCHEMA::dbo FROM SwiftletStaff;

    GRANT SELECT ON dbo.SwiftletHouses TO SwiftletStaff;
    GRANT SELECT ON dbo.Zones TO SwiftletStaff;
    GRANT SELECT ON dbo.Devices TO SwiftletStaff;
    GRANT SELECT ON dbo.SensorReadings TO SwiftletStaff;
    GRANT SELECT ON dbo.EnvironmentThresholds TO SwiftletStaff;
    GRANT SELECT ON dbo.Alerts TO SwiftletStaff;
    GRANT SELECT ON dbo.AlertActions TO SwiftletStaff;
    GRANT SELECT, INSERT ON dbo.ControlLogs TO SwiftletStaff;

    DENY INSERT, UPDATE, DELETE ON dbo.Users TO SwiftletStaff;
    DENY INSERT, UPDATE, DELETE ON dbo.SwiftletHouses TO SwiftletStaff;
    DENY INSERT, UPDATE, DELETE ON dbo.Zones TO SwiftletStaff;
    DENY INSERT, UPDATE, DELETE ON dbo.Devices TO SwiftletStaff;
    DENY INSERT, UPDATE, DELETE ON dbo.SensorReadings TO SwiftletStaff;
    DENY INSERT, UPDATE, DELETE ON dbo.Alerts TO SwiftletStaff;
    DENY INSERT, UPDATE, DELETE ON dbo.AlertActions TO SwiftletStaff;
    DENY INSERT, UPDATE, DELETE ON dbo.EnvironmentThresholds TO SwiftletStaff;
    DENY UPDATE, DELETE ON dbo.ControlLogs TO SwiftletStaff;
    DENY SELECT ON dbo.Users TO SwiftletStaff;

    GRANT EXECUTE ON OBJECT::dbo.sp_AcknowledgeAlert TO SwiftletStaff;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetEnvironmentThreshold TO SwiftletStaff;
    DENY EXECUTE ON OBJECT::dbo.sp_UpdateEnvironmentThreshold TO SwiftletStaff;
    DENY EXECUTE ON OBJECT::dbo.sp_CreateEnvironmentThreshold TO SwiftletStaff;
    DENY EXECUTE ON OBJECT::dbo.sp_InsertSensorReading TO SwiftletStaff;
    GRANT EXECUTE ON OBJECT::dbo.sp_ResolveAlert TO SwiftletStaff;
    GRANT EXECUTE ON OBJECT::dbo.sp_ReopenAlert TO SwiftletStaff;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetLatestSensorReadings TO SwiftletStaff;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetSensorHistory TO SwiftletStaff;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetUnresolvedAlerts TO SwiftletStaff;
    GRANT EXECUTE ON OBJECT::dbo.sp_GetZoneDashboard TO SwiftletStaff;

    -- INGEST
    GRANT EXECUTE ON OBJECT::dbo.sp_InsertSensorReading TO SwiftletIngest;
    DENY INSERT, UPDATE, DELETE ON dbo.SensorReadings TO SwiftletIngest;
    DENY INSERT, UPDATE, DELETE ON dbo.Alerts TO SwiftletIngest;
    DENY INSERT, UPDATE, DELETE ON dbo.AlertActions TO SwiftletIngest;
    DENY INSERT, UPDATE, DELETE ON dbo.EnvironmentThresholds TO SwiftletIngest;

    -- APPLICATION SIMULATION EXTENSION
    -- No change to legacy grants. New tables are writable only through APIs.
    GRANT SELECT ON dbo.BirdMovementEvents TO SwiftletAdmin,SwiftletStaff;
    GRANT SELECT ON dbo.DeviceControlSettings TO SwiftletAdmin,SwiftletStaff;
    GRANT SELECT ON dbo.SimulatedSystemEvents TO SwiftletAdmin,SwiftletStaff;
    DENY INSERT,UPDATE,DELETE ON dbo.BirdMovementEvents TO SwiftletAdmin,SwiftletStaff,SwiftletIngest;
    DENY INSERT,UPDATE,DELETE ON dbo.DeviceControlSettings TO SwiftletAdmin,SwiftletStaff,SwiftletIngest;
    DENY INSERT,UPDATE,DELETE ON dbo.SimulatedSystemEvents TO SwiftletAdmin,SwiftletStaff,SwiftletIngest;
    DENY SELECT ON dbo.BirdMovementEvents TO SwiftletIngest;
    DENY SELECT ON dbo.DeviceControlSettings TO SwiftletIngest;
    DENY SELECT ON dbo.SimulatedSystemEvents TO SwiftletIngest;
    GRANT EXECUTE ON dbo.sp_InsertBirdMovement TO SwiftletAdmin,SwiftletStaff,SwiftletIngest;
    GRANT EXECUTE ON dbo.sp_GetBirdMovementDaily TO SwiftletAdmin,SwiftletStaff;
    GRANT EXECUTE ON dbo.sp_GetEnvironmentMetrics TO SwiftletAdmin,SwiftletStaff;
    GRANT EXECUTE ON dbo.sp_GetSimulatedSystemEvents TO SwiftletAdmin,SwiftletStaff;
    GRANT EXECUTE ON dbo.sp_InsertSimulatedSystemEvent TO SwiftletAdmin,SwiftletIngest;
    DENY EXECUTE ON dbo.sp_InsertSimulatedSystemEvent TO SwiftletStaff;
    GRANT EXECUTE ON dbo.sp_UpdateSimulatedEventStatus TO SwiftletAdmin,SwiftletStaff;
    GRANT EXECUTE ON dbo.sp_SimulateDeviceControl TO SwiftletAdmin,SwiftletStaff;
    DENY EXECUTE ON dbo.sp_SimulateDeviceControl TO SwiftletIngest;
    DENY EXECUTE ON dbo.sp_UpdateSimulatedEventStatus TO SwiftletIngest;
    DENY EXECUTE ON dbo.sp_GetBirdMovementDaily TO SwiftletIngest;
    DENY EXECUTE ON dbo.sp_GetEnvironmentMetrics TO SwiftletIngest;
    DENY EXECUTE ON dbo.sp_GetSimulatedSystemEvents TO SwiftletIngest;
    DENY EXECUTE ON dbo.sp_TransitionAlert TO SwiftletAdmin,SwiftletStaff,SwiftletIngest;

    -- Demo SQL principals are permission fixtures, not authenticated app users.
    -- The backend must obtain @UserId from its authenticated session.
    -- DEMO PRINCIPALS
    IF DATABASE_PRINCIPAL_ID('swiftlet_admin_demo') IS NULL
        CREATE USER swiftlet_admin_demo WITHOUT LOGIN;
    IF DATABASE_PRINCIPAL_ID('swiftlet_staff_demo') IS NULL
        CREATE USER swiftlet_staff_demo WITHOUT LOGIN;
    IF DATABASE_PRINCIPAL_ID('swiftlet_ingest_demo') IS NULL
        CREATE USER swiftlet_ingest_demo WITHOUT LOGIN;

    IF NOT EXISTS (
        SELECT 1 FROM sys.database_role_members
        WHERE role_principal_id = DATABASE_PRINCIPAL_ID('SwiftletAdmin')
          AND member_principal_id = DATABASE_PRINCIPAL_ID('swiftlet_admin_demo')
    )
        ALTER ROLE SwiftletAdmin ADD MEMBER swiftlet_admin_demo;

    IF NOT EXISTS (
        SELECT 1 FROM sys.database_role_members
        WHERE role_principal_id = DATABASE_PRINCIPAL_ID('SwiftletStaff')
          AND member_principal_id = DATABASE_PRINCIPAL_ID('swiftlet_staff_demo')
    )
        ALTER ROLE SwiftletStaff ADD MEMBER swiftlet_staff_demo;
    IF NOT EXISTS (SELECT 1 FROM sys.database_role_members
                   WHERE role_principal_id=DATABASE_PRINCIPAL_ID('SwiftletIngest')
                     AND member_principal_id=DATABASE_PRINCIPAL_ID('swiftlet_ingest_demo'))
        ALTER ROLE SwiftletIngest ADD MEMBER swiftlet_ingest_demo;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
