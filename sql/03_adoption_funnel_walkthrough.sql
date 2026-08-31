-- =============================================================================
-- 03_adoption_funnel_walkthrough.sql
-- CRM Adoption Analytics -- executable SQL walkthrough
--
-- Run this after 01_schema.sql and 02_seed_data.sql have been loaded. Every
-- step below is a standalone, runnable SELECT -- run them one at a time to
-- see the funnel build up, or run the whole file to get every result set
-- back to back.
--
-- Reporting window used throughout: the 10 synthetic weeks in the sample
-- data, 2026-05-04 through 2026-07-12. Change REPORT_START / REPORT_END
-- below (and re-run) to look at a different slice once you plug in your own
-- data.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- STEP 0: Parameters
-- SQLite has no session variables, so the window is expressed as a small
-- CTE that every downstream query joins against. In Postgres/SQL Server
-- you'd typically do the same thing with a CTE, or swap in real variables.
-- -----------------------------------------------------------------------------

-- (for reference only -- inlined as a CTE in every query below)
-- REPORT_START = '2026-05-04'
-- REPORT_END   = '2026-07-12'
-- REGULARITY_THRESHOLD = the share of weeks in the window an employee must
--                         have at least one qualifying event in, to count
--                         as a "regular" user of that behavior (0.75 below,
--                         i.e. active in at least 3 of every 4 weeks)


-- -----------------------------------------------------------------------------
-- STEP 1: Eligible population
-- Who counts as "should be using the CRM" this period? Resolved from the
-- weekly eligibility snapshot, not from today's headcount -- someone who
-- left mid-window still counts for the weeks they were actually eligible.
-- -----------------------------------------------------------------------------

WITH report_window AS (
    SELECT '2026-05-04' AS report_start, '2026-07-12' AS report_end
),
eligible_employees AS (
    SELECT DISTINCT f.employee_key
    FROM fact_employee_eligibility_weekly f
    JOIN dim_date d           ON d.date_key = f.week_end_date_key
    JOIN report_window rw     ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
    WHERE f.is_eligible = 1
)
SELECT COUNT(*) AS eligible_population
FROM eligible_employees;


-- -----------------------------------------------------------------------------
-- STEP 2: Eligible population by office / region
-- Same population, sliced by org unit -- this is the grain most of the
-- funnel will eventually be reported at.
-- -----------------------------------------------------------------------------

WITH report_window AS (
    SELECT '2026-05-04' AS report_start, '2026-07-12' AS report_end
),
eligible_employees AS (
    SELECT DISTINCT f.employee_key
    FROM fact_employee_eligibility_weekly f
    JOIN dim_date d           ON d.date_key = f.week_end_date_key
    JOIN report_window rw     ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
    WHERE f.is_eligible = 1
)
SELECT
    o.region,
    o.office_name,
    COUNT(*) AS eligible_population
FROM eligible_employees e
JOIN dim_employee emp ON emp.employee_key = e.employee_key
JOIN dim_org_unit o   ON o.org_unit_key = emp.org_unit_key
GROUP BY o.region, o.office_name
ORDER BY o.region, o.office_name;


-- -----------------------------------------------------------------------------
-- STEP 3: Unified event log
-- Five different fact tables all answer the same underlying question --
-- "did this employee do a CRM-tracked thing on this date?" -- so rather
-- than writing five near-identical regularity queries, normalize them into
-- one tagged event stream once and reuse it for every funnel stage below.
-- -----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_employee_events;
CREATE VIEW v_employee_events AS
SELECT employee_key, login_date_key AS event_date_key, 'login' AS event_type
FROM fact_logins

UNION ALL

SELECT employee_key, view_date_key, 'lead_view'
FROM fact_lead_views

UNION ALL

SELECT owner_employee_key, created_date_key, 'opportunity_created'
FROM fact_opportunities
WHERE source_lead_key IS NOT NULL   -- only opportunities converted from a reviewed lead count toward "conversion" adoption

UNION ALL

SELECT rep_employee_key, quote_date_key, 'quote_created'
FROM fact_quotes

UNION ALL

SELECT employee_key, activity_date_key, 'activity_logged'
FROM fact_activities;


