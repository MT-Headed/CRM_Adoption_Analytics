"""
generate_sample_data.py
------------------------
Deterministically generates a small, fully-synthetic sample dataset for the
CRM Adoption Analytics case study and writes it out as SQL INSERT statements
(sql/02_seed_data.sql).

Everything here is fabricated: fictional company, fictional people, fictional
offices, randomly generated (but realistic-shaped) activity. There is no
connection to any real organization's data. Re-running this script produces
identical output because the random seed is fixed, which keeps the
executable SQL walkthrough reproducible.

Usage:
    python3 data/generate_sample_data.py > sql/02_seed_data.sql
"""

import random
from datetime import date, timedelta

random.seed(42)

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

REGIONS = ["North", "South"]
OFFICES = [
    # (org_unit_key, region, territory, office_name)
    (1, "North", "Great Lakes", "Chicago Office"),
    (2, "North", "Northeast", "Boston Office"),
    (3, "South", "Southeast", "Atlanta Office"),
    (4, "South", "Southwest", "Austin Office"),
]

JOB_FAMILIES = ["Outside Sales", "Inside Sales", "Sales Support", "Sales Leadership"]
ELIGIBLE_JOB_FAMILIES = {"Outside Sales", "Inside Sales", "Sales Support"}

ACTIVITY_TYPES = [
    (1, "Call Logged", "Outreach"),
    (2, "Meeting Logged", "Outreach"),
    (3, "Email Logged", "Outreach"),
    (4, "Follow-up Task", "Admin"),
    (5, "Note Added", "Admin"),
]

OPPORTUNITY_TYPES = [
    (1, "New Business"),
    (2, "Renewal"),
    (3, "Expansion"),
]

FIRST_NAMES = [
    "Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Jamie", "Drew",
    "Cameron", "Sydney", "Avery", "Reese", "Quinn", "Rowan", "Skyler",
    "Emerson", "Hayden", "Parker", "Elliot", "Finley",
]
LAST_NAMES = [
    "Bennett", "Carver", "Doyle", "Ellison", "Foster", "Grady", "Hensley",
    "Ibarra", "Jansen", "Kowalski", "Lindqvist", "Marsh", "Nolan", "Osei",
    "Pruitt", "Quintero", "Reyes", "Sorensen", "Torres", "Vance",
]

# ---------------------------------------------------------------------------
# Date dimension: 10 ISO weeks (Mon-Sun), 70 calendar days
# ---------------------------------------------------------------------------

START_DATE = date(2026, 5, 4)  # a Monday
NUM_WEEKS = 10
ALL_DATES = [START_DATE + timedelta(days=i) for i in range(NUM_WEEKS * 7)]


def week_bounds(d: date):
    start = d - timedelta(days=d.weekday())
    end = start + timedelta(days=6)
    return start, end


def date_key(d: date) -> int:
    return int(d.strftime("%Y%m%d"))


def sql_date(d: date) -> str:
    return d.isoformat()


# ---------------------------------------------------------------------------
# Employees: 24 employees spread across the 4 offices
# ---------------------------------------------------------------------------

NUM_EMPLOYEES = 24
employees = []
name_pairs = random.sample(
    [(f, l) for f in FIRST_NAMES for l in LAST_NAMES], NUM_EMPLOYEES
)
for i in range(NUM_EMPLOYEES):
    employee_key = 1000 + i
    first, last = name_pairs[i]
    org_unit_key = OFFICES[i % len(OFFICES)][0]
    # weight toward the two selling job families, a few support/leadership
    job_family = random.choices(
        JOB_FAMILIES, weights=[0.35, 0.30, 0.15, 0.20], k=1
    )[0]
    hire_date = START_DATE - timedelta(days=random.randint(120, 900))
    # two employees terminate partway through the window to exercise
    # eligibility-over-time logic
    termination_date = None
    if i in (5, 17):
        termination_date = START_DATE + timedelta(days=random.randint(20, 45))
    # a couple of "always logged in but not in an eligible job family"
    # accounts, to show eligibility != CRM access
    is_crm_licensed = 1
    employees.append(
        dict(
            employee_key=employee_key,
            employee_code=f"EMP-{employee_key}",
            display_name=f"{first} {last}",
            job_family=job_family,
            org_unit_key=org_unit_key,
            hire_date=hire_date,
            termination_date=termination_date,
            is_crm_licensed=is_crm_licensed,
        )
    )

