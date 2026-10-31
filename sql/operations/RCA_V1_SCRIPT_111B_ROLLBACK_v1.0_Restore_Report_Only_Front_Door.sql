USE dbamaint;
GO
/*==============================================================================
 RCA V1 - SCRIPT 111B ROLLBACK v1.0

 Restores the pre-111B report-only usp_RCA_WhyIsDatabaseSlowV1 implementation.
 No capture, snapshot, or evidence data is deleted.
==============================================================================*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @@TRANCOUNT<>0
    THROW 63840,'SCRIPT 111B ROLLBACK ABORTED: run with no open transaction.',1;

IF OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1',N'P') IS NULL
    THROW 63841,'SCRIPT 111B ROLLBACK ABORTED: public front door is missing.',1;

IF OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1_Report',N'P') IS NULL
    THROW 63842,'SCRIPT 111B ROLLBACK ABORTED: preserved internal report is missing.',1;

IF EXISTS
(
    SELECT 1
    FROM dbo.RCA_CaptureRun
    WHERE CaptureStatus='CAPTURING'
      AND CaptureReason LIKE 'ONE-CALL LIVE RCA | DB=%'
)
    THROW 63843,'SCRIPT 111B ROLLBACK ABORTED: a one-call live RCA capture is active.',1;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP PROCEDURE dbo.usp_RCA_WhyIsDatabaseSlowV1;

    EXEC sys.sp_rename
         @objname=N'dbo.usp_RCA_WhyIsDatabaseSlowV1_Report',
         @newname=N'usp_RCA_WhyIsDatabaseSlowV1',
         @objtype=N'OBJECT';

    IF OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1',N'P') IS NULL
       OR OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1_Report',N'P') IS NOT NULL
        THROW 63844,'SCRIPT 111B ROLLBACK FAILED: original public object was not restored exactly once.',1;

    COMMIT TRANSACTION;

    SELECT
          'SCRIPT 111B ROLLBACK VERDICT' AS ValidationSection
        , 'PASS' AS Result
        , OBJECT_ID(N'dbo.usp_RCA_WhyIsDatabaseSlowV1',N'P') AS RestoredPublicObjectID
        , 'ORIGINAL REPORT-ONLY FRONT DOOR RESTORED' AS State
        , 'NO RCA CAPTURE OR EVIDENCE DATA DELETED' AS SafetyStatement;
END TRY
BEGIN CATCH
    DECLARE
          @ErrorNumber int=ERROR_NUMBER()
        , @ErrorLine int=ERROR_LINE()
        , @ErrorMessage nvarchar(4000)=ERROR_MESSAGE();

    IF XACT_STATE()<>0
        ROLLBACK TRANSACTION;

    SELECT
          'ERROR - SCRIPT 111B ROLLBACK' AS ValidationSection
        , @ErrorNumber AS ErrorNumber
        , @ErrorLine AS ErrorLine
        , @ErrorMessage AS ErrorMessage
        , @@TRANCOUNT AS OpenTransactionCount
        , 'ROLLBACK OF THE ROLLBACK WAS EXECUTED' AS SafetyStatus;

    THROW;
END CATCH;
GO
