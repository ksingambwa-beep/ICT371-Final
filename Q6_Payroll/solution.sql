-- (a) Database and seed data [6 marks]
-- Employee 4 starts active so payroll can be processed for two months through the procedure, then becomes inactive. 
-- This gives historical payroll rows for an inactive employee. The payroll is loaded in "(a) continued".
DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6, public;
 
CREATE TABLE employees (
  employee_id   SERIAL PRIMARY KEY,
  full_name     VARCHAR(100) NOT NULL,
  basic_salary  NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance     NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction     NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active        BOOLEAN NOT NULL DEFAULT TRUE
);
 
CREATE TABLE payroll (
  payroll_id   SERIAL PRIMARY KEY,
  employee_id  INT NOT NULL REFERENCES employees(employee_id),
  pay_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
  gross_pay    NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay      NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month)
);
 
CREATE TABLE salary_audit (
  audit_id     SERIAL PRIMARY KEY,
  employee_id  INT NOT NULL REFERENCES employees(employee_id),
  old_salary   NUMERIC(12,2) NOT NULL,
  new_salary   NUMERIC(12,2) NOT NULL,
  changed_at   TIMESTAMP NOT NULL DEFAULT now()
);
 
INSERT INTO employees
  (full_name, basic_salary, allowance, deduction, active) VALUES
  ('Mulenga Kapata',  5000, 500, 300, TRUE),
  ('Nkandu Mwiinga',  4000, 400, 250, TRUE),
  ('Kapya Lubinda',   6000, 700, 500, TRUE),
  ('Zimba Chanda',    3000, 200, 150, TRUE);

-- Test queries
SELECT * FROM employees ORDER BY employee_id;

-- (b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
  v_net NUMERIC;
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
  END IF;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END $$;

-- Test queries
SELECT fn_net_pay(1);    -- 5200.00
SELECT fn_net_pay(99);   -- ERROR: Unknown employee

-- (c) Procedure [8 marks]
A query FOR loop visits each active employee. ON CONFLICT DO NOTHING leaves an existing employee/month row unchanged. If fn_net_pay raises for any employee, the whole CALL is rolled back, so no partial payroll is stored.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
  r     RECORD;
  v_net NUMERIC;
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'Payroll month must be the first day of a month';
  END IF;
 
  FOR r IN
    SELECT employee_id, basic_salary, allowance
    FROM employees
    WHERE active
    ORDER BY employee_id
  LOOP
    v_net := fn_net_pay(r.employee_id);   -- raises on an invalid calculation
    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;
  END LOOP;
END $$;

-- Test queries
CALL pr_process_payroll('2026-09-15');   -- ERROR: not a month start
CALL pr_process_payroll(NULL);           -- ERROR

-- (d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_salary_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  END IF;
  RETURN NEW;
END $$;
 
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_salary_audit_fn();

-- Test queries
UPDATE employees SET allowance = 450 WHERE employee_id = 2;       -- no audit
UPDATE employees SET basic_salary = 4000 WHERE employee_id = 2;   -- same value
SELECT COUNT(*) FROM salary_audit;                                -- 0
UPDATE employees SET basic_salary = 4200 WHERE employee_id = 2;   -- real change
SELECT * FROM salary_audit;                                       -- 1 row
-- restore original values (the salary restore is audited too)
UPDATE employees SET allowance = 400, basic_salary = 4000
WHERE employee_id = 2;

-- (a) continued: process two months, then deactivate employee 4
CALL pr_process_payroll('2026-09-01');
CALL pr_process_payroll('2026-10-01');
CALL pr_process_payroll('2026-10-01');   -- rerun: no change, no duplicates
 
UPDATE employees SET active = FALSE WHERE employee_id = 4;
CALL pr_process_payroll('2026-11-01');   -- employee 4 is skipped

-- Test queries
SELECT * FROM payroll ORDER BY pay_month, employee_id;   -- 4 + 4 + 3 rows
SELECT * FROM salary_audit;
 
-- An invalid calculation fails the whole call (rolled back):
BEGIN;
UPDATE employees SET deduction = 99999 WHERE employee_id = 1;
CALL pr_process_payroll('2026-12-01');   -- ERROR: Negative net pay
ROLLBACK;
SELECT COUNT(*) FROM payroll WHERE pay_month = '2026-12-01';   -- 0

-- (e) View [5 marks]
An inner join to employees with no filter on active keeps historical rows for employees who later became inactive.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
ORDER BY p.pay_month, e.full_name;

-- Test queries
SELECT * FROM v_payroll_report;   -- includes Zimba Chanda for Sep and Oct

-- (f) Index [5 marks]
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
 
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payroll WHERE pay_month = '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job [6 marks]
Runs at 02:00 on day 1 of each month. date_trunc gives the first day of the current month; subtracting one month gives the first day of the previous month.
CREATE EXTENSION IF NOT EXISTS pg_cron;
 
SELECT cron.schedule('q6_monthly_payroll', '0 2 1 * *',
  $$CALL q6.pr_process_payroll(
      (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);
 
-- Inspect the job
SELECT jobid, jobname, schedule, command, active FROM cron.job;
 
-- Inspect the run history
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC;

-- Test queries
-- To remove the job later:
-- SELECT cron.unschedule('q6_monthly_payroll');
