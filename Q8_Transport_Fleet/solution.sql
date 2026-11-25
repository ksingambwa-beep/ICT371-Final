-- (a) Database and seed data [6 marks]
-- Vehicle 1 is 2,000 km since service (not due), vehicle 2 is 6,000 km (due) and vehicle 3 is exactly 5,000 km (due).
-- Trips are added through the procedure after the trigger is installed ("(a) continued").
DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path TO q8, public;
 
CREATE TABLE vehicles (
  vehicle_id             SERIAL PRIMARY KEY,
  registration           VARCHAR(20) NOT NULL UNIQUE,
  current_odometer       INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer  INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT ck_service_not_ahead
    CHECK (last_service_odometer <= current_odometer)
);
 
CREATE TABLE trips (
  trip_id         SERIAL PRIMARY KEY,
  vehicle_id      INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on         DATE NOT NULL,
  start_odometer  INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer    INT NOT NULL CHECK (end_odometer >= 0)
);
 
CREATE TABLE service_alerts (
  vehicle_id        INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service  INT NOT NULL,
  flagged_on        DATE NOT NULL
);
 
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
  ('BAE 1234', 12000, 10000),
  ('ALM 5678', 30000, 24000),
  ('BCK 9012',  8000,  3000);

-- Test queries
SELECT * FROM vehicles;

-- (b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
  v_km INT;
BEGIN
  SELECT current_odometer - last_service_odometer INTO v_km
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;
  RETURN v_km >= 5000;
END $$;

-- Test queries
SELECT fn_service_due(1);    -- false
SELECT fn_service_due(2);    -- true
SELECT fn_service_due(3);    -- true (exactly 5000)
SELECT fn_service_due(99);   -- ERROR: Unknown vehicle

-- (c) Procedure [8 marks]
Only validates and inserts the trip. It does not update the vehicle odometer; the trigger does that.
CREATE OR REPLACE PROCEDURE pr_record_trip(
  p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;
  IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
    RAISE EXCEPTION 'Trip date and odometer values are required';
  END IF;
  IF p_end <= p_start THEN
    RAISE EXCEPTION 'End odometer (%) must be greater than start (%)',
                    p_end, p_start;
  END IF;
 
  INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- Test queries
CALL pr_record_trip(99, CURRENT_DATE, 100, 200);     -- ERROR: Unknown vehicle
CALL pr_record_trip(1, CURRENT_DATE, 12000, 12000);  -- ERROR: end not greater

-- (d) Trigger [8 marks]
-- BEFORE INSERT. The vehicle row is locked, the start odometer must equal the current value, the mileage must be valid, then current_odometer is set to the trip end once. 
-- If the insert later fails, the whole statement (including this update) is rolled back.
CREATE OR REPLACE FUNCTION trg_trip_odometer_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_current INT;
BEGIN
  SELECT current_odometer INTO v_current
  FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
  END IF;
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: end (%) must exceed start (%)',
                    NEW.end_odometer, NEW.start_odometer;
  END IF;
  IF NEW.start_odometer <> v_current THEN
    RAISE EXCEPTION 'Trip must start at current odometer % (got %)',
                    v_current, NEW.start_odometer;
  END IF;
 
  UPDATE vehicles SET current_odometer = NEW.end_odometer
  WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END $$;
 
CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer_fn();

-- (a) continued: add six trips through the procedure
CALL pr_record_trip(1, '2026-11-18', 12000, 12150);
CALL pr_record_trip(1, '2026-11-20', 12150, 12400);
CALL pr_record_trip(2, '2026-11-18', 30000, 30200);
CALL pr_record_trip(2, '2026-11-21', 30200, 30500);
CALL pr_record_trip(3, '2026-11-19',  8000,  8100);
CALL pr_record_trip(3, '2026-11-22',  8100,  8300);

-- Test queries
SELECT * FROM trips ORDER BY trip_id;
SELECT vehicle_id, current_odometer FROM vehicles ORDER BY 1;  -- 12400/30500/8300
CALL pr_record_trip(1, CURRENT_DATE, 5000, 5100);  -- ERROR: wrong start odometer
SELECT current_odometer FROM vehicles WHERE vehicle_id = 1;   -- unchanged

-- (e) View [5 marks]
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- Test queries
SELECT * FROM v_service_due;   -- ALM 5678 (6500) and BCK 9012 (5300)

-- (f) Index [5 marks]
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
 
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- (g) Scheduled job [6 marks]
-- Upserts an alert for every due vehicle (keeping the original flagged_on date) and deletes alerts for vehicles that are no longer due.
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;
 
  DELETE FROM service_alerts
  WHERE vehicle_id NOT IN (
    SELECT vehicle_id FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000);
END $$;
 
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q8_refresh_service_alerts', '0 6 * * 1',
  $$CALL q8.pr_refresh_service_alerts()$$);

-- Test queries
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;        -- vehicles 2 and 3
 
-- Service vehicle 2, then refresh: its alert is removed
UPDATE vehicles SET last_service_odometer = current_odometer
WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;        -- vehicle 3 only
SELECT jobid, jobname, schedule, command FROM cron.job;