-- Sanity check: row counts per event type
SELECT event_type, COUNT(*) AS event_row_count
FROM v_employee_events
GROUP BY event_type
ORDER BY event_type;


-- -----------------------------------------------------------------------------
-- STEP 4: Coverage -- "did they do it at all this period?"
-- For each event type, the share of eligible employees with at least one
-- occurrence anywhere in the reporting window. This is the loosest bar in
-- the funnel (any single occurrence counts).
-- -----------------------------------------------------------------------------

WITH report_window AS (
    SELECT '2026-05-04' AS report_start, '2026-07-12' AS report_end
),
eligible_employees AS (
    SELECT DISTINCT f.employee_key
    FROM fact_employee_eligibility_weekly f
    JOIN dim_date d       ON d.date_key = f.week_end_date_key
    JOIN report_window rw ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
    WHERE f.is_eligible = 1
),
events_in_window AS (
    SELECT ev.employee_key, ev.event_type
    FROM v_employee_events ev
    JOIN dim_date d        ON d.date_key = ev.event_date_key
    JOIN report_window rw  ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
),
coverage AS (
    SELECT
        ev.event_type,
        COUNT(DISTINCT ev.employee_key) AS employees_with_event
    FROM events_in_window ev
    JOIN eligible_employees e ON e.employee_key = ev.employee_key
    GROUP BY ev.event_type
)
SELECT
    c.event_type,
    c.employees_with_event,
    (SELECT COUNT(*) FROM eligible_employees) AS eligible_population,
    ROUND(100.0 * c.employees_with_event / (SELECT COUNT(*) FROM eligible_employees), 1) AS coverage_pct
FROM coverage c
ORDER BY coverage_pct DESC;


-- -----------------------------------------------------------------------------
-- STEP 5: Regularity -- "do they do it most weeks, not just once?"
-- A stricter bar than coverage: the employee needs a qualifying event in at
-- least REGULARITY_THRESHOLD (75%) of the weeks in the window. This is what
-- turns "used it once in ten weeks" from counting the same as "uses it
-- every week" -- the two look identical under plain coverage.
-- -----------------------------------------------------------------------------

WITH report_window AS (
    SELECT '2026-05-04' AS report_start, '2026-07-12' AS report_end
),
window_weeks AS (
    SELECT DISTINCT d.week_end_date
    FROM dim_date d
    JOIN report_window rw ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
),
required_weeks AS (
    SELECT CAST(ROUND(0.75 * (SELECT COUNT(*) FROM window_weeks)) AS INTEGER) AS n
),
eligible_employees AS (
    SELECT DISTINCT f.employee_key
    FROM fact_employee_eligibility_weekly f
    JOIN dim_date d       ON d.date_key = f.week_end_date_key
    JOIN report_window rw ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
    WHERE f.is_eligible = 1
),
employee_event_weeks AS (
    -- distinct (employee, event_type, week) triples -- one row per week an
    -- employee had *any* qualifying event of that type
    SELECT DISTINCT
        ev.employee_key,
        ev.event_type,
        d.week_end_date
    FROM v_employee_events ev
    JOIN dim_date d ON d.date_key = ev.event_date_key
    JOIN report_window rw ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
),
weeks_active_per_employee AS (
    SELECT employee_key, event_type, COUNT(*) AS weeks_active
    FROM employee_event_weeks
    GROUP BY employee_key, event_type
),
regular_users AS (
    SELECT w.event_type, COUNT(DISTINCT w.employee_key) AS regular_employee_count
    FROM weeks_active_per_employee w
    JOIN eligible_employees e ON e.employee_key = w.employee_key
    WHERE w.weeks_active >= (SELECT n FROM required_weeks)
    GROUP BY w.event_type
)
SELECT
    r.event_type,
    r.regular_employee_count,
    (SELECT COUNT(*) FROM eligible_employees) AS eligible_population,
    (SELECT n FROM required_weeks) AS weeks_required_of_10,
    ROUND(100.0 * r.regular_employee_count / (SELECT COUNT(*) FROM eligible_employees), 1) AS regular_user_pct
FROM regular_users r
ORDER BY regular_user_pct DESC;


