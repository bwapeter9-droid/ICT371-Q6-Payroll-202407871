-- =====================================================================
-- ICT371 Advanced Database | Student No: 202407871
-- QUESTION 6: Monthly Payroll Processing  (50 marks)
-- Run with:  psql -d yourdb -f ICT371_202407871_Q6_Payroll.sql
-- Objects live in schema q6_payroll; the script can be re-run safely.
-- =====================================================================
DROP SCHEMA IF EXISTS q6_payroll CASCADE;
CREATE SCHEMA q6_payroll;
SET search_path TO q6_payroll, public;

-- ---------------------------------------------------------------------
-- (a) DATABASE AND SEED DATA [6]
-- ---------------------------------------------------------------------
CREATE TABLE employees (
    employee_id   SERIAL        PRIMARY KEY,
    full_name     VARCHAR(100)  NOT NULL,
    basic_salary  NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance     NUMERIC(12,2) NOT NULL CHECK (allowance    >= 0),
    deduction     NUMERIC(12,2) NOT NULL CHECK (deduction    >= 0),
    active        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id   SERIAL        PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month    DATE          NOT NULL,
    gross_pay    NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay      NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month),
    CONSTRAINT chk_month_start   CHECK (EXTRACT(DAY FROM pay_month) = 1)   -- first day of a month
);

CREATE TABLE salary_audit (
    audit_id     SERIAL        PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary   NUMERIC(12,2) NOT NULL,
    new_salary   NUMERIC(12,2) NOT NULL,
    changed_at   TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Alice Mulenga', 5000.00, 500.00, 300.00, TRUE),
    ('Bob Chanda',    4000.00, 400.00, 250.00, TRUE),
    ('Carol Zimba',   6000.00, 600.00, 400.00, TRUE),
    ('David Nyirenda',3500.00, 300.00, 200.00, FALSE);   -- INACTIVE employee

-- Historical payroll row for the inactive employee, two months ago
-- (gross 3500+300 = 3800 ; net 3800-200 = 3600)
INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
VALUES (4, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::DATE, 3800.00, 3600.00);

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_net_pay [6]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction
    INTO   v_net
    FROM   employees
    WHERE  employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_process_payroll [8]  - query FOR loop
-- ON CONFLICT DO NOTHING leaves existing rows unchanged.
-- Any exception (e.g. negative net pay) aborts the WHOLE call, so no
-- partial payroll is left behind.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    r     RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::DATE THEN
        RAISE EXCEPTION 'Pay month must be the first day of a month, got %', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM   employees
        WHERE  active = TRUE
        ORDER  BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);           -- raises on invalid calculation

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER AFTER UPDATE [8]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- Seed two payroll months for the active employees
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::DATE);
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);

-- ---------------------------------------------------------------------
-- (e) VIEW v_payroll_report [5]  - plain JOIN, no "active" filter, so
-- history of employees who later became inactive is kept.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT p.payroll_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM   payroll p
JOIN   employees e ON e.employee_id = p.employee_id;

-- ---------------------------------------------------------------------
-- (f) INDEX [5]
-- The existing UNIQUE (employee_id, pay_month) index starts with
-- employee_id, so it cannot efficiently answer "all employees for ONE
-- month". A single-column index on pay_month does, and does not
-- duplicate the unique index.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB [6]
-- 02:00 on day 1 of each month, passing the FIRST DATE OF THE PREVIOUS MONTH.
-- ---------------------------------------------------------------------

-- Safe scheduling: runs only if pg_cron is available on this server.
-- If it is not installed you will just see a NOTICE and the rest of the script still works.
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q6_monthly_payroll', '0 2 1 * *', $cmd$CALL q6_payroll.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE)$cmd$);
        RAISE NOTICE 'Job q6_monthly_payroll scheduled: 0 2 1 * *';
    ELSE
        RAISE NOTICE 'pg_cron is not installed on this server - job NOT scheduled. Schedule used: 0 2 1 * *';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule job (q6_monthly_payroll): %', SQLERRM;
END
$do$;

-- Inspect the job:
-- Inspect job / history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q6_monthly_payroll';
-- Inspect run history (shows status, return_message, start/end time):
-- Inspect job / history (uncomment where pg_cron is installed):
-- SELECT jobid, runid, status, return_message, start_time, end_time
-- FROM   cron.job_run_details
-- WHERE  jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q6_monthly_payroll')
-- ORDER  BY start_time DESC LIMIT 10;
-- To remove the job:  SELECT cron.unschedule('q6_monthly_payroll');

-- =====================================================================
-- TESTS / EVIDENCE
-- =====================================================================
SELECT '--- (a) Data ---' AS section;
SELECT * FROM employees ORDER BY employee_id;
SELECT * FROM payroll ORDER BY pay_month, employee_id;

SELECT '--- (b) Function ---' AS section;
SELECT employee_id, fn_net_pay(employee_id) FROM employees ORDER BY employee_id;   -- 5200, 4150, 6200, 3600
DO $$ BEGIN PERFORM fn_net_pay(999);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown employee): %', SQLERRM; END $$;

SELECT '--- (c) Procedure ---' AS section;
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-15');
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (not month start): %', SQLERRM; END $$;

-- A raise during the month must not change the existing payroll row:
SELECT employee_id, gross_pay, net_pay FROM payroll
WHERE  employee_id = 1 AND pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE;
UPDATE employees SET basic_salary = 5500.00 WHERE employee_id = 1;       -- logged by trigger
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);   -- rerun
SELECT employee_id, gross_pay, net_pay FROM payroll
WHERE  employee_id = 1 AND pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE;  -- unchanged
SELECT COUNT(*) AS rows_after_rerun FROM payroll;                         -- still 7 (3 + 3 active employees + David's history)

-- Invalid calculation fails the WHOLE call (the DO block rolls back its own UPDATE too):
DO $$ BEGIN
    UPDATE employees SET deduction = 100000 WHERE employee_id = 2;       -- makes Bob's net negative
    CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (whole call fails): %', SQLERRM; END $$;
SELECT COUNT(*) AS rows_for_current_month_must_be_0 FROM payroll
WHERE pay_month = date_trunc('month', CURRENT_DATE)::DATE;

SELECT '--- (d) Trigger: salary change logged, allowance-only change is not ---' AS section;
SELECT * FROM salary_audit ORDER BY audit_id;                             -- 1 row (5000 -> 5500)
UPDATE employees SET allowance = 550.00 WHERE employee_id = 1;
UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 2;   -- unchanged
SELECT COUNT(*) AS audit_rows_still_1 FROM salary_audit;

SELECT '--- (e) View includes history of inactive David ---' AS section;
SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

SELECT '--- (f) EXPLAIN ---' AS section;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE;
RESET enable_seqscan;
