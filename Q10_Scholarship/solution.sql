-- (a) Database and seed data [6 marks]
-- Six PENDING applications across three students: two qualifying (both at boundaries), two failing on age (17 and 26), one failing on income (K3,000.01) and one failing on mark (69.99).
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10, public;
 
CREATE TABLE students (
  student_id      SERIAL PRIMARY KEY,
  student_number  VARCHAR(20) NOT NULL UNIQUE,
  full_name       VARCHAR(100) NOT NULL
);
 
CREATE TABLE applications (
  application_id      SERIAL PRIMARY KEY,
  student_id          INT NOT NULL REFERENCES students(student_id),
  age_at_application  INT NOT NULL CHECK (age_at_application > 0),
  monthly_income      NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark        NUMERIC(5,2) NOT NULL
    CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on        DATE NOT NULL,
  status              VARCHAR(10) NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
 
CREATE TABLE decision_audit (
  audit_id        SERIAL PRIMARY KEY,
  application_id  INT NOT NULL REFERENCES applications(application_id),
  old_status      VARCHAR(10) NOT NULL,
  new_status      VARCHAR(10) NOT NULL,
  changed_at      TIMESTAMP NOT NULL DEFAULT now()
);
 
INSERT INTO students (student_number, full_name) VALUES
  ('S2026001', 'Grace Mumba'), ('S2026002', 'David Katongo'),
  ('S2026003', 'Ruth Sichone');
 
INSERT INTO applications
  (student_id, age_at_application, monthly_income, average_mark,
   submitted_on, status) VALUES
  (1, 18, 3000.00, 70.00, '2026-11-02', 'PENDING'),  -- all lower boundaries: qualifies
  (1, 25, 2000.00, 85.00, '2026-11-03', 'PENDING'),  -- upper age boundary: qualifies
  (2, 17, 1000.00, 90.00, '2026-11-04', 'PENDING'),  -- too young
  (2, 26, 1000.00, 90.00, '2026-11-05', 'PENDING'),  -- too old
  (3, 20, 3000.01, 80.00, '2026-11-09', 'PENDING'),  -- income just over
  (3, 22, 2500.00, 69.99, '2026-11-10', 'PENDING');  -- mark just under

-- Test queries
SELECT * FROM applications ORDER BY application_id;

-- (b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
  p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark must not be NULL';
  END IF;
  IF p_age <= 0 THEN
    RAISE EXCEPTION 'Age must be positive';
  END IF;
  IF p_income < 0 THEN
    RAISE EXCEPTION 'Income cannot be negative';
  END IF;
  IF p_mark < 0 OR p_mark > 100 THEN
    RAISE EXCEPTION 'Mark must be between 0 and 100';
  END IF;
  RETURN p_age BETWEEN 18 AND 25
     AND p_income <= 3000
     AND p_mark >= 70;
END $$;

-- Test queries
SELECT fn_scholarship_eligible(18, 3000, 70);        -- true
SELECT fn_scholarship_eligible(26, 1000, 90);        -- false
SELECT fn_scholarship_eligible(20, 3000.01, 80);     -- false
SELECT fn_scholarship_eligible(NULL, 1000, 80);      -- ERROR
SELECT fn_scholarship_eligible(20, 1000, 101);       -- ERROR

-- (c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
  v_age    INT;
  v_income NUMERIC;
  v_mark   NUMERIC;
  v_status VARCHAR(10);
BEGIN
  SELECT age_at_application, monthly_income, average_mark, status
  INTO v_age, v_income, v_mark, v_status
  FROM applications WHERE application_id = p_application_id FOR UPDATE;
 
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application % does not exist', p_application_id;
  END IF;
  IF v_status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % was already assessed (status %)',
                    p_application_id, v_status;
  END IF;
 
  UPDATE applications
  SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                    THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END $$;

-- Test queries
CALL pr_assess_application(99);   -- ERROR: does not exist

-- (d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_decision_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO decision_audit
      (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
  END IF;
  RETURN NEW;
END $$;
 
CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION trg_decision_audit_fn();

-- Test queries
-- Same status: no audit row
UPDATE applications SET status = 'PENDING' WHERE application_id = 1;
UPDATE applications SET average_mark = 70 WHERE application_id = 1;
SELECT COUNT(*) FROM decision_audit;   -- 0
 
-- Assess one application: exactly one audit row
CALL pr_assess_application(1);
SELECT * FROM applications WHERE application_id = 1;   -- APPROVED
SELECT * FROM decision_audit;                           -- PENDING -> APPROVED
CALL pr_assess_application(1);   -- ERROR: already assessed

-- (e) View [5 marks]
Income is deliberately left out of the view.
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- Test queries
SELECT * FROM v_approved_applicants;

-- (f) Index [5 marks]
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);
 
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- (g) Scheduled job [6 marks]
-- The query FOR loop selects only PENDING applications, so completed ones are never reassessed on a rerun and no duplicate audit entries are created.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT application_id FROM applications
    WHERE status = 'PENDING'
    ORDER BY application_id
  LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END $$;
 
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q10_assess_pending', '0 8 * * 1',
  $$CALL q10.pr_assess_pending()$$);

-- Test queries
CALL pr_assess_pending();
SELECT application_id, status FROM applications ORDER BY 1;
SELECT COUNT(*) FROM decision_audit;     -- 6 (one per application)
 
CALL pr_assess_pending();                -- rerun: nothing pending
SELECT COUNT(*) FROM decision_audit;     -- still 6
SELECT jobid, jobname, schedule, command FROM cron.job;