# Give each employee a personal "engagement level" so activity isn't uniform
# noise -- this makes the funnel numbers in the walkthrough tell a story
# (some reps are heavy adopters, some are laggards).
engagement_level = {e["employee_key"]: random.uniform(0.15, 0.95) for e in employees}


def is_employed(emp, d: date) -> bool:
    if d < emp["hire_date"]:
        return False
    if emp["termination_date"] and d > emp["termination_date"]:
        return False
    return True


def is_eligible(emp, d: date) -> bool:
    return is_employed(emp, d) and emp["job_family"] in ELIGIBLE_JOB_FAMILIES


# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

eligibility_rows = []  # (employee_key, week_end_date_key, is_eligible)
login_rows = []  # (employee_key, login_date_key)
lead_rows = []  # (lead_key, created_date_key, lead_value)
lead_view_rows = []  # (lead_key, employee_key, view_date_key)
opportunity_rows = []  # (opportunity_key, owner_employee_key, opportunity_type_key, created_date_key, source_lead_key, opportunity_value, opportunity_qty)
quote_rows = []  # (quote_key, opportunity_key, rep_employee_key, quote_date_key, quote_amount)
activity_rows = []  # (activity_key, employee_key, activity_type_key, opportunity_key, activity_date_key, quantity)

# weekly eligibility snapshot
week_starts = sorted({week_bounds(d)[0] for d in ALL_DATES})
for ws in week_starts:
    _, we = week_bounds(ws)
    for emp in employees:
        eligibility_rows.append(
            (emp["employee_key"], date_key(we), 1 if is_eligible(emp, we) else 0)
        )

# leads: ~3-6 new leads per business day, no employee attached at creation
lead_key_seq = 1
leads_by_date = {}
for d in ALL_DATES:
    if d.weekday() >= 5:
        continue
    n_leads = random.randint(2, 5)
    day_leads = []
    for _ in range(n_leads):
        value = round(random.uniform(500, 12000), 2)
        lead_rows.append((lead_key_seq, date_key(d), value))
        day_leads.append(lead_key_seq)
        lead_key_seq += 1
    leads_by_date[d] = day_leads

opportunity_key_seq = 1
quote_key_seq = 1
activity_key_seq = 1

for d in ALL_DATES:
    if d.weekday() >= 5:
        continue  # business days only for activity generation
    for emp in employees:
        if not is_employed(emp, d):
            continue
        level = engagement_level[emp["employee_key"]]
        eligible_today = is_eligible(emp, d)

        # Logins: eligible reps log in most days if engaged; a few
        # non-eligible (support/leadership) accounts also log in sometimes.
        login_chance = level if eligible_today else 0.5
        if random.random() < login_chance:
            login_rows.append((emp["employee_key"], date_key(d)))

            # Lead views only happen on days the rep logged in, and only
            # for eligible reps
            if eligible_today and d in leads_by_date and random.random() < level * 0.6:
                lead_key = random.choice(leads_by_date[d])
                lead_view_rows.append((lead_key, emp["employee_key"], date_key(d)))

                # Some viewed leads convert into an opportunity the same day
                if random.random() < level * 0.25:
                    opp_type = random.choice(OPPORTUNITY_TYPES)[0]
                    opp_value = round(random.uniform(1000, 25000), 2)
                    opportunity_rows.append(
                        (
                            opportunity_key_seq,
                            emp["employee_key"],
                            opp_type,
                            date_key(d),
                            lead_key,
                            opp_value,
                            1,
                        )
                    )
                    opportunity_key_seq += 1

            # Reps also create opportunities directly (not from a lead)
            if eligible_today and random.random() < level * 0.10:
                opp_type = random.choice(OPPORTUNITY_TYPES)[0]
                opp_value = round(random.uniform(1000, 25000), 2)
                opportunity_rows.append(
                    (
                        opportunity_key_seq,
                        emp["employee_key"],
                        opp_type,
                        date_key(d),
                        None,
                        opp_value,
                        1,
                    )
                )
                opportunity_key_seq += 1

            # Activities logged (calls/meetings/emails/etc.)
            if eligible_today:
                n_activities = 0
                if random.random() < level:
                    n_activities = random.randint(1, 6)
                for _ in range(n_activities):
                    activity_type = random.choice(ACTIVITY_TYPES)[0]
                    activity_rows.append(
                        (
                            activity_key_seq,
                            emp["employee_key"],
                            activity_type,
                            None,
                            date_key(d),
                            1,
                        )
                    )
                    activity_key_seq += 1

