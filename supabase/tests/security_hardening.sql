-- Uses synthetic users only. All changes, grants and test objects roll back.
begin;
create temporary table security_results(label text);
create function pg_temp.security_assert(ok boolean, label text) returns void
language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'Security assertion failed: %', label; end if;
  insert into pg_temp.security_results values(label);
end $$;

create temporary table security_ids as
select n, gen_random_uuid() auth_id, gen_random_uuid() customer_id, gen_random_uuid() sensor_id,
  gen_random_uuid() phone_id, gen_random_uuid() agent_id, gen_random_uuid() pairing_id,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) token,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) second_token,
  'fizz_' || md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) api_key,
  md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text) phone_token
from generate_series(1, 2) n;
insert into auth.users(id, email, encrypted_password, is_anonymous)
select auth_id, 'audit-' || auth_id || '@example.invalid', 'old-password-hash', false from security_ids;
insert into public.fizz_customers(id, auth_user_id, username)
select customer_id, auth_id, 'audit_' || left(replace(customer_id::text, '-', ''), 16) from security_ids;
insert into public.fizz_sessions(token_hash, customer_id, expires_at)
select extensions.digest(decode(token, 'hex'), 'sha256'), customer_id, now() + interval '1 hour' from security_ids
union all
select extensions.digest(decode(second_token, 'hex'), 'sha256'), customer_id, now() + interval '1 hour' from security_ids;
insert into public.fizz_sensors(id, customer_id, kind, name, mode, api_key_hash)
select sensor_id, customer_id, 'custom', 'Security fixture', 'api', extensions.digest(api_key, 'sha256') from security_ids
union all
select phone_id, customer_id, 'phone', 'Security fixture phone', 'phone', null from security_ids;
insert into public.fizz_phone_devices(token_hash, sensor_id, expires_at)
select extensions.digest(decode(phone_token, 'hex'), 'sha256'), phone_id, now() + interval '1 hour' from security_ids;
insert into public.fizz_agent_connections(id, customer_id, name, token_hash)
select agent_id, customer_id, 'Security fixture agent', extensions.digest(token, 'sha256') from security_ids;
insert into public.fizz_device_pairings(id, code_hash, poll_hash, device_name, status, customer_id, expires_at)
select pairing_id, extensions.digest(token, 'sha256'), extensions.digest(second_token, 'sha256'),
  'Security fixture pairing', 'claimed', customer_id, now() + interval '1 hour' from security_ids;
insert into public.fizz_phone_pairings(token_hash, customer_id, sensor_id, expires_at)
select extensions.digest(token, 'sha256'), customer_id, phone_id, now() + interval '1 hour' from security_ids;

-- Exercise service-role RPCs through their real permission boundary.
grant execute on function pg_temp.security_assert(boolean,text) to service_role;
grant select on security_ids to service_role;
grant insert on security_results to service_role;
set local role service_role;
do $$ declare a record; b record; result jsonb; i integer; begin
  select * into a from pg_temp.security_ids where n=1;
  select * into b from pg_temp.security_ids where n=2;
  perform pg_temp.security_assert(public.fizz_session_customer(a.token) = a.customer_id, 'valid session');
  perform pg_temp.security_assert(public.fizz_session_customer(null) is null, 'missing session denied');
  perform pg_temp.security_assert(public.fizz_session_customer('junk') is null, 'malformed session denied');
  perform pg_temp.security_assert(public.fizz_session_customer(repeat('0',64)) is null, 'unknown session denied');
  perform pg_temp.security_assert(public.fizz_request_budget('junk', 'chat')->>'error' = 'unauthorized', 'budget authenticates session');
  perform pg_temp.security_assert(public.fizz_request_budget(a.token, 'unknown')->>'error' = 'invalid_operation', 'budget operation allowlist');
  for i in 1..20 loop
    perform pg_temp.security_assert(public.fizz_request_budget(a.token, 'chat')->>'ok' = 'true', 'chat within minute budget ' || i);
  end loop;
  perform pg_temp.security_assert(public.fizz_request_budget(a.token, 'chat')->>'error' = 'rate_limited', 'chat over minute budget');
  perform pg_temp.security_assert(public.fizz_request_budget(a.second_token, 'chat')->>'error' = 'rate_limited', 'rotated session cannot reset budget');
  perform pg_temp.security_assert(public.fizz_request_budget(b.token, 'chat')->>'ok' = 'true', 'budget isolates customers');
  perform pg_temp.security_assert(public.fizz_request_budget(a.token, 'voice')->>'ok' = 'true', 'voice has separate budget');
  result := public.fizz_ingest_event(a.sensor_id, a.api_key, 'good-event', now(), '{"temperature_c":22}'::jsonb);
  perform pg_temp.security_assert(result ? 'accepted', 'correct sensor credential accepted');
  result := public.fizz_ingest_event(a.sensor_id, b.api_key, 'foreign-event', now(), '{"temperature_c":22}'::jsonb);
  perform pg_temp.security_assert(result->>'error' = 'unauthorized', 'foreign sensor credential denied');
  result := public.fizz_ingest_event(a.sensor_id, null, 'missing-event', now(), '{"temperature_c":22}'::jsonb);
  perform pg_temp.security_assert(result->>'error' = 'unauthorized', 'missing sensor credential denied');
  perform pg_temp.security_assert(public.fizz_phone_reading(a.phone_token, 'phone-good', 'acceleration_x', 1, 'm/s²')->>'ok' = 'true', 'valid phone credential accepted');
  perform pg_temp.security_assert(public.fizz_phone_reading(repeat('0',64), 'phone-bad', 'acceleration_x', 1, 'm/s²')->>'error' = 'unauthorized', 'unknown phone credential denied');
