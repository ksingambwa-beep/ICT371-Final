-- (a) Database and seed data [6 marks] Creates the schema, four tables with keys and CHECK constraints (positive price, non-negative stock) and four medicines. 
-- The six sales are loaded in "(a) continued", after the procedure and trigger exist.

DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path TO q1, public;
 
CREATE TABLE medicines (
  medicine_id    SERIAL PRIMARY KEY,
  medicine_name  VARCHAR(100) NOT NULL,
  unit_price     NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty      INT NOT NULL CHECK (stock_qty >= 0)
);
 
CREATE TABLE sales (
  sale_id      SERIAL PRIMARY KEY,
  medicine_id  INT NOT NULL REFERENCES medicines(medicine_id),
  quantity     INT NOT NULL CHECK (quantity > 0),
  unit_price   NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on      DATE NOT NULL
);
 
CREATE TABLE stock_audit (
  audit_id     SERIAL PRIMARY KEY,
  medicine_id  INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty      INT NOT NULL,
  new_qty      INT NOT NULL,
  changed_at   TIMESTAMP NOT NULL DEFAULT now()
);
 
CREATE TABLE daily_sales (
  sales_date    DATE PRIMARY KEY,
  total_qty     INT NOT NULL,
  total_amount  NUMERIC(12,2) NOT NULL
);
 
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
  ('Paracetamol', 5.00, 100),
  ('Amoxicillin', 12.50, 50),
  ('ORS Sachet',   3.00, 12),
  ('Ibuprofen',    8.00, 30);
-- Test queries
SELECT * FROM medicines;

-- (b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
  v_price NUMERIC;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  SELECT unit_price INTO v_price
  FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;
  RETURN v_price * p_quantity;
END $$;

-- Test queries
SELECT fn_sale_value(1, 3);   -- 15.00
SELECT fn_sale_value(99, 1);  -- ERROR: Unknown medicine
SELECT fn_sale_value(1, 0);   -- ERROR: Invalid quantity

-- (c) Procedure [8 marks]
-- The whole CALL is one transaction, so any exception rolls back both the sale insert and the stock deduction. 
-- FOR UPDATE locks the medicine row so two sales cannot oversell. Stock is deducted once, in one UPDATE.
CREATE OR REPLACE PROCEDURE pr_record_sale(
  p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
  v_price NUMERIC;
  v_stock INT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'Sale date is required';
  END IF;
 
  SELECT unit_price, stock_qty INTO v_price, v_stock
  FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: available %, requested %',
                    v_stock, p_quantity;
  END IF;
 
  INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
 
  UPDATE medicines SET stock_qty = stock_qty - p_quantity
  WHERE medicine_id = p_medicine_id;
END $$;

-- Test queries
CALL pr_record_sale(3, 999, CURRENT_DATE);  -- ERROR: Insufficient stock
CALL pr_record_sale(99, 1, CURRENT_DATE);   -- ERROR: Unknown medicine
CALL pr_record_sale(1, 0, CURRENT_DATE);    -- ERROR: Invalid quantity
SELECT medicine_id, stock_qty FROM medicines ORDER BY 1;  -- unchanged
SELECT COUNT(*) FROM sales;                               

-- (d) Trigger [8 marks]
-- Fires AFTER UPDATE for each row and writes to stock_audit only when stock_qty really changes.
CREATE OR REPLACE FUNCTION trg_stock_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  END IF;
  RETURN NEW;
END $$;
 
CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_stock_audit_fn();

-- Test queries
UPDATE medicines SET medicine_name = 'Paracetamol 500mg' WHERE medicine_id = 1;
SELECT COUNT(*) FROM stock_audit;   -- 0 (stock did not change)
UPDATE medicines SET medicine_name = 'Paracetamol' WHERE medicine_id = 1;

-- (a) continued: load six sales through the procedure
CALL pr_record_sale(1, 10, '2026-11-21');
CALL pr_record_sale(2,  5, '2026-11-21');
CALL pr_record_sale(3,  4, '2026-11-22');
CALL pr_record_sale(1, 20, '2026-11-22');
CALL pr_record_sale(4,  6, '2026-11-23');
CALL pr_record_sale(3,  2, '2026-11-23');

-- Test queries
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM stock_audit ORDER BY audit_id;   -- one row per sale

-- (e) View [5 marks]
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

-- Test queries
SELECT * FROM v_low_stock;                 -- ORS Sachet (6 left)
CALL pr_record_sale(2, 41, '2026-11-24');  -- Amoxicillin drops to 4
SELECT * FROM v_low_stock;                 -- now two rows

-- (f) Index [5 marks]
CREATE INDEX idx_sales_med_date ON sales (medicine_id, sold_on);
 
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- (g) Scheduled job [6 marks]
-- The INSERT ... ON CONFLICT DO UPDATE replaces the day's row, so a rerun never duplicates or double-counts. 
-- Totals are recalculated from sales every time.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_sales (sales_date, total_qty, total_amount)
  SELECT p_day,
         COALESCE(SUM(quantity), 0),
         COALESCE(SUM(quantity * unit_price), 0)
  FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END $$;
 
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q1_refresh_sales', '15 0 * * *',
  $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$);

-- Test queries
CALL pr_refresh_sales('2026-11-21');
CALL pr_refresh_sales('2026-11-21');   -- rerun: same totals
SELECT * FROM daily_sales;
SELECT jobid, jobname, schedule, command FROM cron.job;
