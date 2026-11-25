-- (a) Database and seed data [6 marks]
-- The trigger is installed before deliveries are loaded (see "(a) continued").
-- Two deliveries come from the procedure (unpaid), four from direct INSERTs (paid), covering all grades and both payment states.
DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path TO q9, public;
 
CREATE TABLE farmers (
  farmer_id      SERIAL PRIMARY KEY,
  farmer_number  VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
 
CREATE TABLE deliveries (
  delivery_id   SERIAL PRIMARY KEY,
  farmer_id     INT NOT NULL REFERENCES farmers(farmer_id),
  grade         CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
  weight_kg     NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
  unit_rate     NUMERIC(10,2) NOT NULL,
  total_value   NUMERIC(12,2) NOT NULL,
  delivered_on  DATE NOT NULL,
  is_paid       BOOLEAN NOT NULL DEFAULT FALSE
);
 
CREATE TABLE daily_purchases (
  purchase_date  DATE PRIMARY KEY,
  total_weight   NUMERIC(12,2) NOT NULL,
  total_value    NUMERIC(14,2) NOT NULL
);
 
INSERT INTO farmers (farmer_number, full_name) VALUES
  ('F001', 'Moses Shamwana'), ('F002', 'Agnes Mutinta'), ('F003', 'Joseph Haankuku');

-- Test queries
SELECT * FROM farmers;

-- (b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade is required';
  END IF;
  CASE p_grade
    WHEN 'A' THEN RETURN 5.00;
    WHEN 'B' THEN RETURN 4.00;
    WHEN 'C' THEN RETURN 3.00;
    ELSE RAISE EXCEPTION 'Unsupported grade: %', p_grade;
  END CASE;
END $$;

-- Test queries
SELECT fn_maize_rate('A'), fn_maize_rate('B'), fn_maize_rate('C');  -- 5, 4, 3
SELECT fn_maize_rate('D');    -- ERROR: Unsupported grade
SELECT fn_maize_rate(NULL);   -- ERROR: Grade is required

-- (c) Procedure [8 marks]
-- Inserts only the basic fields and is_paid = FALSE. unit_rate and total_value are filled in by the trigger.
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
  p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
    RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
  END IF;
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive';
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Delivery date is required';
  END IF;
  PERFORM fn_maize_rate(p_grade);   -- rejects NULL or unsupported grades
 
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- Test queries
CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);   -- ERROR: Unknown farmer
CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);    -- ERROR: Unsupported grade
CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);    -- ERROR: weight

-- (d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION trg_delivery_price_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive';
  END IF;
  NEW.unit_rate   := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END $$;
 
CREATE TRIGGER trg_delivery_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_price_fn();

-- (a) continued: load six deliveries
-- Direct SQL (paid): trigger supplies unit_rate and total_value
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
  (1, 'B',  50.5, '2026-11-21', TRUE),
  (2, 'A',  80,   '2026-11-22', TRUE),
  (3, 'B', 120,   '2026-11-22', TRUE),
  (3, 'C',  60,   '2026-11-23', TRUE);
 
-- Through the procedure (unpaid)
CALL pr_receive_delivery(1, 'A', 100, '2026-11-20');
CALL pr_receive_delivery(2, 'C', 200, '2026-11-21');

-- Test queries
SELECT * FROM deliveries ORDER BY delivery_id;
 
-- Direct SQL cannot bypass the rule:
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value,
                        delivered_on)
VALUES (1, 'A', 10, 1.00, 1.00, CURRENT_DATE);   -- stored as 5.00 / 50.00
SELECT unit_rate, total_value FROM deliveries ORDER BY delivery_id DESC LIMIT 1;
DELETE FROM deliveries WHERE delivery_id = 7;    -- remove the test row

-- (e) View [5 marks]
-- The unpaid condition is in the join (not the WHERE clause), so farmers with no unpaid deliveries still appear with zero.
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name
ORDER BY f.farmer_number;

-- Test queries
SELECT * FROM v_farmer_amount_due;   -- F001 500, F002 600, F003 0

-- (f) Index [5 marks]
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
 
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- (g) Scheduled job [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END $$;
 
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q9_refresh_purchases', '30 1 * * *',
  $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$);

-- Test queries
CALL pr_refresh_purchases('2026-11-21');
CALL pr_refresh_purchases('2026-11-21');   -- rerun replaces, not adds
SELECT * FROM daily_purchases;             -- 250.50 kg, 802.00 (50.5*4 + 200*3)
SELECT jobid, jobname, schedule, command FROM cron.job;

