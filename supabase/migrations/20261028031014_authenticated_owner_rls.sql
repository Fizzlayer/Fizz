-- Fizz's server uses service_role and checks its own session tokens. Keep the
-- existing table grants and server-only RPCs unchanged. These policies also
-- enforce ownership if authenticated Data API access is granted in the future.
-- A customer's UUID differs from auth.uid(): resolve it via auth_user_id.

-- This ownership column already exists on the linked project. Record it here
-- so a fresh database gets the same invite ownership rules.
alter table public.fizz_invite_codes
  add column if not exists created_by uuid references public.fizz_customers(id) on delete set null;

do $migration$
declare
  v_table text;
  v_owner text;
  v_policy text;
  v_authenticated constant text := $predicate$
    coalesce((select auth.jwt() ->> 'is_anonymous'), 'false') <> 'true'
  $predicate$;
begin
  for v_table, v_owner in
    select * from (values
      ('fizz_customers', $predicate$
        auth_user_id = (select auth.uid())
      $predicate$),
      ('fizz_sessions', $predicate$
        exists (select 1 from public.fizz_customers c
          where c.id = fizz_sessions.customer_id and c.auth_user_id = (select auth.uid()))
      $predicate$),
      ('fizz_sensor_choices', $predicate$
        exists (select 1 from public.fizz_customers c
          where c.id = fizz_sensor_choices.customer_id and c.auth_user_id = (select auth.uid()))
      $predicate$),
      ('fizz_sensors', $predicate$
        exists (select 1 from public.fizz_customers c
          where c.id = fizz_sensors.customer_id and c.auth_user_id = (select auth.uid()))
      $predicate$),
      ('fizz_sensor_readings', $predicate$
        exists (select 1 from public.fizz_sensors s
          join public.fizz_customers c on c.id = s.customer_id
          where s.id = fizz_sensor_readings.sensor_id and c.auth_user_id = (select auth.uid()))
      $predicate$),
      ('fizz_phone_pairings', $predicate$
        exists (select 1 from public.fizz_customers c
          join public.fizz_sensors s on s.customer_id = c.id
          where c.id = fizz_phone_pairings.customer_id and s.id = fizz_phone_pairings.sensor_id
            and c.auth_user_id = (select auth.uid()))
      $predicate$),
      ('fizz_phone_devices', $predicate$
        exists (select 1 from public.fizz_sensors s
          join public.fizz_customers c on c.id = s.customer_id
          where s.id = fizz_phone_devices.sensor_id and c.auth_user_id = (select auth.uid()))
      $predicate$),
      ('fizz_phone_clips', $predicate$
        exists (select 1 from public.fizz_sensors s
          join public.fizz_customers c on c.id = s.customer_id
          join public.fizz_phone_devices d on d.sensor_id = s.id
          where s.id = fizz_phone_clips.sensor_id and d.token_hash = fizz_phone_clips.device_hash
            and c.auth_user_id = (select auth.uid()))
      $predicate$),
      ('fizz_alert_rules', $predicate$
        exists (select 1 from public.fizz_customers c
          join public.fizz_sensors s on s.customer_id = c.id
          where c.id = fizz_alert_rules.customer_id and s.id = fizz_alert_rules.sensor_id
            and c.auth_user_id = (select auth.uid()))
      $predicate$),
      ('fizz_alert_events', $predicate$
        exists (select 1 from public.fizz_customers c
          join public.fizz_sensors s on s.customer_id = c.id
          join public.fizz_sensor_readings r on r.sensor_id = s.id
          where c.id = fizz_alert_events.customer_id and s.id = fizz_alert_events.sensor_id
            and r.id = fizz_alert_events.reading_id and c.auth_user_id = (select auth.uid()))
        and (rule_id is null or exists (select 1 from public.fizz_alert_rules a
          where a.id = fizz_alert_events.rule_id and a.customer_id = fizz_alert_events.customer_id
            and a.sensor_id = fizz_alert_events.sensor_id))
      $predicate$),
      ('fizz_agent_connections', $predicate$
        exists (select 1 from public.fizz_customers c
          where c.id = fizz_agent_connections.customer_id and c.auth_user_id = (select auth.uid()))
      $predicate$),
      ('fizz_device_pairings', $predicate$
        exists (select 1 from public.fizz_customers c
          where c.id = fizz_device_pairings.customer_id and c.auth_user_id = (select auth.uid()))
        and (sensor_id is null or exists (select 1 from public.fizz_sensors s
          where s.id = fizz_device_pairings.sensor_id and s.customer_id = fizz_device_pairings.customer_id))
        and (agent_id is null or exists (select 1 from public.fizz_agent_connections a
          where a.id = fizz_device_pairings.agent_id and a.customer_id = fizz_device_pairings.customer_id))
      $predicate$),
      ('fizz_invite_codes', $predicate$
        exists (select 1 from public.fizz_customers c
          where c.id = fizz_invite_codes.created_by and c.auth_user_id = (select auth.uid()))
      $predicate$)
    ) as ownership(table_name, predicate)
  loop
    execute format('alter table public.%I enable row level security', v_table);

    -- Permissive policies are ORed together. Replace partial dashboard policies
    -- as well as any older policies so none can bypass these ownership checks.
    for v_policy in
      select policyname from pg_policies where schemaname = 'public' and tablename = v_table
    loop
      execute format('drop policy %I on public.%I', v_policy, v_table);
    end loop;

    v_owner := format('(%s) and (%s)', v_authenticated, v_owner);
    execute format('create policy %I on public.%I for select to authenticated using (%s)',
      v_table || '_owner_select', v_table, v_owner);
    execute format('create policy %I on public.%I for insert to authenticated with check (%s)',
      v_table || '_owner_insert', v_table, v_owner);
    -- USING protects the existing row; WITH CHECK also protects the new owner
    -- and related IDs, preventing ownership transfers through UPDATE.
    execute format('create policy %I on public.%I for update to authenticated using (%s) with check (%s)',
      v_table || '_owner_update', v_table, v_owner, v_owner);
    execute format('create policy %I on public.%I for delete to authenticated using (%s)',
      v_table || '_owner_delete', v_table, v_owner);
  end loop;
end;
$migration$;

-- Waitlist submissions, business leads, and rate limits have no authenticated
-- owner. They retain their existing RLS-enabled, service-only access.
