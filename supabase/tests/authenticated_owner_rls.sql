-- Run with: supabase db query --linked --file supabase/tests/authenticated_owner_rls.sql
-- All fixtures and temporary grants roll back. No existing customer data is used.
begin;

create temporary table rls_ids as
select n as owner_index, gen_random_uuid() as auth_id, gen_random_uuid() as customer_id,
  gen_random_uuid() as sensor_id, gen_random_uuid() as reading_id,
  gen_random_uuid() as rule_id, gen_random_uuid() as agent_id,
  gen_random_uuid() as choice_id, gen_random_uuid() as clip_id,
  gen_random_uuid() as event_id, gen_random_uuid() as pairing_id,
  decode(md5(gen_random_uuid()::text), 'hex') as device_hash,
  decode(md5(gen_random_uuid()::text), 'hex') as session_hash,
  decode(md5(gen_random_uuid()::text), 'hex') as phone_pairing_hash,
  decode(md5(gen_random_uuid()::text), 'hex') as invite_hash
from generate_series(1, 3) n;

insert into auth.users(id) select auth_id from rls_ids;
insert into public.fizz_customers(id, username, auth_user_id)
select customer_id, 'rls_' || left(replace(customer_id::text, '-', ''), 16), auth_id
from rls_ids where owner_index <= 2;
insert into public.fizz_sensors(id, customer_id, kind, name, mode)
select sensor_id, customer_id, 'phone', 'RLS test sensor', 'phone'
from rls_ids where owner_index <= 2;
insert into public.fizz_sensor_readings(id, sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
select reading_id, sensor_id, 'rls-test', now(), 'temperature_c', 41, 'C', 'phone'
from rls_ids where owner_index <= 2;
insert into public.fizz_alert_rules(id, customer_id, sensor_id, metric, comparator, threshold, unit, enabled)
select rule_id, customer_id, sensor_id, 'temperature_c', 'gt', 40, 'C', false
from rls_ids where owner_index <= 2;
insert into public.fizz_alert_events(id, rule_id, reading_id, customer_id, sensor_id,
  metric, numeric_value, threshold, comparator, unit, observed_at)
select event_id, rule_id, reading_id, customer_id, sensor_id, 'temperature_c', 41, 40, 'gt', 'C', now()
from rls_ids where owner_index <= 2;
insert into public.fizz_phone_devices(token_hash, sensor_id, expires_at)
select device_hash, sensor_id, now() + interval '1 hour' from rls_ids where owner_index <= 2;
insert into public.fizz_phone_clips(id, sensor_id, device_hash, mime_type, audio)
select clip_id, sensor_id, device_hash, 'audio/webm', decode('00', 'hex')
from rls_ids where owner_index <= 2;
insert into public.fizz_phone_pairings(token_hash, customer_id, sensor_id, expires_at)
select phone_pairing_hash, customer_id, sensor_id, now() + interval '1 hour'
from rls_ids where owner_index <= 2;
insert into public.fizz_sessions(token_hash, customer_id, expires_at)
select session_hash, customer_id, now() + interval '1 hour' from rls_ids where owner_index <= 2;
insert into public.fizz_sensor_choices(id, customer_id, kind)
select choice_id, customer_id, 'phone' from rls_ids where owner_index <= 2;
insert into public.fizz_agent_connections(id, customer_id, name, token_hash)
select agent_id, customer_id, 'RLS test agent', decode(md5(agent_id::text), 'hex')
from rls_ids where owner_index <= 2;
insert into public.fizz_device_pairings(id, code_hash, poll_hash, device_name,
  customer_id, sensor_id, agent_id, expires_at)
select pairing_id, decode(md5(pairing_id::text), 'hex'), decode(md5(sensor_id::text), 'hex'),
  'RLS test device', customer_id, sensor_id, agent_id, now() + interval '1 hour'
from rls_ids where owner_index <= 2;
insert into public.fizz_invite_codes(code_hash, created_by, note)
select invite_hash, customer_id, 'RLS test invite' from rls_ids where owner_index <= 2;

-- Templates use a fixture owner index. Fresh keys avoid duplicate-key errors
-- hiding an INSERT policy failure. Customers use the third, unlinked Auth user.
create temporary table rls_cases(table_name text, key_column text, fixture_key text,
  update_clause text, owner_column text, owner_key text, insert_sql text);
insert into rls_cases values
  ('fizz_customers', 'id', 'customer_id', 'username = username', 'auth_user_id', 'auth_id',
    $sql$insert into public.fizz_customers(id, username, auth_user_id)
      select customer_id, 'rls_' || left(replace(customer_id::text, '-', ''), 16), auth_id
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_sessions', 'token_hash', 'session_hash', 'expires_at = expires_at', 'customer_id', 'customer_id',
    $sql$insert into public.fizz_sessions(token_hash, customer_id, expires_at)
      select decode(md5(gen_random_uuid()::text), 'hex'), customer_id, now() + interval '1 hour'
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_sensor_choices', 'id', 'choice_id', 'kind = kind', 'customer_id', 'customer_id',
    $sql$insert into public.fizz_sensor_choices(customer_id, kind)
      select customer_id, 'water' from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_sensors', 'id', 'sensor_id', 'name = name', 'customer_id', 'customer_id',
    $sql$insert into public.fizz_sensors(customer_id, kind, name)
      select customer_id, 'temperature', 'RLS inserted sensor' from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_sensor_readings', 'id', 'reading_id', 'numeric_value = numeric_value', 'sensor_id', 'sensor_id',
    $sql$insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, source)
      select sensor_id, gen_random_uuid()::text, now(), 'temperature_c', 25, 'phone'
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_phone_pairings', 'token_hash', 'phone_pairing_hash', 'expires_at = expires_at', 'customer_id', 'customer_id',
    $sql$insert into public.fizz_phone_pairings(token_hash, customer_id, sensor_id, expires_at)
      select decode(md5(gen_random_uuid()::text), 'hex'), customer_id, sensor_id, now() + interval '1 hour'
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_phone_devices', 'token_hash', 'device_hash', 'expires_at = expires_at', 'sensor_id', 'sensor_id',
    $sql$insert into public.fizz_phone_devices(token_hash, sensor_id, expires_at)
      select decode(md5(gen_random_uuid()::text), 'hex'), sensor_id, now() + interval '1 hour'
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_phone_clips', 'id', 'clip_id', 'mime_type = mime_type', 'sensor_id', 'sensor_id',
    $sql$insert into public.fizz_phone_clips(sensor_id, device_hash, mime_type, audio)
      select sensor_id, device_hash, 'audio/webm', decode('00', 'hex')
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_alert_rules', 'id', 'rule_id', 'threshold = threshold', 'customer_id', 'customer_id',
    $sql$insert into public.fizz_alert_rules(customer_id, sensor_id, metric, comparator, threshold, enabled)
      select customer_id, sensor_id, 'temperature_c', 'gt', 40, false
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_alert_events', 'id', 'event_id', 'threshold = threshold', 'customer_id', 'customer_id',
    $sql$insert into public.fizz_alert_events(rule_id, reading_id, customer_id, sensor_id,
        metric, numeric_value, threshold, comparator, unit, observed_at)
      select null, reading_id, customer_id, sensor_id, 'temperature_c', 41, 40, 'gt', 'C', now()
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_agent_connections', 'id', 'agent_id', 'name = name', 'customer_id', 'customer_id',
    $sql$insert into public.fizz_agent_connections(customer_id, name, token_hash)
      select customer_id, 'RLS inserted agent', decode(md5(gen_random_uuid()::text), 'hex')
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_device_pairings', 'id', 'pairing_id', 'device_name = device_name', 'customer_id', 'customer_id',
    $sql$insert into public.fizz_device_pairings(code_hash, poll_hash, device_name,
        customer_id, sensor_id, agent_id, expires_at)
      select decode(md5(gen_random_uuid()::text), 'hex'), decode(md5(gen_random_uuid()::text), 'hex'),
        'RLS inserted device', customer_id, sensor_id, agent_id, now() + interval '1 hour'
      from pg_temp.rls_ids where owner_index = %s$sql$),
  ('fizz_invite_codes', 'code_hash', 'invite_hash', 'note = note', 'created_by', 'customer_id',
    $sql$insert into public.fizz_invite_codes(code_hash, created_by, note)
      select decode(md5(gen_random_uuid()::text), 'hex'), customer_id, 'RLS inserted invite'
      from pg_temp.rls_ids where owner_index = %s$sql$);

