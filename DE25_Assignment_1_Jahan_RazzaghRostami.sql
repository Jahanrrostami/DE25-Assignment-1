-- Döp den här filen till: DE25_Assignment_1_Jahan_RazzaghRostami
-- Placera din kod enligt följande:
--
-- Formeln är kontrollerad mot exempelraderna i kalkylbladet.
--   Ålder              = årtalet i körningsmånaden - ManufactureYear
--   Slutränta          = BaseInterestRate + MarginRate + RiskAdjustment
--   Månadskostnad      = BasePrice * Slutränta / 100 / 12
--   Värde i år         = BasePrice * (1 - årets avskrivning)
--   Avskrivning i år   = BasePrice * (årets sats - förra årets sats)
--   EstimatedProfit    = BasePrice * Slutränta / 100 - avskrivning i år
-- Förra årets sats är 0 när bilen var 0 år. Då gäller inte bandet 0-1.
-- EcoCar X1 i maj 2025: 35000 * 11.70 / 100 - 3500 = 595.

-- =============================================================================
-- 1. Saker som behöver köras innan jag skapar ditt jobbsteg:
-- =============================================================================

SET NOCOUNT ON;

IF DB_ID(N'Assignment1') IS NULL
    CREATE DATABASE Assignment1;
GO

USE Assignment1;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF NOT EXISTS (
    SELECT 1
    FROM sys.configurations
    WHERE name = N'Database Mail XPs'
      AND value_in_use = 1
)
BEGIN
    EXEC sys.sp_configure N'show advanced options', 1;
    RECONFIGURE;
    EXEC sys.sp_configure N'Database Mail XPs', 1;
    RECONFIGURE;
END;

