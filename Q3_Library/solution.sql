-- (a) Database and seed data [6 marks]
-- Six loans are inserted as open loans. Two of them are returned later through pr_return_loan (see "(a) continued"), giving a returned late loan and a loan returned on its due date. 
-- Loans 1 and 5 are open and overdue; loans 2 and 6 are not yet due.
DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path TO q3, public;
 
CREATE TABLE books (
  book_id  SERIAL PRIMARY KEY,
  title    VARCHAR(150) NOT NULL
);
 
CREATE TABLE loans (
  loan_id        SERIAL PRIMARY KEY,
  book_id        INT NOT NULL REFERENCES books(book_id),
  borrower_name  VARCHAR(100) NOT NULL,
  borrowed_on    DATE NOT NULL,
  due_on         DATE NOT NULL,
  returned_on    DATE,
  fine_amount    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);
 
CREATE TABLE loan_audit (
  audit_id          SERIAL PRIMARY KEY,
  loan_id           INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on   DATE,
  new_returned_on   DATE,
  changed_at        TIMESTAMP NOT NULL DEFAULT now()
);
 
CREATE TABLE overdue_summary (
  snapshot_date  DATE PRIMARY KEY,
  overdue_count  INT NOT NULL,
  total_fine     NUMERIC(12,2) NOT NULL
);
 
INSERT INTO books (title) VALUES
  ('Database System Concepts'),
  ('Introduction to Algorithms'),
  ('Computer Networks');
 
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
  (1, 'Mwansa',    '2026-10-20', '2026-11-03'),  -- open, overdue
  (2, 'Chileshe',  '2026-11-15', '2026-12-15'),  -- open, not yet due
  (3, 'Banda',     '2026-10-01', '2026-10-15'),  -- returned late
  (1, 'Phiri',     '2026-11-01', '2026-11-10'),  -- returned on due date
  (2, 'Tembo',     '2026-10-25', '2026-11-08'),  -- open, overdue
  (3, 'Zulu',      '2026-11-20', '2026-12-04');  -- open, not yet due

-- Test queries
SELECT * FROM loans ORDER BY loan_id;

-- (b) Function [6 marks]
-- The fine is calculated up to the earlier of p_as_of and returned_on. GREATEST(0, ...) gives the minimum of zero.
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
  v_due DATE;
  v_ret DATE;
  v_end DATE;
BEGIN
  IF p_as_of IS NULL THEN
    RAISE EXCEPTION 'As-of date is required';
  END IF;
  SELECT due_on, returned_on INTO v_due, v_ret
  FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
  END IF;
  v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));
  RETURN 2 * GREATEST(0, v_end - v_due);
END $$;

-- Test queries
SELECT fn_loan_fine(1, CURRENT_DATE);   -- open overdue loan
SELECT fn_loan_fine(2, CURRENT_DATE);   -- 0 (not yet due)
SELECT fn_loan_fine(99, CURRENT_DATE);  -- ERROR: Unknown loan

(c) Procedure [8 marks]
-- The final fine is calculated first, then the return date and the fine are stored in one UPDATE so they always agree.
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
  v_borrowed DATE;
  v_returned DATE;
  v_fine     NUMERIC;
BEGIN
  SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
  FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
  END IF;
  IF v_returned IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
  END IF;
  IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date cannot be before borrowed date (%)', v_borrowed;
  END IF;
 
  v_fine := fn_loan_fine(p_loan_id, p_returned_on);
 
  UPDATE loans
  SET returned_on = p_returned_on,
      fine_amount = v_fine
  WHERE loan_id = p_loan_id;
END $$;

-- Test queries
CALL pr_return_loan(99, CURRENT_DATE);        -- ERROR: Unknown loan
CALL pr_return_loan(3, '2026-09-01');         -- ERROR: before borrowed date

-- (d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_loan_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  END IF;
  RETURN NEW;
END $$;
 
CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loan_audit_fn();

-- (a) continued: return two loans through the procedure
CALL pr_return_loan(3, '2026-10-20');   -- 5 days late  -> K10
CALL pr_return_loan(4, '2026-11-10');   -- on due date  -> K0

-- Test queries
SELECT loan_id, due_on, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;       -- two rows
CALL pr_return_loan(3, CURRENT_DATE);             -- ERROR: already returned
SELECT fn_loan_fine(3, CURRENT_DATE);             -- 10 (stops at return date)
SELECT fn_loan_fine(4, CURRENT_DATE);             -- 0
-- Unchanged date creates no audit row:
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;
SELECT COUNT(*) FROM loan_audit;                  -- still 2

-- (e) View [5 marks]
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- Test queries
SELECT * FROM v_overdue_loans;   -- Mwansa and Tembo

-- (f) Index [5 marks]
CREATE INDEX idx_loans_book_open ON loans (book_id)
WHERE returned_on IS NULL;
 
SET enable_seqscan = off;
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job [6 marks]
-- A loan counts as unreturned on p_as_of if it was borrowed by then and has no return date, or was returned after that date. 
-- Only overdue loans (due before p_as_of) are counted and fined.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
  SELECT p_as_of,
         COUNT(*),
         COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE borrowed_on <= p_as_of
    AND (returned_on IS NULL OR returned_on > p_as_of)
    AND due_on < p_as_of
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END $$;
 
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q3_refresh_overdue', '10 0 * * *',
  $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$);

-- Test queries
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces the same date
SELECT * FROM overdue_summary;
SELECT jobid, jobname, schedule, command FROM cron.job;
