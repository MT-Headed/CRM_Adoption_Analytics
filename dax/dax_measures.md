# Power BI / DAX layer

The SQL in `sql/03_adoption_funnel_walkthrough.sql` is the source of truth for
the logic in this project, but the same star schema loads cleanly into Power
BI (Import mode) for teams that want the funnel as an interactive report
instead of (or alongside) a SQL notebook. This file documents the DAX
measures that reproduce each SQL step, so the two layers stay in sync
conceptually even though the syntax is different.

Assumed model relationships (all single-direction, dimension-to-fact):

```
dim_date[date_key]              1 --- * fact_logins[login_date_key]
dim_date[date_key]              1 --- * fact_lead_views[view_date_key]
dim_date[date_key]              1 --- * fact_opportunities[created_date_key]
dim_date[date_key]              1 --- * fact_quotes[quote_date_key]
dim_date[date_key]              1 --- * fact_activities[activity_date_key]
dim_date[date_key]              1 --- * fact_employee_eligibility_weekly[week_end_date_key]
dim_employee[employee_key]      1 --- * (every fact table via its employee-role column)
dim_org_unit[org_unit_key]      1 --- * dim_employee[org_unit_key]
```

A disconnected `ref_eligible_job_families` table is loaded as-is (no
relationship) and referenced inside measures via `TREATAS`/`CONTAINS`, so the
eligible job family list stays a single editable table rather than a
hardcoded list buried in DAX.

## Stage 1 — Eligible Population Count

```dax
Eligible Population Count =
CALCULATE (
    DISTINCTCOUNT ( fact_employee_eligibility_weekly[employee_key] ),
    fact_employee_eligibility_weekly[is_eligible] = 1
)
```

## Stage 2 — Coverage (did they do it at all this period?)

One generic pattern, parameterized by which fact table you point it at.
Shown here for logins; the same shape applies to lead views, opportunities,
quotes, and activities.

```dax
Login Coverage Count =
CALCULATE (
    DISTINCTCOUNT ( fact_logins[employee_key] ),
    KEEPFILTERS ( TREATAS ( VALUES ( fact_employee_eligibility_weekly[employee_key] ), fact_logins[employee_key] ) )
)

Login Coverage % =
DIVIDE ( [Login Coverage Count], [Eligible Population Count] )
```

## Stage 3 — Regularity (do they do it most weeks, not just once?)

This is the measure worth the most care: an employee needs a qualifying
event in at least `Regularity Threshold` of the weeks in the current filter
context, not just one occurrence anywhere in the range.

```dax
Regularity Threshold = 0.75  -- edit to change the "most weeks" bar

Weeks In Period =
DISTINCTCOUNT ( dim_date[week_end_date] )

Required Weeks =
ROUNDUP ( [Weeks In Period] * [Regularity Threshold], 0 )

Regular Login Users Count =
VAR EmployeeWeeks =
    SUMMARIZE (
        fact_logins,
        fact_logins[employee_key],
        dim_date[week_end_date]
    )
VAR WeeksActivePerEmployee =
    ADDCOLUMNS (
        SUMMARIZE ( EmployeeWeeks, fact_logins[employee_key] ),
        "@WeeksActive", CALCULATE ( COUNTROWS ( EmployeeWeeks ) )
    )
RETURN
    COUNTROWS ( FILTER ( WeeksActivePerEmployee, [@WeeksActive] >= [Required Weeks] ) )

Regular Login Users % =
DIVIDE ( [Regular Login Users Count], [Eligible Population Count] )
```

`Regular Lead-Review Users %`, `Regular Quoting Users %`, `Regular
Opportunity-Conversion Users %`, and `Regular Activity-Logging Users %`
follow the same three-measure pattern against their respective fact tables.

## Stage 4 — Funnel summary table

A matrix visual with `dim_org_unit[office_name]` on rows and the five
`Regular * Users %` measures as columns reproduces the SQL walkthrough's
Step 6 output as an interactive, filterable report page — slice by
`dim_date[week_end_date]` for the trend view from Step 7, or by
`dim_org_unit[region]` for a rolled-up leadership view.

## Notes on scope

This is a compact, from-scratch DAX layer written to demonstrate the same
adoption-funnel concept as the SQL walkthrough, in a form a Power BI-based
portfolio reviewer would recognize. It intentionally does not replicate any
particular production semantic model's exact measure names, calculation
groups, or DirectLake-specific patterns — treat it as a clean-room
implementation of the same idea, not a port of an existing model.
