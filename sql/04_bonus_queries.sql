-- =============================================================================
-- 04_bonus_queries.sql
-- A few extra queries that aren't part of the core funnel but show off
-- other angles on the same star schema. Independent of each other -- run
-- any one on its own.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A) Pipeline value by opportunity type and source
-- Are opportunities created directly by reps worth more or less, on
-- average, than ones converted from a reviewed lead?
-- -----------------------------------------------------------------------------

SELECT
    ot.opportunity_type_name,
    CASE WHEN o.source_lead_key IS NULL THEN 'Created directly' ELSE 'Converted from lead' END AS origin,
    COUNT(*) AS opportunity_count,
    ROUND(AVG(o.opportunity_value), 2) AS avg_opportunity_value,
    ROUND(SUM(o.opportunity_value), 2) AS total_opportunity_value
FROM fact_opportunities o
JOIN dim_opportunity_type ot ON ot.opportunity_type_key = o.opportunity_type_key
GROUP BY ot.opportunity_type_name, origin
ORDER BY ot.opportunity_type_name, origin;


-- -----------------------------------------------------------------------------
-- B) Rep-level leaderboard: activity volume vs. quote-winning
-- A window-function ranking, not just a top-N -- keeps every rep's rank
-- visible even if you later filter down to one office.
-- -----------------------------------------------------------------------------

WITH rep_activity AS (
    SELECT employee_key, COUNT(*) AS activities_logged
    FROM fact_activities
    GROUP BY employee_key
),
rep_quotes AS (
    SELECT rep_employee_key AS employee_key, COUNT(*) AS quotes_created, ROUND(SUM(quote_amount), 2) AS quote_value
    FROM fact_quotes
    GROUP BY rep_employee_key
)
SELECT
    e.display_name,
    o.office_name,
    COALESCE(ra.activities_logged, 0) AS activities_logged,
    COALESCE(rq.quotes_created, 0) AS quotes_created,
    COALESCE(rq.quote_value, 0) AS quote_value,
    RANK() OVER (ORDER BY COALESCE(ra.activities_logged, 0) DESC) AS activity_rank,
    RANK() OVER (ORDER BY COALESCE(rq.quote_value, 0) DESC) AS quote_value_rank
FROM dim_employee e
JOIN dim_org_unit o ON o.org_unit_key = e.org_unit_key
LEFT JOIN rep_activity ra ON ra.employee_key = e.employee_key
LEFT JOIN rep_quotes rq   ON rq.employee_key = e.employee_key
WHERE e.job_family IN (SELECT job_family FROM ref_eligible_job_families)
ORDER BY activity_rank;


-- -----------------------------------------------------------------------------
-- C) Tenure cohort view: does adoption differ by how long someone's been
-- with the company? Buckets hire_date into cohorts and compares login
-- coverage across them.
-- -----------------------------------------------------------------------------

WITH report_window AS (
    SELECT '2026-05-04' AS report_start, '2026-07-12' AS report_end
),
tenure_cohort AS (
    SELECT
        e.employee_key,
        CASE
            WHEN CAST((julianday(rw.report_start) - julianday(e.hire_date)) AS INTEGER) < 180 THEN 'Under 6 months'
            WHEN CAST((julianday(rw.report_start) - julianday(e.hire_date)) AS INTEGER) < 365 THEN '6-12 months'
            ELSE 'Over 1 year'
        END AS tenure_bucket
    FROM dim_employee e
    CROSS JOIN report_window rw
    WHERE e.job_family IN (SELECT job_family FROM ref_eligible_job_families)
),
logged_in_employees AS (
    SELECT DISTINCT f.employee_key
    FROM fact_logins f
    JOIN dim_date d ON d.date_key = f.login_date_key
    JOIN report_window rw ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
)
SELECT
    tc.tenure_bucket,
    COUNT(DISTINCT tc.employee_key) AS eligible_employees,
    COUNT(DISTINCT li.employee_key) AS logged_in_employees,
    ROUND(100.0 * COUNT(DISTINCT li.employee_key) / COUNT(DISTINCT tc.employee_key), 1) AS login_coverage_pct
FROM tenure_cohort tc
LEFT JOIN logged_in_employees li ON li.employee_key = tc.employee_key
GROUP BY tc.tenure_bucket
ORDER BY
    CASE tc.tenure_bucket
        WHEN 'Under 6 months' THEN 1
        WHEN '6-12 months' THEN 2
        ELSE 3
    END;