# Quotes: generated against a random subset of opportunities, by the owner
for opp in opportunity_rows:
    (opp_key, owner_key, _opp_type, created_key, _src, opp_value, _qty) = opp
    if random.random() < 0.55:
        quote_amount = round(opp_value * random.uniform(0.7, 1.05), 2)
        quote_rows.append((quote_key_seq, opp_key, owner_key, created_key, quote_amount))
        quote_key_seq += 1


# ---------------------------------------------------------------------------
# Emit SQL
# ---------------------------------------------------------------------------

def esc(s):
    return str(s).replace("'", "''")


lines = []
lines.append("-- 02_seed_data.sql")
lines.append("-- Fully synthetic sample data for the CRM Adoption Analytics case study.")
lines.append("-- Generated by data/generate_sample_data.py (fixed random seed = reproducible).")
lines.append("-- No real people, companies, or CRM records are represented here.")
lines.append("")
lines.append("BEGIN TRANSACTION;")
lines.append("")

# dim_date
lines.append("-- dim_date -----------------------------------------------------------------")
for d in ALL_DATES:
    ws, we = week_bounds(d)
    lines.append(
        "INSERT INTO dim_date (date_key, calendar_date, week_start_date, week_end_date, "
        "month_number, month_name, quarter_number, year_number, is_business_day) VALUES "
        f"({date_key(d)}, '{sql_date(d)}', '{sql_date(ws)}', '{sql_date(we)}', "
        f"{d.month}, '{d.strftime('%B')}', {(d.month - 1)//3 + 1}, {d.year}, "
        f"{0 if d.weekday() >= 5 else 1});"
    )
lines.append("")

# dim_org_unit
lines.append("-- dim_org_unit ---------------------------------------------------------------")
for org_unit_key, region, territory, office_name in OFFICES:
    lines.append(
        "INSERT INTO dim_org_unit (org_unit_key, region, territory, office_name) VALUES "
        f"({org_unit_key}, '{region}', '{territory}', '{office_name}');"
    )
lines.append("")

# dim_employee
lines.append("-- dim_employee -----------------------------------------------------------")
for emp in employees:
    term = f"'{sql_date(emp['termination_date'])}'" if emp["termination_date"] else "NULL"
    lines.append(
        "INSERT INTO dim_employee (employee_key, employee_code, display_name, job_family, "
        "org_unit_key, hire_date, termination_date, is_crm_licensed) VALUES "
        f"({emp['employee_key']}, '{emp['employee_code']}', '{esc(emp['display_name'])}', "
        f"'{emp['job_family']}', {emp['org_unit_key']}, '{sql_date(emp['hire_date'])}', "
        f"{term}, {emp['is_crm_licensed']});"
    )
lines.append("")