end $$;
reset role;

-- Regression: SQL NULL used to make a sensor with no key accept any shaped key.
update public.fizz_sensors set api_key_hash = null where id = (select sensor_id from security_ids where n=1);
select pg_temp.security_assert(
  public.fizz_ingest_event(sensor_id, api_key, 'null-key-event', now(), '{"temperature_c":22}')->>'error' = 'unauthorized',
  'NULL stored sensor key fails closed') from security_ids where n=1;
update public.fizz_sensors set api_key_hash = extensions.digest(api_key, 'sha256') from security_ids where id = sensor_id;

-- Fast-forward budgets using only fixture keys, including the hourly limit.
update public.fizz_rate_limits set hits = 200 where bucket='paid_chat_hour'
  and subject_hash=extensions.digest((select customer_id::text from security_ids where n=2), 'sha256');
select pg_temp.security_assert(public.fizz_request_budget(token, 'chat')->>'error' = 'rate_limited', 'hourly paid budget') from security_ids where n=2;
update public.fizz_rate_limits set hits=1200 where bucket='ingest_sensor'
  and subject_hash=extensions.digest((select sensor_id::text from security_ids where n=1), 'sha256');
select pg_temp.security_assert(public.fizz_ingest_event(sensor_id, api_key, 'limited', now(), '{"temperature_c":22}')->>'error' = 'rate_limited', 'sensor upload budget') from security_ids where n=1;
update public.fizz_rate_limits set hits=1200 where bucket='fizz_phone_reading'
  and subject_hash=extensions.digest((select phone_id::text from security_ids where n=1), 'sha256');
select pg_temp.security_assert(public.fizz_phone_reading(phone_token, 'limited', 'acceleration_x', 1, 'm/s²')->>'error' = 'rate_limited', 'phone upload budget') from security_ids where n=1;

-- Metadata updates retain sessions, while credential changes invalidate every session.
update auth.users set raw_user_meta_data = '{"audit":true}' where id = (select auth_id from security_ids where n=1);
select pg_temp.security_assert(public.fizz_session_customer(token) = customer_id, 'metadata update preserves session') from security_ids where n=1;
update auth.users set encrypted_password = 'new-password-hash' where id = (select auth_id from security_ids where n=1);
select pg_temp.security_assert(not exists(select 1 from public.fizz_sessions s where s.customer_id = i.customer_id), 'password change removes all sessions') from security_ids i where n=1;
select pg_temp.security_assert(public.fizz_session_customer(token) = customer_id, 'password change isolates other customers') from security_ids where n=2;
insert into public.fizz_sessions(token_hash, customer_id, expires_at)
select extensions.digest(decode(token, 'hex'), 'sha256'), customer_id, now() + interval '1 hour' from security_ids where n=1;
update auth.users set email = 'changed-' || id || '@example.invalid' where id = (select auth_id from security_ids where n=1);
select pg_temp.security_assert(public.fizz_session_customer(token) is null, 'email change invalidates session') from security_ids where n=1;

update auth.users set banned_until = now() + interval '1 day' where id = (select auth_id from security_ids where n=2);
select pg_temp.security_assert(public.fizz_session_customer(token) is null, 'ban invalidates session') from security_ids where n=2;
select pg_temp.security_assert(public.fizz_oauth_sign_in(auth_id, 'audit@example.invalid', null, '127.0.0.1')->>'error' = 'unavailable', 'ban prevents new Fizz session') from security_ids where n=2;
select pg_temp.security_assert(s.api_key_hash is null and s.status='paused', 'ban revokes sensor keys') from security_ids i join public.fizz_sensors s on s.id=i.sensor_id where n=2;
select pg_temp.security_assert(d.revoked_at is not null, 'ban revokes phone devices') from security_ids i join public.fizz_phone_devices d on d.sensor_id=i.phone_id where n=2;
select pg_temp.security_assert(a.revoked_at is not null, 'ban revokes agents') from security_ids i join public.fizz_agent_connections a on a.id=i.agent_id where n=2;
select pg_temp.security_assert(p.status='rejected', 'ban rejects pending pairing') from security_ids i join public.fizz_device_pairings p on p.id=i.pairing_id where n=2;
select pg_temp.security_assert(not exists(select 1 from public.fizz_phone_pairings p where p.customer_id=i.customer_id), 'ban deletes phone pairing links') from security_ids i where n=2;

select pg_temp.security_assert(not exists(
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and (p.proname like 'fizz_%' or p.proname='rls_auto_enable')
    and (has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE'))
), 'no client-executable privileged functions');
select pg_temp.security_assert(not has_schema_privilege('anon','public','CREATE') and not has_schema_privilege('authenticated','public','CREATE'), 'clients cannot create exposed objects');
create table public.fizz_audit_default_grants(id integer);
create function public.fizz_audit_default_grants() returns boolean language sql as $$ select true $$;
select pg_temp.security_assert(not has_table_privilege('anon','public.fizz_audit_default_grants','SELECT') and not has_table_privilege('authenticated','public.fizz_audit_default_grants','INSERT'), 'future tables default deny clients');
select pg_temp.security_assert(not has_function_privilege('anon','public.fizz_audit_default_grants()','EXECUTE') and not has_function_privilege('authenticated','public.fizz_audit_default_grants()','EXECUTE'), 'future functions default deny clients');
select count(*) as security_assertions_passed from security_results;
rollback;