create temporary table rls_results(label text);
grant select on rls_ids, rls_cases to authenticated, anon;
grant insert on rls_results to authenticated, anon;

create function pg_temp.rls_assert(p_sql text, p_expected bigint, p_label text, p_select boolean default false)
returns void language plpgsql security invoker as $$
declare v_actual bigint;
begin
  if p_select then execute p_sql into v_actual;
  else execute p_sql; get diagnostics v_actual = row_count;
  end if;
  if v_actual is distinct from p_expected then
    raise exception '%: expected %, got %', p_label, p_expected, v_actual;
  end if;
  insert into pg_temp.rls_results values (p_label);
end;
$$;

create function pg_temp.rls_denied(p_sql text, p_label text)
returns void language plpgsql security invoker as $$
begin
  begin
    execute p_sql;
  exception when insufficient_privilege then
    insert into pg_temp.rls_results values (p_label);
    return;
  end;
  raise exception '%: statement unexpectedly allowed', p_label;
end;
$$;

grant execute on function pg_temp.rls_assert(text,bigint,text,boolean), pg_temp.rls_denied(text,text) to authenticated, anon;

-- Exercise RLS itself, rather than merely observing table privilege failures.
-- These grants exist only for the transaction and are never deployed.
do $$
declare v_table text;
begin
  for v_table in select table_name from pg_temp.rls_cases loop
    execute format('grant select, insert, update, delete on public.%I to authenticated, anon', v_table);
  end loop;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', auth_id, 'role', 'authenticated',
  'is_anonymous', false)::text, true), set_config('request.jwt.claim.sub', auth_id::text, true)
