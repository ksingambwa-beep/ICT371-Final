-- (a) Database and seed data [6 marks]
-- Students are created here. The six payments are loaded in "(a) continued" through the procedure, after the trigger exists, so every payment is audited by the trigger.
DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path TO q2, public;
 
CREATE TABLE students (
  student_id      SERIAL PRIMARY KEY,
  student_number  VARCHAR(20) NOT NULL UNIQUE,
  full_name       VARCHAR(100) NOT NULL,
  fee_due         NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
 
CREATE TABLE payments (
  payment_id  SERIAL PRIMARY KEY,
  student_id  INT NOT NULL REFERENCES students(student_id),
  amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on     DATE NOT NULL
);
 
CREATE TABLE payment_audit (
  audit_id    SERIAL PRIMARY KEY,
  payment_id  INT NOT NULL REFERENCES payments(payment_id),
  student_id  INT NOT NULL REFERENCES students(student_id),
  amount      NUMERIC(12,2) NOT NULL,
  logged_at   TIMESTAMP NOT NULL DEFAULT now()
);
 
CREATE TABLE daily_collections (
  collection_date  DATE PRIMARY KEY,
  payment_count    INT NOT NULL,
  total_amount     NUMERIC(14,2) NOT NULL
);
 
INSERT INTO students (student_number, full_name, fee_due) VALUES
  ('2026001', 'Alice Mwale',  5000.00),
  ('2026002', 'Brian Phiri',  3000.00),
  ('2026003', 'Chanda Banda', 4000.00);

-- Test queries
SELECT * FROM students;

-- (b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
  v_fee  NUMERIC;
  v_paid NUMERIC;
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM payments WHERE student_id = p_student_id;
  RETURN v_fee - v_paid;
END $$;

-- Test queries
SELECT fn_fee_balance(3);    -- 4000.00 (no payments: full fee)
SELECT fn_fee_balance(99);   -- ERROR: Unknown student

-- (c) Procedure [8 marks]
-- The procedure only inserts into payments. It never touches fee_due and does not write the audit row (the trigger does). 
-- The student row is locked so two simultaneous payments cannot overpay.
CREATE OR REPLACE PROCEDURE pr_receive_payment(
  p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
  v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be a positive number';
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Payment date is required';
  END IF;
 
  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
  v_balance := fn_fee_balance(p_student_id);  -- raises if unknown student
 
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %',
                    p_amount, v_balance;
  END IF;
 
  INSERT INTO payments (student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- Test queries
CALL pr_receive_payment(3, 0, CURRENT_DATE);       -- ERROR: not positive
CALL pr_receive_payment(3, NULL, CURRENT_DATE);    -- ERROR: not positive
CALL pr_receive_payment(3, 99999, CURRENT_DATE);   -- ERROR: exceeds balance
CALL pr_receive_payment(99, 10, CURRENT_DATE);     -- ERROR: Unknown student
SELECT COUNT(*) FROM payments;                     -- 0

-- (d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_payment_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END $$;
 
CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit_fn();

-- (a) continued: load six payments through the procedure
-- Alice pays part of her fee, Brian settles in full, Chanda has no payments.
CALL pr_receive_payment(1, 1000, '2026-11-18');
CALL pr_receive_payment(1, 1500, '2026-11-18');
CALL pr_receive_payment(1,  500, '2026-11-19');
CALL pr_receive_payment(2, 1000, '2026-11-19');
CALL pr_receive_payment(2, 1000, '2026-11-20');
CALL pr_receive_payment(2, 1000, '2026-11-20');

-- Test queries
SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;   -- six rows, from the trigger
SELECT student_id, fee_due FROM students;        -- fee_due unchanged
SELECT fn_fee_balance(1), fn_fee_balance(2), fn_fee_balance(3);
CALL pr_receive_payment(2, 1, CURRENT_DATE);     -- ERROR: exceeds balance (0)

-- (e) View [5 marks]
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- Test queries
SELECT * FROM v_fee_balances;   -- Alice (2000) and Chanda (4000); Brian excluded

-- (f) Index [5 marks]
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);
 
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- (g) Scheduled job [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END $$;
 
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q2_refresh_collections', '0 1 * * *',
  $$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$$);

-- Test queries
CALL pr_refresh_collections('2026-11-18');
CALL pr_refresh_collections('2026-11-18');   -- rerun replaces the row
SELECT * FROM daily_collections;
SELECT jobid, jobname, schedule, command FROM cron.job;