# dim_activity_type
lines.append("-- dim_activity_type ------------------------------------------------------")
for k, name, category in ACTIVITY_TYPES:
    lines.append(
        "INSERT INTO dim_activity_type (activity_type_key, activity_type_name, category) "
        f"VALUES ({k}, '{name}', '{category}');"
    )
lines.append("")

# dim_opportunity_type
lines.append("-- dim_opportunity_type ----------------------------------------------------")
for k, name in OPPORTUNITY_TYPES:
    lines.append(
        "INSERT INTO dim_opportunity_type (opportunity_type_key, opportunity_type_name) "
        f"VALUES ({k}, '{name}');"
    )
lines.append("")

# fact_employee_eligibility_weekly
lines.append("-- fact_employee_eligibility_weekly -----------------------------------------")
for employee_key, week_end_date_key, elig in eligibility_rows:
    lines.append(
        "INSERT INTO fact_employee_eligibility_weekly (employee_key, week_end_date_key, "
        f"is_eligible) VALUES ({employee_key}, {week_end_date_key}, {elig});"
    )
lines.append("")

# fact_logins
lines.append("-- fact_logins --------------------------------------------------------------")
for employee_key, login_date_key in login_rows:
    lines.append(
        "INSERT INTO fact_logins (employee_key, login_date_key) VALUES "
        f"({employee_key}, {login_date_key});"
    )
lines.append("")

# fact_leads
lines.append("-- fact_leads (anonymized: no employee attached) -----------------------------")
for lead_key, created_date_key, lead_value in lead_rows:
    lines.append(
        "INSERT INTO fact_leads (lead_key, created_date_key, lead_value) VALUES "
        f"({lead_key}, {created_date_key}, {lead_value});"
    )
lines.append("")

# fact_lead_views
lines.append("-- fact_lead_views ------------------------------------------------------------")
for lead_key, employee_key, view_date_key in lead_view_rows:
    lines.append(
        "INSERT INTO fact_lead_views (lead_key, employee_key, view_date_key) VALUES "
        f"({lead_key}, {employee_key}, {view_date_key});"
    )
lines.append("")

# fact_opportunities
lines.append("-- fact_opportunities ---------------------------------------------------------")
for (
    opp_key,
    owner_key,
    opp_type,
    created_key,
    src_lead_key,
    opp_value,
    opp_qty,
) in opportunity_rows:
    src = src_lead_key if src_lead_key is not None else "NULL"
    lines.append(
        "INSERT INTO fact_opportunities (opportunity_key, owner_employee_key, "
        "opportunity_type_key, created_date_key, source_lead_key, opportunity_value, "
        f"opportunity_qty) VALUES ({opp_key}, {owner_key}, {opp_type}, {created_key}, "
        f"{src}, {opp_value}, {opp_qty});"
    )
lines.append("")

# fact_quotes
lines.append("-- fact_quotes ------------------------------------------------------------")
for quote_key, opp_key, rep_key, quote_date_key, amount in quote_rows:
    lines.append(
        "INSERT INTO fact_quotes (quote_key, opportunity_key, rep_employee_key, "
        f"quote_date_key, quote_amount) VALUES ({quote_key}, {opp_key}, {rep_key}, "
        f"{quote_date_key}, {amount});"
    )
lines.append("")

# fact_activities
lines.append("-- fact_activities --------------------------------------------------------")
for (
    activity_key,
    employee_key,
    activity_type_key,
    opp_key,
    activity_date_key,
    qty,
) in activity_rows:
    opp = opp_key if opp_key is not None else "NULL"
    lines.append(
        "INSERT INTO fact_activities (activity_key, employee_key, activity_type_key, "
        f"opportunity_key, activity_date_key, quantity) VALUES ({activity_key}, "
        f"{employee_key}, {activity_type_key}, {opp}, {activity_date_key}, {qty});"
    )
lines.append("")

lines.append("COMMIT;")
lines.append("")

print("\n".join(lines))
