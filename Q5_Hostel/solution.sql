-- (a) Database and seed data [6 marks]
-- Room 101 is full (2 of 2), room 102 is partly occupied (1 of 3) and room 103 is empty. Student 4 has an ENDED allocation in room 103 (history), and student 5 has none.
DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path TO q5, public;
 
CREATE TABLE students (
  student_id      SERIAL PRIMARY KEY,
  student_number  VARCHAR(20) NOT NULL UNIQUE,
  full_name       VARCHAR(100) NOT NULL
);
 
CREATE TABLE rooms (
  room_id      SERIAL PRIMARY KEY,
  room_number  VARCHAR(10) NOT NULL UNIQUE,
  capacity     INT NOT NULL CHECK (capacity > 0)
);
 
CREATE TABLE allocations (
  allocation_id  SERIAL PRIMARY KEY,
  student_id     INT NOT NULL REFERENCES students(student_id),
  room_id        INT NOT NULL REFERENCES rooms(room_id),
  allocated_on   DATE NOT NULL,
  released_on    DATE,
  status         VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
  CONSTRAINT ck_status_release CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED'  AND released_on IS NOT NULL))
);
 
CREATE TABLE occupancy_snapshot (
  snapshot_date  DATE NOT NULL,
  room_id        INT NOT NULL REFERENCES rooms(room_id),
  occupied_beds  INT NOT NULL,
  free_beds      INT NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);
 
INSERT INTO students (student_number, full_name) VALUES
  ('H001', 'Mutale Chola'), ('H002', 'Bwalya Mulenga'),
  ('H003', 'Namukolo Hamoonga'), ('H004', 'Kelvin Sinkala'),
  ('H005', 'Esther Tembo');
 
INSERT INTO rooms (room_number, capacity) VALUES
  ('R101', 2), ('R102', 3), ('R103', 2);
 
INSERT INTO allocations
  (student_id, room_id, allocated_on, released_on, status) VALUES
  (1, 1, '2026-09-01', NULL,         'ACTIVE'),
  (2, 1, '2026-09-01', NULL,         'ACTIVE'),
  (3, 2, '2026-09-02', NULL,         'ACTIVE'),
  (4, 3, '2026-02-01', '2026-06-30', 'ENDED');

-- Test queries
SELECT * FROM allocations ORDER BY allocation_id;

-- (b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  v_cap    INT;
  v_active INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room: %', p_room_id;
  END IF;
  SELECT COUNT(*) INTO v_active
  FROM allocations WHERE room_id = p_room_id AND status = 'ACTIVE';
  RETURN v_cap - v_active;   -- ENDED rows are not counted
END $$;

-- Test queries
SELECT fn_free_beds(1);    -- 0
SELECT fn_free_beds(2);    -- 2
SELECT fn_free_beds(3);    -- 2 (the ENDED allocation does not count)
SELECT fn_free_beds(99);   -- ERROR: Unknown room

-- (c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_allocate_room(
  p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room: %', p_room_id;
  END IF;
  IF p_allocated_on IS NULL THEN
    RAISE EXCEPTION 'Allocation date is required';
  END IF;
  IF EXISTS (SELECT 1 FROM allocations
             WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % is full', p_room_id;
  END IF;
 
  INSERT INTO allocations (student_id, room_id, allocated_on,
                           released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- Test queries
CALL pr_allocate_room(5, 1, CURRENT_DATE);    -- ERROR: Room 1 is full
CALL pr_allocate_room(1, 2, CURRENT_DATE);    -- ERROR: already ACTIVE
CALL pr_allocate_room(99, 2, CURRENT_DATE);   -- ERROR: Unknown student
CALL pr_allocate_room(5, 99, CURRENT_DATE);   -- ERROR: Unknown room
CALL pr_allocate_room(5, 2, CURRENT_DATE);    -- OK (room 102 now 2 of 3)
CALL pr_allocate_room(4, 3, CURRENT_DATE);    -- OK (ended history does not block)

-- (d) Trigger [8 marks]
-- Enforces both rules for direct INSERT or UPDATE. The row being updated is excluded from both counts (allocation_id <> NEW.allocation_id). 
-- The room row is locked so simultaneous inserts cannot both take the last bed. ENDED rows skip the checks because they occupy nothing.
CREATE OR REPLACE FUNCTION trg_allocation_rules_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_cap    INT;
  v_in_use INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms
    WHERE room_id = NEW.room_id FOR UPDATE;
 
    IF EXISTS (SELECT 1 FROM allocations a
               WHERE a.student_id = NEW.student_id
                 AND a.status = 'ACTIVE'
                 AND a.allocation_id <> NEW.allocation_id) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation',
                      NEW.student_id;
    END IF;
 
    SELECT COUNT(*) INTO v_in_use FROM allocations a
    WHERE a.room_id = NEW.room_id
      AND a.status = 'ACTIVE'
      AND a.allocation_id <> NEW.allocation_id;
    IF v_in_use >= v_cap THEN
      RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_cap;
    END IF;
  END IF;
  RETURN NEW;
END $$;
 
CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_rules_fn();

-- Test queries
-- Direct SQL: second ACTIVE allocation for student 3
INSERT INTO allocations (student_id, room_id, allocated_on, status)
VALUES (3, 3, CURRENT_DATE, 'ACTIVE');                   -- ERROR
 
-- Direct SQL: room 1 is full (new student with no allocation)
INSERT INTO students (student_number, full_name) VALUES ('H006', 'Test Student');
INSERT INTO allocations (student_id, room_id, allocated_on, status)
VALUES (6, 1, CURRENT_DATE, 'ACTIVE');                   -- ERROR
 
-- Updating an ACTIVE row without changing room/student is fine
UPDATE allocations SET allocated_on = '2026-09-03'
WHERE allocation_id = 1;                                 -- OK
 
-- Ending an allocation frees a bed
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE
WHERE allocation_id = 1;
SELECT fn_free_beds(1);                                  -- 1

-- (e) View [5 marks]
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity
ORDER BY r.room_id;

-- Test queries
SELECT * FROM v_room_occupancy;

-- (f) Index [5 marks]
CREATE INDEX idx_alloc_active_room ON allocations (room_id)
WHERE status = 'ACTIVE';
 
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM allocations
WHERE room_id = 2 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot
    (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE,
         r.room_id,
         COUNT(a.allocation_id),
         r.capacity - COUNT(a.allocation_id)
  FROM rooms r
  LEFT JOIN allocations a
         ON a.room_id = r.room_id AND a.status = 'ACTIVE'
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END $$;
 
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q5_refresh_occupancy', '55 23 * * *',
  $$CALL q5.pr_refresh_occupancy()$$);

-- Test queries
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun replaces values, no duplicate rows
SELECT * FROM occupancy_snapshot ORDER BY room_id;
SELECT jobid, jobname, schedule, command FROM cron.job;
