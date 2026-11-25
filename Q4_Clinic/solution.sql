-- (a) Database and seed data [6 marks]
-- Dates in the seed data are relative to CURRENT_DATE so today's view always has rows. The seed data was checked against the slot rule before the trigger was added.
DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path TO q4, public;
 
CREATE TABLE patients (
  patient_id  SERIAL PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);
 
CREATE TABLE doctors (
  doctor_id   SERIAL PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);
 
CREATE TABLE appointments (
  appointment_id   SERIAL PRIMARY KEY,
  patient_id       INT NOT NULL REFERENCES patients(patient_id),
  doctor_id        INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_day  DATE NOT NULL,
  slot_time        TIME NOT NULL
    CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
  status           VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
    CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);
 
CREATE TABLE clinic_summary (
  summary_date     DATE PRIMARY KEY,
  booked_count     INT NOT NULL,
  attended_count   INT NOT NULL,
  cancelled_count  INT NOT NULL
);
 
INSERT INTO patients (full_name) VALUES
  ('Natasha Lungu'), ('Joseph Daka'), ('Mercy Sakala');
INSERT INTO doctors (full_name) VALUES
  ('Dr. Mumba'), ('Dr. Kunda'), ('Dr. Zimba');
 
INSERT INTO appointments
  (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
  (1, 1, CURRENT_DATE - 2, '09:00', 'ATTENDED'),
  (2, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED'),
  (3, 2, CURRENT_DATE - 1, '09:00', 'CANCELLED'),
  (1, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
  (2, 3, CURRENT_DATE,     '10:00', 'BOOKED'),
  (3, 1, CURRENT_DATE + 1, '11:00', 'BOOKED');

-- Test queries
SELECT * FROM appointments ORDER BY appointment_id;

-- (b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  v_count INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM appointments
  WHERE doctor_id = p_doctor_id
    AND appointment_day = p_day
    AND status <> 'CANCELLED';
  RETURN v_count;   -- COUNT gives 0 when there are no bookings
END $$;

-- Test queries
SELECT fn_daily_load(2, CURRENT_DATE);        -- 1
SELECT fn_daily_load(1, CURRENT_DATE + 30);   -- 0
SELECT fn_daily_load(99, CURRENT_DATE);       -- ERROR: Unknown doctor

-- (c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_book_appointment(
  p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
    RAISE EXCEPTION 'Unknown patient: %', p_patient_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;
  IF p_day IS NULL OR p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Appointment date cannot be in the past';
  END IF;
  IF p_slot IS NULL OR p_slot NOT IN
     (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
    RAISE EXCEPTION 'Unsupported slot: %', p_slot;
  END IF;
 
  INSERT INTO appointments (patient_id, doctor_id, appointment_day,
                            slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END $$;

-- Test queries
CALL pr_book_appointment(1, 1, CURRENT_DATE + 2, '12:00');   -- OK
CALL pr_book_appointment(99, 1, CURRENT_DATE + 2, '12:00');  -- ERROR: patient
CALL pr_book_appointment(1, 99, CURRENT_DATE + 2, '12:00');  -- ERROR: doctor
CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '12:00');   -- ERROR: past date
CALL pr_book_appointment(1, 1, CURRENT_DATE + 2, '13:30');   -- ERROR: slot

-- (d) Trigger [8 marks]
-- On UPDATE the row being changed is excluded from the clash search (appointment_id <> NEW.appointment_id), otherwise it would clash with itself. 
-- Cancelled rows never clash. The partial unique index is an extra safety net for simultaneous sessions; the trigger raises its friendlier message first.
CREATE OR REPLACE FUNCTION trg_appointment_clash_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' THEN
    IF EXISTS (
      SELECT 1 FROM appointments a
      WHERE a.doctor_id       = NEW.doctor_id
        AND a.appointment_day = NEW.appointment_day
        AND a.slot_time       = NEW.slot_time
        AND a.status         <> 'CANCELLED'
        AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
    ) THEN
      RAISE EXCEPTION 'Doctor % is already booked on % at %',
                      NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
  END IF;
  RETURN NEW;
END $$;
 
CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointment_clash_fn();
 
CREATE UNIQUE INDEX uq_active_slot
ON appointments (doctor_id, appointment_day, slot_time)
WHERE status <> 'CANCELLED';

-- Test queries
-- Clash on INSERT (doctor 2 already has 09:00 today)
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time)
VALUES (2, 2, CURRENT_DATE, '09:00');                 -- ERROR
 
-- Clash on UPDATE (moving appointment 5 onto doctor 2 at 09:00)
UPDATE appointments SET doctor_id = 2, slot_time = '09:00'
WHERE appointment_id = 5;                             -- ERROR
 
-- Updating a row without creating a clash is allowed (no self-clash)
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 4;  -- OK
 
-- A cancelled slot can be rebooked
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time)
VALUES (2, 2, CURRENT_DATE - 1, '09:00');             -- OK

-- (e) View [5 marks]
-- Only the names and slot are exposed. No patient IDs, contact or other patient columns are included.
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id,
       p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time;

-- Test queries
SELECT * FROM v_today_appointments;

-- (f) Index [5 marks]
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);
 
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments
WHERE appointment_day = CURRENT_DATE AND doctor_id = 2;
RESET enable_seqscan;

-- (g) Scheduled job [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary
    (summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM appointments
  WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END $$;
 
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q4_refresh_clinic_summary', '0 1 * * *',
  $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

-- Test queries
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces the row
SELECT * FROM clinic_summary;
SELECT jobid, jobname, schedule, command FROM cron.job;