from pg_temp.rls_ids where owner_index = 1;

do $$
declare v record; v_key text; v_foreign_key text; v_owner text; v_auth uuid;
begin
  for v in select * from pg_temp.rls_cases loop
    execute format('select %I::text from pg_temp.rls_ids where owner_index = 1', v.fixture_key) into v_key;
    execute format('select %I::text from pg_temp.rls_ids where owner_index = 2', v.fixture_key) into v_foreign_key;
    execute format('select %I::text from pg_temp.rls_ids where owner_index = 2', v.owner_key) into v_owner;
    perform pg_temp.rls_assert(format('select count(*) from public.%I where %I = %L',
      v.table_name, v.key_column, v_key), 1, v.table_name || ': select own', true);
    perform pg_temp.rls_assert(format('select count(*) from public.%I where %I = %L',
      v.table_name, v.key_column, v_foreign_key), 0, v.table_name || ': hide foreign', true);
    perform pg_temp.rls_assert(format('update public.%I set %s where %I = %L',
      v.table_name, v.update_clause, v.key_column, v_key), 1, v.table_name || ': update own');
    perform pg_temp.rls_assert(format('update public.%I set %s where %I = %L',
      v.table_name, v.update_clause, v.key_column, v_foreign_key), 0, v.table_name || ': cannot update foreign');
    perform pg_temp.rls_assert(format('delete from public.%I where %I = %L',
      v.table_name, v.key_column, v_foreign_key), 0, v.table_name || ': cannot delete foreign');
    perform pg_temp.rls_denied(format('update public.%I set %I = %L where %I = %L',
      v.table_name, v.owner_column, v_owner, v.key_column, v_key), v.table_name || ': cannot transfer owner');
    perform pg_temp.rls_denied(format(v.insert_sql, 2), v.table_name || ': cannot insert foreign');

    if v.table_name = 'fizz_customers' then
      select auth_id into v_auth from pg_temp.rls_ids where owner_index = 3;
      perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth, 'is_anonymous', false)::text, true);
      perform set_config('request.jwt.claim.sub', v_auth::text, true);
      perform pg_temp.rls_assert(format(v.insert_sql, 3), 1, v.table_name || ': insert own');
      select auth_id into v_auth from pg_temp.rls_ids where owner_index = 1;
      perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth, 'is_anonymous', false)::text, true);
      perform set_config('request.jwt.claim.sub', v_auth::text, true);
    else
      perform pg_temp.rls_assert(format(v.insert_sql, 1), 1, v.table_name || ': insert own');
    end if;
  end loop;
end;
$$;