-- -----------------------------------------------------------------------------
-- STEP 6: The funnel, by office
-- Same regularity metric as Step 5, but cut by org unit -- this is the
-- shape a real adoption dashboard would show: overall numbers are useful,
-- but "which offices are lagging" is the actionable version.
-- -----------------------------------------------------------------------------

WITH report_window AS (
    SELECT '2026-05-04' AS report_start, '2026-07-12' AS report_end
),
window_weeks AS (
    SELECT DISTINCT d.week_end_date
    FROM dim_date d
    JOIN report_window rw ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
),
required_weeks AS (
    SELECT CAST(ROUND(0.75 * (SELECT COUNT(*) FROM window_weeks)) AS INTEGER) AS n
),
eligible_employees AS (
    SELECT DISTINCT f.employee_key
    FROM fact_employee_eligibility_weekly f
    JOIN dim_date d       ON d.date_key = f.week_end_date_key
    JOIN report_window rw ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
    WHERE f.is_eligible = 1
),
employee_event_weeks AS (
    SELECT DISTINCT
        ev.employee_key,
        ev.event_type,
        d.week_end_date
    FROM v_employee_events ev
    JOIN dim_date d ON d.date_key = ev.event_date_key
    JOIN report_window rw ON d.calendar_date BETWEEN rw.report_start AND rw.report_end
    WHERE ev.event_type = 'activity_logged'
),
weeks_active_per_employee AS (
    SELECT employee_key, COUNT(*) AS weeks_active
    FROM employee_event_weeks
    GROUP BY employee_key
),
eligible_by_office AS (
    SELECT o.region, o.office_name, e.employee_key
    FROM eligible_employees e
    JOIN dim_employee emp ON emp.employee_key = e.employee_key
    JOIN dim_org_unit o   ON o.org_unit_key = emp.org_unit_key
)
SELECT
    eo.region,
    eo.office_name,
    COUNT(DISTINCT eo.employee_key) AS eligible_population,
    COUNT(DISTINCT CASE WHEN w.weeks_active >= (SELECT n FROM required_weeks) THEN eo.employee_key END) AS regular_activity_loggers,
    ROUND(
        100.0 * COUNT(DISTINCT CASE WHEN w.weeks_active >= (SELECT n FROM required_weeks) THEN eo.employee_key END)
        / COUNT(DISTINCT eo.employee_key), 1
    ) AS regular_activity_logger_pct
FROM eligible_by_office eo
LEFT JOIN weeks_active_per_employee w ON w.employee_key = eo.employee_key
GROUP BY eo.region, eo.office_name
ORDER BY regular_activity_logger_pct DESC;


-- -----------------------------------------------------------------------------
-- STEP 7: Trend over time
-- Weekly login-regularity rate using a trailing window, computed with a
-- window function -- this is the kind of series a line chart on a
-- dashboard would be built from.
-- -----------------------------------------------------------------------------

WITH weekly_logins AS (
    SELECT DISTINCT
        f.employee_key,
        d.week_end_date
    FROM fact_logins f
    JOIN dim_date d ON d.date_key = f.login_date_key
),
weekly_eligible AS (
    SELECT
        d.week_end_date,
        f.employee_key
    FROM fact_employee_eligibility_weekly f
    JOIN dim_date d ON d.date_key = f.week_end_date_key
    WHERE f.is_eligible = 1
),
weekly_rate AS (
    SELECT
        we.week_end_date,
        COUNT(DISTINCT we.employee_key) AS eligible_population,
        COUNT(DISTINCT wl.employee_key) AS employees_logged_in,
        ROUND(100.0 * COUNT(DISTINCT wl.employee_key) / COUNT(DISTINCT we.employee_key), 1) AS weekly_login_pct
    FROM weekly_eligible we
    LEFT JOIN weekly_logins wl
        ON wl.employee_key = we.employee_key AND wl.week_end_date = we.week_end_date
    GROUP BY we.week_end_date
)
SELECT
    week_end_date,
    eligible_population,
    employees_logged_in,
    weekly_login_pct,
    ROUND(AVG(weekly_login_pct) OVER (
        ORDER BY week_end_date
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
    ), 1) AS trailing_4wk_avg_login_pct
FROM weekly_rate
ORDER BY week_end_date;
