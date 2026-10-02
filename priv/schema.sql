CREATE TABLE IF NOT EXISTS atheum_invocations (
 invocation_id text PRIMARY KEY,
 execution_id text NOT NULL UNIQUE,
 acceptance_key text NOT NULL UNIQUE,
 request jsonb NOT NULL,
 status text NOT NULL CHECK(status IN ('accepted','running','succeeded','failed','stopped','unresolved')),
 attempt_id text,
 generation integer NOT NULL DEFAULT 0,
 cancel_requested boolean NOT NULL DEFAULT false,
 stop_confirmed boolean NOT NULL DEFAULT false,
 effect_certainty text NOT NULL DEFAULT 'not_started',
 result jsonb,
 error jsonb,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS atheum_events (
 sequence bigserial PRIMARY KEY,
 invocation_id text NOT NULL REFERENCES atheum_invocations(invocation_id),
 attempt_id text,
 kind text NOT NULL,
 data jsonb NOT NULL,
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS atheum_worker_slots (
 slot text PRIMARY KEY CHECK(slot='local'),
 owner_token text NOT NULL,
 owner_vm text NOT NULL,
 invocation_id text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS atheum_worker_instances (
 instance_name text PRIMARY KEY,
 instance_generation bigserial UNIQUE,
 owner_token text NOT NULL,
 invocation_id text NOT NULL,
 execution_id text NOT NULL,
 attempt_id text NOT NULL,
 job_generation integer NOT NULL,
 image_id text NOT NULL,
 container_id text UNIQUE,
 phase text NOT NULL,
 observations jsonb NOT NULL DEFAULT '[]'::jsonb,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