-- The row's customer alone is insufficient: all related rows must match it.
do $$
declare v record; v_key text; v_foreign_key text;
begin
  for v in select * from (values
    ('fizz_phone_pairings', 'token_hash', 'phone_pairing_hash', 'sensor_id', 'sensor_id'),
    ('fizz_phone_clips', 'id', 'clip_id', 'device_hash', 'device_hash'),
    ('fizz_alert_rules', 'id', 'rule_id', 'sensor_id', 'sensor_id'),
    ('fizz_alert_events', 'id', 'event_id', 'sensor_id', 'sensor_id'),
    ('fizz_alert_events', 'id', 'event_id', 'reading_id', 'reading_id'),
    ('fizz_alert_events', 'id', 'event_id', 'rule_id', 'rule_id'),
    ('fizz_device_pairings', 'id', 'pairing_id', 'sensor_id', 'sensor_id'),
    ('fizz_device_pairings', 'id', 'pairing_id', 'agent_id', 'agent_id')
  ) as links(table_name, key_column, fixture_key, reference_column, foreign_key) loop
    execute format('select %I::text from pg_temp.rls_ids where owner_index = 1', v.fixture_key) into v_key;
    execute format('select %I::text from pg_temp.rls_ids where owner_index = 2', v.foreign_key) into v_foreign_key;
    perform pg_temp.rls_denied(format('update public.%I set %I = %L where %I = %L',
      v.table_name, v.reference_column, v_foreign_key, v.key_column, v_key),
      v.table_name || ': reject foreign ' || v.reference_column);
  end loop;
end;
$$;

-- Test Supabase anonymous sign-ins (which use the authenticated DB role),
-- missing identities, and the anon role even if a subject claim is present.
do $$
declare v record; v_mode integer; v_key text; v_auth uuid;
begin
  select auth_id into v_auth from pg_temp.rls_ids where owner_index = 1;
  for v_mode in 1..3 loop
    if v_mode = 1 then
      perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth, 'is_anonymous', true)::text, true);
    elsif v_mode = 2 then
      perform set_config('request.jwt.claims', '{}', true);
      perform set_config('request.jwt.claim.sub', '', true);
    else
      execute 'set local role anon';
      perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth, 'is_anonymous', false)::text, true);
      perform set_config('request.jwt.claim.sub', v_auth::text, true);
    end if;
    for v in select * from pg_temp.rls_cases loop
      execute format('select %I::text from pg_temp.rls_ids where owner_index = 1', v.fixture_key) into v_key;
      perform pg_temp.rls_assert(format('select count(*) from public.%I', v.table_name),
        0, v.table_name || ': unauthenticated select mode ' || v_mode, true);
      perform pg_temp.rls_assert(format('update public.%I set %s where %I = %L',
        v.table_name, v.update_clause, v.key_column, v_key),
        0, v.table_name || ': unauthenticated update mode ' || v_mode);
      perform pg_temp.rls_assert(format('delete from public.%I where %I = %L',
        v.table_name, v.key_column, v_key), 0, v.table_name || ': unauthenticated delete mode ' || v_mode);
      perform pg_temp.rls_denied(format(v.insert_sql, 1),
        v.table_name || ': unauthenticated insert mode ' || v_mode);
    end loop;
  end loop;
end;
$$;

reset role;
-- Delete in reverse dependency order; avoid foreign-key failures obscuring RLS.
set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', auth_id, 'is_anonymous', false)::text, true),
  set_config('request.jwt.claim.sub', auth_id::text, true)
from pg_temp.rls_ids where owner_index = 1;
do $$
declare v_table text;
begin
  foreach v_table in array array['fizz_alert_events', 'fizz_alert_rules', 'fizz_phone_clips',
    'fizz_device_pairings', 'fizz_phone_pairings', 'fizz_phone_devices', 'fizz_sensor_readings',
    'fizz_sensors', 'fizz_agent_connections', 'fizz_sessions', 'fizz_sensor_choices', 'fizz_invite_codes',
    'fizz_customers'] loop
    perform pg_temp.rls_assert(format('with removed as (delete from public.%I returning 1) select count(*) from removed',
      v_table), case when v_table = 'fizz_customers' then 1 else 2 end, v_table || ': delete own', true);
  end loop;
end;
$$;
reset role;

select count(*) as passed_assertions, 'Owner CRUD, foreign ownership, related IDs, anonymous users, missing JWT, and anon role' as coverage
from pg_temp.rls_results;
rollback;