IF OBJECT_ID(N'dbo.InterestRates', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InterestRates (
        RateID           int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
        EffectiveDate    date          NOT NULL,
        BaseInterestRate decimal(5,2)  NOT NULL,
        CONSTRAINT UQ_InterestRates_EffectiveDate UNIQUE (EffectiveDate)
    );
END;

IF OBJECT_ID(N'dbo.EnergyClassMargin', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.EnergyClassMargin (
        EnergyClass nvarchar(20) NOT NULL PRIMARY KEY,
        MarginRate  decimal(5,2) NOT NULL
    );
END;

-- Bandet följer formelbladet: 4-5 år är 0.35 och från 6 år är satsen 0.50.
IF OBJECT_ID(N'dbo.DepreciationRates', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DepreciationRates (
        MinYear          int          NOT NULL,
        MaxYear          int          NOT NULL,
        DepreciationRate decimal(5,2) NOT NULL,
        CONSTRAINT PK_DepreciationRates PRIMARY KEY (MinYear, MaxYear)
    );
END;

IF OBJECT_ID(N'dbo.CreditRiskTier', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CreditRiskTier (
        RiskTier       nvarchar(20) NOT NULL PRIMARY KEY,
        RiskAdjustment decimal(5,2) NOT NULL
    );
END;

IF OBJECT_ID(N'dbo.ETL_Log', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ETL_Log (
        LogID        bigint           IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunID        uniqueidentifier NOT NULL,
        LogTime      datetime2(0)     NOT NULL CONSTRAINT DF_ETL_Log_LogTime DEFAULT (SYSDATETIME()),
        Severity     varchar(10)      NOT NULL,
        StepName     nvarchar(80)     NOT NULL,
        Message      nvarchar(4000)   NOT NULL,
        RowsAffected int              NULL
    );

    CREATE INDEX IX_ETL_Log_RunID ON dbo.ETL_Log (RunID, LogID);
END;

IF OBJECT_ID(N'dbo.ETL_MailConfig', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ETL_MailConfig (
        ConfigID    int           NOT NULL CONSTRAINT PK_ETL_MailConfig PRIMARY KEY,
        ProfileName sysname       NOT NULL,
        Recipients  nvarchar(500) NOT NULL,
        CONSTRAINT CK_ETL_MailConfig_OneRow CHECK (ConfigID = 1)
    );
END;

IF NOT EXISTS (SELECT 1 FROM dbo.ETL_MailConfig WHERE ConfigID = 1)
BEGIN
    INSERT INTO dbo.ETL_MailConfig (ConfigID, ProfileName, Recipients)
    VALUES (1, N'NackademinMail', N'you@example.com');
END;

UPDATE dbo.ETL_MailConfig
SET Recipients = N'you@example.com'
WHERE ConfigID = 1
  AND Recipients = N'you@example.com';

IF OBJECT_ID(N'dbo.EnergyClassSynonym', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.EnergyClassSynonym (
        RawValue    nvarchar(50) NOT NULL PRIMARY KEY,
        EnergyClass nvarchar(20) NOT NULL
    );
END;

IF NOT EXISTS (SELECT 1 FROM dbo.EnergyClassMargin)
BEGIN
    INSERT INTO dbo.EnergyClassMargin (EnergyClass, MarginRate) VALUES
        (N'Diesel',   0.90),
        (N'Electric', 0.35),
        (N'Gasoline', 0.70),
        (N'Hybrid',   0.50);
END;

IF NOT EXISTS (SELECT 1 FROM dbo.CreditRiskTier)
BEGIN
    INSERT INTO dbo.CreditRiskTier (RiskTier, RiskAdjustment) VALUES
        (N'Average',   0.25),
        (N'Excellent', -0.40),
        (N'Good',      -0.15),
        (N'Poor',       0.60);
END;

IF NOT EXISTS (SELECT 1 FROM dbo.DepreciationRates)
BEGIN
    INSERT INTO dbo.DepreciationRates (MinYear, MaxYear, DepreciationRate) VALUES
        (0,    1, 0.10),
        (2,    3, 0.20),
        (4,    5, 0.35),
        (6, 1000, 0.50);
END;

-- Maj 2025 och november 2026 har en egen ränta.
-- Oktober 2026 finns kvar så att reservräntan kan provas.
IF NOT EXISTS (SELECT 1 FROM dbo.InterestRates)
BEGIN
    INSERT INTO dbo.InterestRates (EffectiveDate, BaseInterestRate) VALUES
        ('2025-04-01', 11.50),
        ('2025-05-01', 11.75),
        ('2026-10-01', 11.50),
        ('2026-11-01', 11.75);
END;

MERGE dbo.EnergyClassSynonym AS tgt
USING (VALUES
    (N'electric', N'Electric'),
    (N'el',       N'Electric'),
    (N'ev',       N'Electric'),
    (N'gas',      N'Gasoline'),
    (N'gasoline', N'Gasoline'),
    (N'bensin',   N'Gasoline'),
    (N'diesel',   N'Diesel'),
    (N'hybrid',   N'Hybrid')
) AS src (RawValue, EnergyClass)
ON tgt.RawValue = src.RawValue
WHEN NOT MATCHED BY TARGET THEN
    INSERT (RawValue, EnergyClass) VALUES (src.RawValue, src.EnergyClass);

-- Räkneexemplet från formelbladet. Körs med @YearMonth = '202505'.
IF OBJECT_ID(N'dbo.CarInformation_202505', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CarInformation_202505 (
        RecordID         int            NOT NULL PRIMARY KEY,
        CarModel         nvarchar(100)  NULL,
        EnergyClass      nvarchar(20)   NULL,
        ManufactureYear  int            NULL,
        BasePrice        decimal(10,2)  NULL,
        FileMonth        date           NULL,
        CustomerRiskTier nvarchar(20)   NULL
    );

    INSERT INTO dbo.CarInformation_202505
        (RecordID, CarModel, EnergyClass, ManufactureYear, BasePrice, FileMonth, CustomerRiskTier)
    VALUES
        (1, N'EcoCar X1',      N'Electric', 2023, 35000.00, '2025-05-01', N'Excellent'),
        (2, N'Speedster G2',   N'Gasoline', 2020, 27000.00, '2025-05-01', N'Good'),
        (3, N'FamilyVan D3',   N'Diesel',   2018, 22000.00, '2025-05-01', N'Average'),
        (4, N'Compact EV4',    N'Electric', 2024, 32000.00, '2025-05-01', N'Poor'),
        (5, N'Hybrid Cruiser', N'Hybrid',   2021, 31000.00, '2025-05-01', N'Good');
END;

-- Månaden som jobbet träffar när det körs i november 2026.
IF OBJECT_ID(N'dbo.CarInformation_202611', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CarInformation_202611 (
        RecordID         int            NOT NULL PRIMARY KEY,
        CarModel         nvarchar(100)  NULL,
        EnergyClass      nvarchar(20)   NULL,
        ManufactureYear  int            NULL,
        BasePrice        decimal(10,2)  NULL,
        FileMonth        date           NULL,
        CustomerRiskTier nvarchar(20)   NULL
    );

    INSERT INTO dbo.CarInformation_202611
        (RecordID, CarModel, EnergyClass, ManufactureYear, BasePrice, FileMonth, CustomerRiskTier)
    VALUES
        (1, N'EcoCar X1',      N'Electric', 2023, 35000.00, '2026-11-01', N'Excellent'),
        (2, N'Speedster G2',   N'Gasoline', 2020, 27000.00, '2026-11-01', N'Good'),
        (3, N'FamilyVan D3',   N'Diesel',   2018, 22000.00, '2026-11-01', N'Average'),
        (4, N'Compact EV4',    N'Electric', 2024, 32000.00, '2026-11-01', N'Poor'),
        (5, N'Hybrid Cruiser', N'Hybrid',   2021, 31000.00, '2026-11-01', N'Good');
END;

DROP TABLE IF EXISTS dbo.CarInformation_Staging;
CREATE TABLE dbo.CarInformation_Staging (
    StageRowID       int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    RecordID         int            NULL,
    CarModel         nvarchar(100)  NULL,
    EnergyClassRaw   nvarchar(50)   NULL,
    EnergyClass      nvarchar(20)   NULL,
    ManufactureYear  int            NULL,
    BasePrice        decimal(18,2)  NULL,
    FileMonth        date           NULL,
    CustomerRiskTier nvarchar(20)   NULL,
    VehicleAge       int            NULL,
    IsValid          bit            NOT NULL CONSTRAINT DF_CarInformation_Staging_IsValid DEFAULT (0),
    RejectReason     nvarchar(400)  NULL
);
GO

-- =============================================================================
-- 2. Ditt jobbsteg (Stored Procedure):
-- =============================================================================

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LoadLoanProfitEstimates
    @YearMonth char(6) = NULL  -- Tom parameter: månaden tas från GETUTCDATE().
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RunID uniqueidentifier = NEWID();
    DECLARE @SourceTable sysname;
    DECLARE @SourceSchema sysname;
    DECLARE @TargetTable nvarchar(100);
    DECLARE @QualifiedSource nvarchar(300);
    DECLARE @MonthStart date;
    DECLARE @MonthEnd date;
    DECLARE @BaseInterestRate decimal(8,2);
    DECLARE @InterestEffectiveDate date;
    DECLARE @UsedFallback bit = 0;
    DECLARE @RowsRead int = 0;
    DECLARE @RowsRejected int = 0;
    DECLARE @RowsLoaded int = 0;
    DECLARE @Sql nvarchar(max);
    DECLARE @ProfileName sysname;
    DECLARE @Recipients nvarchar(500);
    DECLARE @Subject nvarchar(255);
    DECLARE @Body nvarchar(max);
    DECLARE @Succeeded bit = 0;
    DECLARE @ErrorMessage nvarchar(4000);
    DECLARE @MailError nvarchar(4000);
    DECLARE @ThrowMessage nvarchar(2048);

    BEGIN TRY
        -- Jobbet anropar proceduren utan parameter. FORMAT ger yyyyMM.
        IF @YearMonth IS NULL
            SET @YearMonth = CONVERT(char(6), FORMAT(GETUTCDATE(), 'yyyyMM'));

        IF @YearMonth NOT LIKE '[0-9][0-9][0-9][0-9][0-9][0-9]'
            THROW 50001, N'YearMonth must be six digits in the form YYYYMM.', 1;

        SET @MonthStart = DATEFROMPARTS(CONVERT(int, LEFT(@YearMonth, 4)), CONVERT(int, RIGHT(@YearMonth, 2)), 1);
        SET @MonthEnd = EOMONTH(@MonthStart);
        SET @SourceTable = N'CarInformation_' + @YearMonth;
        SET @TargetTable = N'LoanProfitEstimates_' + @YearMonth;

        INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
        VALUES (@RunID, N'INFO', N'Start',
                N'ETL started for ' + @SourceTable + N'. Output table ' + @TargetTable + N'.');

        SELECT TOP (1) @SourceSchema = s.name
        FROM sys.tables AS t
        INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.name = @SourceTable
        ORDER BY CASE WHEN s.name = N'dbo' THEN 0 ELSE 1 END, s.name;

        IF @SourceSchema IS NULL
        BEGIN
            SET @ErrorMessage = N'CarInformation_' + @YearMonth + N' table for the current month not found.';
            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (@RunID, N'ERROR', N'Source', @ErrorMessage);
            THROW 50002, @ErrorMessage, 1;
        END;

        SET @QualifiedSource = QUOTENAME(@SourceSchema) + N'.' + QUOTENAME(@SourceTable);

        SELECT TOP (1)
            @BaseInterestRate = r.BaseInterestRate,
            @InterestEffectiveDate = r.EffectiveDate
        FROM dbo.InterestRates AS r
        WHERE r.EffectiveDate >= @MonthStart
          AND r.EffectiveDate <= @MonthEnd
        ORDER BY r.EffectiveDate DESC;

        IF @BaseInterestRate IS NULL
        BEGIN
            SELECT TOP (1)
                @BaseInterestRate = r.BaseInterestRate,
                @InterestEffectiveDate = r.EffectiveDate
            FROM dbo.InterestRates AS r
            WHERE r.EffectiveDate < @MonthStart
            ORDER BY r.EffectiveDate DESC;

            IF @BaseInterestRate IS NULL
            BEGIN
                SET @ErrorMessage = N'No base interest rate is available for the current month or any earlier month.';
                INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
                VALUES (@RunID, N'ERROR', N'InterestRate', @ErrorMessage);
                THROW 50003, @ErrorMessage, 1;
            END;

            SET @UsedFallback = 1;
            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (
                @RunID, N'WARNING', N'InterestRate',
                N'Base interest rate for the current month is missing. Value from the previous month was used.'
            );
        END;

        TRUNCATE TABLE dbo.CarInformation_Staging;

        -- Bara tabellnamnet är dynamiskt. Värdena läses set-baserat.
        SET @Sql = N'
            INSERT INTO dbo.CarInformation_Staging (
                RecordID, CarModel, EnergyClassRaw, ManufactureYear,
                BasePrice, FileMonth, CustomerRiskTier
            )
            SELECT
                TRY_CONVERT(int, src.RecordID),
                NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100), src.CarModel))), N''''),
                NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(50), src.EnergyClass))), N''''),
                TRY_CONVERT(int, src.ManufactureYear),
                COALESCE(
                    TRY_CONVERT(decimal(18,2), src.BasePrice),
                    TRY_CONVERT(decimal(18,2), REPLACE(REPLACE(CONVERT(nvarchar(40), src.BasePrice), N'' '', N''''), N'','', N''.''))
                ),
                TRY_CONVERT(date, src.FileMonth),
                NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(20), src.CustomerRiskTier))), N'''')
            FROM ' + @QualifiedSource + N' AS src;';

        EXEC sys.sp_executesql @Sql;
        SET @RowsRead = @@ROWCOUNT;

        UPDATE dbo.CarInformation_Staging
        SET VehicleAge = YEAR(@MonthStart) - ManufactureYear
        WHERE ManufactureYear IS NOT NULL;

        UPDATE s
        SET EnergyClass = COALESCE(directMatch.EnergyClass, synonymMatch.EnergyClass)
        FROM dbo.CarInformation_Staging AS s
        OUTER APPLY (
            SELECT TOP (1) m.EnergyClass
            FROM dbo.EnergyClassMargin AS m
            WHERE LOWER(LTRIM(RTRIM(m.EnergyClass))) = LOWER(s.EnergyClassRaw)
        ) AS directMatch
        OUTER APPLY (
            SELECT TOP (1) m.EnergyClass
            FROM dbo.EnergyClassSynonym AS y
            INNER JOIN dbo.EnergyClassMargin AS m
                ON LOWER(LTRIM(RTRIM(m.EnergyClass))) = LOWER(y.EnergyClass)
            WHERE LOWER(y.RawValue) = LOWER(s.EnergyClassRaw)
        ) AS synonymMatch;

        ;WITH DuplicateIds AS (
            SELECT RecordID
            FROM dbo.CarInformation_Staging
            WHERE RecordID IS NOT NULL
            GROUP BY RecordID
            HAVING COUNT(*) > 1
        )
        UPDATE s
        SET RejectReason = NULLIF(CONCAT_WS(
                N'; ',
                CASE WHEN s.RecordID IS NULL THEN N'RecordID is missing or not an integer' END,
                CASE WHEN d.RecordID IS NOT NULL THEN N'Duplicate RecordID' END,
                CASE WHEN s.BasePrice IS NULL OR s.BasePrice < 0 THEN N'BasePrice is missing or negative' END,
                CASE WHEN s.ManufactureYear IS NULL THEN N'ManufactureYear is missing or not an integer' END,
                CASE WHEN s.EnergyClass IS NULL THEN N'EnergyClass is missing or not in EnergyClassMargin' END,
                CASE WHEN risk.RiskTier IS NULL THEN N'CustomerRiskTier is missing or not in CreditRiskTier' END,
                CASE
                    WHEN s.VehicleAge > 0 AND dep.DepreciationRate IS NULL
                    THEN N'No depreciation band matches the vehicle age'
                END
            ), N'')
        FROM dbo.CarInformation_Staging AS s
        LEFT JOIN DuplicateIds AS d ON d.RecordID = s.RecordID
        OUTER APPLY (
            SELECT TOP (1) c.RiskTier
            FROM dbo.CreditRiskTier AS c
            WHERE LOWER(LTRIM(RTRIM(c.RiskTier))) = LOWER(s.CustomerRiskTier)
        ) AS risk
        OUTER APPLY (
            SELECT TOP (1) r.DepreciationRate
            FROM dbo.DepreciationRates AS r
            WHERE s.VehicleAge BETWEEN r.MinYear AND r.MaxYear
            ORDER BY r.MinYear
        ) AS dep;

        UPDATE dbo.CarInformation_Staging
        SET IsValid = CASE WHEN RejectReason IS NULL THEN 1 ELSE 0 END;

        INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message, RowsAffected)
        SELECT @RunID, N'WARNING', N'Validate',
               N'Rejected ' + CONVERT(nvarchar(20), COUNT(*)) + N' rows: ' + RejectReason,
               COUNT(*)
        FROM dbo.CarInformation_Staging
        WHERE IsValid = 0
        GROUP BY RejectReason;

        SELECT @RowsRejected = COUNT(*)
        FROM dbo.CarInformation_Staging
        WHERE IsValid = 0;

        BEGIN TRANSACTION;

        SET @Sql = N'DROP TABLE IF EXISTS dbo.' + QUOTENAME(@TargetTable) + N';
            CREATE TABLE dbo.' + QUOTENAME(@TargetTable) + N' (
                RecordID                  int            NOT NULL PRIMARY KEY,
                CarModel                  nvarchar(100)  NULL,
                EnergyClass               nvarchar(20)   NOT NULL,
                ManufactureYear           int            NOT NULL,
                BasePrice                 decimal(18,2)  NOT NULL,
                CustomerRiskTier          nvarchar(20)   NOT NULL,
                FinalInterestRate         decimal(8,2)   NOT NULL,
                EstimatedMonthlyPayment   decimal(18,4)  NOT NULL,
                DepreciatedValue          decimal(18,2)  NOT NULL,
                EstimatedProfit           decimal(18,2)  NOT NULL,
                DataMonth                 date           NOT NULL,
                BaseInterestRate          decimal(8,2)   NOT NULL,
                EffectiveRateDate         date           NOT NULL,
                VehicleAge                int            NOT NULL,
                DepreciationRate          decimal(8,2)   NOT NULL,
                PreviousDepreciationRate  decimal(8,2)   NOT NULL,
                DepreciationThisYear      decimal(18,2)  NOT NULL,
                MarginRate                decimal(8,2)   NOT NULL,
                RiskAdjustment            decimal(8,2)   NOT NULL
            );';
        EXEC sys.sp_executesql @Sql;

        SET @Sql = N'
            INSERT INTO dbo.' + QUOTENAME(@TargetTable) + N' (
                RecordID, CarModel, EnergyClass, ManufactureYear, BasePrice, CustomerRiskTier,
                FinalInterestRate, EstimatedMonthlyPayment, DepreciatedValue, EstimatedProfit,
                DataMonth, BaseInterestRate, EffectiveRateDate, VehicleAge, DepreciationRate,
                PreviousDepreciationRate, DepreciationThisYear, MarginRate, RiskAdjustment
            )
            SELECT
                s.RecordID,
                s.CarModel,
                s.EnergyClass,
                s.ManufactureYear,
                s.BasePrice,
                risk.RiskTier,
                calc.FinalInterestRate,
                calc.EstimatedMonthlyPayment,
                calc.DepreciatedValue,
                calc.EstimatedProfit,
                @MonthStart,
                @BaseInterestRate,
                @InterestEffectiveDate,
                calc.VehicleAge,
                calc.DepreciationRate,
                calc.PreviousDepreciationRate,
                calc.DepreciationThisYear,
                margin.MarginRate,
                risk.RiskAdjustment
            FROM dbo.CarInformation_Staging AS s
            INNER JOIN dbo.EnergyClassMargin AS margin
                ON LOWER(LTRIM(RTRIM(margin.EnergyClass))) = LOWER(s.EnergyClass)
            INNER JOIN dbo.CreditRiskTier AS risk
                ON LOWER(LTRIM(RTRIM(risk.RiskTier))) = LOWER(s.CustomerRiskTier)
            OUTER APPLY (
                SELECT TOP (1) d.DepreciationRate
                FROM dbo.DepreciationRates AS d
                WHERE s.VehicleAge BETWEEN d.MinYear AND d.MaxYear
                ORDER BY d.MinYear
            ) AS curDep
            OUTER APPLY (
                SELECT TOP (1) d.DepreciationRate
                FROM dbo.DepreciationRates AS d
                WHERE s.VehicleAge - 1 BETWEEN d.MinYear AND d.MaxYear
                ORDER BY d.MinYear
            ) AS prevDep
            CROSS APPLY (
                SELECT
                    s.VehicleAge,
                    DepreciationRate = CASE
                        WHEN s.VehicleAge <= 0 THEN CAST(0 AS decimal(8,2))
                        ELSE curDep.DepreciationRate
                    END,
                    PreviousDepreciationRate = CASE
                        WHEN s.VehicleAge - 1 <= 0 THEN CAST(0 AS decimal(8,2))
                        ELSE prevDep.DepreciationRate
                    END,
                    FinalInterestRate = CAST(@BaseInterestRate + margin.MarginRate + risk.RiskAdjustment AS decimal(8,2))
            ) AS rates
            CROSS APPLY (
                SELECT
                    rates.VehicleAge,
                    rates.DepreciationRate,
                    rates.PreviousDepreciationRate,
                    rates.FinalInterestRate,
                    DepreciatedValue = CAST(ROUND(s.BasePrice * (1 - rates.DepreciationRate), 2) AS decimal(18,2)),
                    DepreciationThisYear = CAST(ROUND(s.BasePrice * (rates.DepreciationRate - rates.PreviousDepreciationRate), 2) AS decimal(18,2)),
                    EstimatedMonthlyPayment = CAST(ROUND(s.BasePrice * rates.FinalInterestRate / 100.0 / 12.0, 4) AS decimal(18,4)),
                    EstimatedProfit = CAST(
                        ROUND(s.BasePrice * rates.FinalInterestRate / 100.0, 2)
                        - ROUND(s.BasePrice * (rates.DepreciationRate - rates.PreviousDepreciationRate), 2)
                        AS decimal(18,2))
            ) AS calc
            WHERE s.IsValid = 1;';

        EXEC sys.sp_executesql
            @Sql,
            N'@MonthStart date, @BaseInterestRate decimal(8,2), @InterestEffectiveDate date',
            @MonthStart = @MonthStart,
            @BaseInterestRate = @BaseInterestRate,
            @InterestEffectiveDate = @InterestEffectiveDate;

        SET @RowsLoaded = @@ROWCOUNT;
        COMMIT TRANSACTION;
        SET @Succeeded = 1;

        INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message, RowsAffected)
        VALUES (
            @RunID, N'INFO', N'Load',
            N'Loaded ' + CONVERT(nvarchar(20), @RowsLoaded) + N' rows into dbo.' + @TargetTable
                + N'. Read ' + CONVERT(nvarchar(20), @RowsRead)
                + N', rejected ' + CONVERT(nvarchar(20), @RowsRejected) + N'.',
            @RowsLoaded
        );
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @Succeeded = 0;
        IF @ErrorMessage IS NULL
            SET @ErrorMessage = ERROR_MESSAGE();

        IF ERROR_NUMBER() NOT IN (50002, 50003)
        BEGIN
            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (@RunID, N'ERROR', N'Failed', @ErrorMessage);
        END;
    END CATCH;

    SELECT @ProfileName = ProfileName, @Recipients = Recipients
    FROM dbo.ETL_MailConfig
    WHERE ConfigID = 1;

    SET @Subject = CASE
        WHEN @Succeeded = 1
        THEN N'Loan profit ETL succeeded - ' + ISNULL(@TargetTable, N'(no output table)')
        ELSE N'Loan profit ETL failed - ' + ISNULL(@TargetTable, N'(no output table)')
    END;

    SET @Body =
        N'The ETL job ' + CASE WHEN @Succeeded = 1 THEN N'completed successfully.' ELSE N'failed.' END
        + NCHAR(13) + NCHAR(10) + NCHAR(13) + NCHAR(10)
        + N'Output table: dbo.' + ISNULL(@TargetTable, N'(not created)') + NCHAR(13) + NCHAR(10)
        + N'Rows processed: ' + CONVERT(nvarchar(20), @RowsLoaded) + NCHAR(13) + NCHAR(10)
        + N'Rows read: ' + CONVERT(nvarchar(20), @RowsRead) + NCHAR(13) + NCHAR(10)
        + N'Rows rejected: ' + CONVERT(nvarchar(20), @RowsRejected) + NCHAR(13) + NCHAR(10)
        + N'Base interest rate: ' + COALESCE(CONVERT(nvarchar(20), @BaseInterestRate), N'(none)')
        + CASE
            WHEN @InterestEffectiveDate IS NULL THEN N''
            ELSE N' effective ' + CONVERT(char(10), @InterestEffectiveDate, 23)
          END
        + NCHAR(13) + NCHAR(10)
        + N'Fallback rate used: ' + CASE WHEN @UsedFallback = 1 THEN N'Yes' ELSE N'No' END
        + NCHAR(13) + NCHAR(10)
        + N'Database: ' + DB_NAME();

    -- VG kräver anropet. Det är godkänt att mejlet inte kommer fram
    -- om Database Mail-profilen saknas på servern.
    IF @ProfileName IS NULL OR @Recipients IS NULL
    BEGIN
        INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
        VALUES (@RunID, N'ERROR', N'Email',
                N'Confirmation email could not be sent. dbo.ETL_MailConfig has no profile or recipient. ' + @Body);
    END
    ELSE
    BEGIN
        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = @ProfileName,
                @recipients = @Recipients,
                @subject = @Subject,
                @body = @Body;

            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (@RunID, N'INFO', N'Email', N'Confirmation email sent to ' + @Recipients + N'. ' + @Body);
        END TRY
        BEGIN CATCH
            SET @MailError = ERROR_MESSAGE();
            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (@RunID, N'ERROR', N'Email',
                    N'Confirmation email could not be sent. ' + @MailError + N' ' + @Body);
        END CATCH;
    END;

    IF @Succeeded = 0
    BEGIN
        SET @ThrowMessage = LEFT(ISNULL(@ErrorMessage, N'ETL failed.'), 2047);
        THROW 50000, @ThrowMessage, 1;
    END;
END;
GO

-- =============================================================================
-- 3. Ditt SQL Agent-jobb:
-- =============================================================================

SET NOCOUNT ON;

DECLARE @JobName sysname = N'ETL_LoanProfitEstimates';
DECLARE @ScheduleName sysname = N'Monthly_LoanProfitEstimates';
DECLARE @DatabaseName sysname = DB_NAME();
DECLARE @Owner sysname = SUSER_SNAME();

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = @JobName,
        @delete_unused_schedule = 1;
END;

EXEC msdb.dbo.sp_add_job
    @job_name = @JobName,
    @enabled = 1,
    @description = N'Månadsvis ETL. Läser CarInformation_yyyymm för UTC-månaden och skriver LoanProfitEstimates_yyyymm. Skickar bekräftelsemejl med antal rader och tabellnamn.',
    @owner_login_name = @Owner,
    @notify_level_eventlog = 2;

EXEC msdb.dbo.sp_add_jobstep
    @job_name = @JobName,
    @step_name = N'Load LoanProfitEstimates',
    @step_id = 1,
    @subsystem = N'TSQL',
    @database_name = @DatabaseName,
    @command = N'EXEC dbo.usp_LoadLoanProfitEstimates;',
    @on_success_action = 1,
    @on_fail_action = 2;

EXEC msdb.dbo.sp_update_job
    @job_name = @JobName,
    @start_step_id = 1;

EXEC msdb.dbo.sp_add_schedule
    @schedule_name = @ScheduleName,
    @enabled = 1,
    @freq_type = 16,
    @freq_interval = 1,
    @freq_recurrence_factor = 1,
    @active_start_date = 20261101,
    @active_start_time = 070000;

EXEC msdb.dbo.sp_attach_schedule
    @job_name = @JobName,
    @schedule_name = @ScheduleName;

EXEC msdb.dbo.sp_add_jobserver
    @job_name = @JobName,
    @server_name = N'(LOCAL)';
GO
