USE dbamaint;
GO
SET NOCOUNT ON;
IF OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1_Live',N'P') IS NULL
 THROW 63930,'111F ROLLBACK ABORTED: preserved live wrapper is absent.',1;
DROP PROCEDURE IF EXISTS dbo.usp_RCA_WhyIsDatabaseSlowV1;
EXEC sys.sp_rename N'dbo.usp_RCA_WhyIsDatabaseSlowV1_Live',N'usp_RCA_WhyIsDatabaseSlowV1',N'OBJECT';
SELECT 'SCRIPT 111F ROLLBACK' ValidationSection,'PASS' Result,
       'LIVE ONE-CALL FRONT DOOR RESTORED; HISTORICAL DATA PRESERVED' RestoredState;
GO
