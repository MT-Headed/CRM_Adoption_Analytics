-- =============================================================================
-- 01_schema.sql
-- CRM Adoption Analytics -- star schema DDL
--
-- Written against SQLite (works unmodified with the sqlite3 CLI or Python's
-- built-in sqlite3 module). Portable to Postgres/SQL Server/DuckDB with only
-- trivial changes (AUTOINCREMENT -> IDENTITY/SERIAL, TEXT dates -> DATE).
-- =============================================================================

PRAGMA foreign_keys = ON;

-- -----------------------------------------------------------------------------
-- Dimension tables
-- -----------------------------------------------------------------------------

CREATE TABLE dim_date (
    date_key            INTEGER PRIMARY KEY,   -- YYYYMMDD
    calendar_date       TEXT NOT NULL,         -- ISO 8601
    week_start_date     TEXT NOT NULL,         -- Monday of that week
    week_end_date       TEXT NOT NULL,         -- Sunday of that week
    month_number        INTEGER NOT NULL,
    month_name          TEXT NOT NULL,
    quarter_number      INTEGER NOT NULL,
    year_number         INTEGER NOT NULL,
    is_business_day     INTEGER NOT NULL       -- 1 = Mon-Fri, 0 = weekend
);

CREATE TABLE dim_org_unit (
    org_unit_key        INTEGER PRIMARY KEY,
    region              TEXT NOT NULL,
    territory           TEXT NOT NULL,
    office_name         TEXT NOT NULL
);

CREATE TABLE dim_employee (
    employee_key        INTEGER PRIMARY KEY,
    employee_code       TEXT NOT NULL UNIQUE,
    display_name        TEXT NOT NULL,
    job_family          TEXT NOT NULL,         -- Outside Sales / Inside Sales / Sales Support / Sales Leadership
    org_unit_key        INTEGER NOT NULL REFERENCES dim_org_unit(org_unit_key),
    hire_date           TEXT NOT NULL,
    termination_date    TEXT,                  -- NULL while still employed
    is_crm_licensed     INTEGER NOT NULL DEFAULT 1  -- holds CRM login credentials
);

CREATE TABLE dim_activity_type (
    activity_type_key   INTEGER PRIMARY KEY,
    activity_type_name  TEXT NOT NULL,
    category            TEXT NOT NULL
);

CREATE TABLE dim_opportunity_type (
    opportunity_type_key   INTEGER PRIMARY KEY,
    opportunity_type_name  TEXT NOT NULL
);

-- Reference list of job families counted toward the adoption funnel.
-- Kept as a table (not hardcoded in queries) so eligibility rules are
-- data-driven and auditable, mirroring how this would live in a real
-- warehouse as a governed reference table.
CREATE TABLE ref_eligible_job_families (
    job_family          TEXT PRIMARY KEY
);
INSERT INTO ref_eligible_job_families (job_family) VALUES
    ('Outside Sales'), ('Inside Sales'), ('Sales Support');

-- -----------------------------------------------------------------------------
-- Fact tables
-- -----------------------------------------------------------------------------

-- Weekly point-in-time snapshot of who counted as an eligible CRM user.
-- This is the single source of truth for "how many people should be using
-- the CRM this week" -- every adoption rate in the walkthrough divides by a
-- count derived from this table, not from today's current headcount, so
-- historical weeks stay accurate even after someone is later terminated or
-- changes job family.
CREATE TABLE fact_employee_eligibility_weekly (
    employee_key         INTEGER NOT NULL REFERENCES dim_employee(employee_key),
    week_end_date_key    INTEGER NOT NULL REFERENCES dim_date(date_key),
    is_eligible          INTEGER NOT NULL,     -- 1/0, resolved as-of that week
    PRIMARY KEY (employee_key, week_end_date_key)
);

CREATE TABLE fact_logins (
    login_key            INTEGER PRIMARY KEY AUTOINCREMENT,
    employee_key         INTEGER NOT NULL REFERENCES dim_employee(employee_key),
    login_date_key       INTEGER NOT NULL REFERENCES dim_date(date_key)
);

-- Inbound leads. Deliberately has no employee_key -- a lead exists before
-- anyone has engaged with it, which is what fact_lead_views is for.
CREATE TABLE fact_leads (
    lead_key             INTEGER PRIMARY KEY,
    created_date_key     INTEGER NOT NULL REFERENCES dim_date(date_key),
    lead_value           REAL NOT NULL
);

CREATE TABLE fact_lead_views (
    view_key             INTEGER PRIMARY KEY AUTOINCREMENT,
    lead_key             INTEGER NOT NULL REFERENCES fact_leads(lead_key),
    employee_key         INTEGER NOT NULL REFERENCES dim_employee(employee_key),
    view_date_key        INTEGER NOT NULL REFERENCES dim_date(date_key)
);

CREATE TABLE fact_opportunities (
    opportunity_key       INTEGER PRIMARY KEY,
    owner_employee_key    INTEGER NOT NULL REFERENCES dim_employee(employee_key),
    opportunity_type_key  INTEGER NOT NULL REFERENCES dim_opportunity_type(opportunity_type_key),
    created_date_key      INTEGER NOT NULL REFERENCES dim_date(date_key),
    source_lead_key       INTEGER REFERENCES fact_leads(lead_key), -- NULL = created directly, not from a converted lead
    opportunity_value     REAL NOT NULL,
    opportunity_qty       INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE fact_quotes (
    quote_key            INTEGER PRIMARY KEY,
    opportunity_key      INTEGER NOT NULL REFERENCES fact_opportunities(opportunity_key),
    rep_employee_key     INTEGER NOT NULL REFERENCES dim_employee(employee_key),
    quote_date_key       INTEGER NOT NULL REFERENCES dim_date(date_key),
    quote_amount         REAL NOT NULL
);

CREATE TABLE fact_activities (
    activity_key          INTEGER PRIMARY KEY AUTOINCREMENT,
    employee_key          INTEGER NOT NULL REFERENCES dim_employee(employee_key),
    activity_type_key     INTEGER NOT NULL REFERENCES dim_activity_type(activity_type_key),
    opportunity_key       INTEGER REFERENCES fact_opportunities(opportunity_key), -- nullable: not every logged activity is tied to an opportunity
    activity_date_key     INTEGER NOT NULL REFERENCES dim_date(date_key),
    quantity              INTEGER NOT NULL DEFAULT 1
);

-- -----------------------------------------------------------------------------
-- Indexes to support the funnel queries in 03_adoption_funnel_walkthrough.sql
-- -----------------------------------------------------------------------------

CREATE INDEX idx_logins_emp_date        ON fact_logins (employee_key, login_date_key);
CREATE INDEX idx_lead_views_emp_date    ON fact_lead_views (employee_key, view_date_key);
CREATE INDEX idx_opportunities_owner    ON fact_opportunities (owner_employee_key, created_date_key);
CREATE INDEX idx_quotes_rep_date        ON fact_quotes (rep_employee_key, quote_date_key);
CREATE INDEX idx_activities_emp_date    ON fact_activities (employee_key, activity_date_key);
CREATE INDEX idx_eligibility_week       ON fact_employee_eligibility_weekly (week_end_date_key);
