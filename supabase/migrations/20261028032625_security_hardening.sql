-- Default-deny new objects in the exposed schema, matching the server-only API.
revoke create on schema public from public, anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on tables from public, anon, authenticated;
-- PUBLIC EXECUTE is a global built-in default; a schema-local REVOKE cannot remove it.
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end;
$$;

-- Check current Auth state even for already-issued Fizz sessions.
create or replace function public.fizz_session_customer(p_token text)
returns uuid language plpgsql stable security definer set search_path = '' as $$
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return null; end if;
  return (select c.id from public.fizz_sessions s
    join public.fizz_customers c on c.id = s.customer_id
    join auth.users u on u.id = c.auth_user_id
    where s.token_hash = extensions.digest(decode(p_token, 'hex'), 'sha256') and s.expires_at > now()
      and not coalesce(u.is_anonymous, false) and u.deleted_at is null
      and (u.banned_until is null or u.banned_until <= now()) limit 1);
end;
$$;

create or replace function public.fizz_current_customer(p_token text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('username', c.username) from public.fizz_customers c
  where c.id = public.fizz_session_customer(p_token);
$$;

create or replace function public.fizz_session_account(p_token text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('username', c.username, 'auth_user_id', c.auth_user_id)
  from public.fizz_customers c where c.id = public.fizz_session_customer(p_token);
$$;

-- Password resets, email changes, and bans must invalidate Fizz's independent
-- 12-hour cookies. Suspended/deleted users also lose agent and device access.
create function public.fizz_auth_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.encrypted_password is distinct from new.encrypted_password
    or old.email is distinct from new.email
    or old.banned_until is distinct from new.banned_until
    or old.deleted_at is distinct from new.deleted_at
    or old.is_anonymous is distinct from new.is_anonymous then
    delete from public.fizz_sessions where customer_id in
      (select id from public.fizz_customers where auth_user_id = new.id);
  end if;
  if new.banned_until > now() or new.deleted_at is not null or coalesce(new.is_anonymous, false) then
    update public.fizz_agent_connections set revoked_at = now()
      where revoked_at is null and customer_id in (select id from public.fizz_customers where auth_user_id = new.id);
    update public.fizz_phone_devices set revoked_at = now()
      where revoked_at is null and sensor_id in (select s.id from public.fizz_sensors s
        join public.fizz_customers c on c.id = s.customer_id where c.auth_user_id = new.id);
    update public.fizz_sensors set api_key_hash = null, status = 'paused'
      where customer_id in (select id from public.fizz_customers where auth_user_id = new.id);
    update public.fizz_alert_rules set enabled = false where customer_id in
      (select id from public.fizz_customers where auth_user_id = new.id);
    update public.fizz_alert_events set notify_status = 'skipped', notify_error = 'Account suspended.'
      where notify_status in ('pending', 'sending') and customer_id in
        (select id from public.fizz_customers where auth_user_id = new.id);
    delete from public.fizz_phone_pairings where customer_id in
      (select id from public.fizz_customers where auth_user_id = new.id);
    update public.fizz_device_pairings set status = 'rejected', finished_at = now()
      where status in ('waiting', 'claimed') and customer_id in
        (select id from public.fizz_customers where auth_user_id = new.id);
  end if;
  return new;
end;
$$;
create trigger fizz_auth_security_changed
  after update of encrypted_password, email, banned_until, deleted_at, is_anonymous on auth.users
  for each row execute function public.fizz_auth_changed();
revoke execute on function public.fizz_auth_changed() from public, anon, authenticated, service_role;

-- Shared per-customer budgets survive server restarts and session rotation.
create function public.fizz_request_budget(p_token text, p_operation text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_minute integer; v_hour integer;
begin
  v_customer := public.fizz_session_customer(p_token);
  if v_customer is null then return jsonb_build_object('error', 'unauthorized'); end if;
  case p_operation
    when 'chat' then v_minute := 20; v_hour := 200;
    when 'voice' then v_minute := 20; v_hour := 100;
    else return jsonb_build_object('error', 'invalid_operation');
  end case;
  if not public.fizz_rate_limit_hit('paid_' || p_operation || '_minute', v_customer::text, v_minute, interval '1 minute')
    or not public.fizz_rate_limit_hit('paid_' || p_operation || '_hour', v_customer::text, v_hour, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.fizz_request_budget(text, text) from public, anon, authenticated;
grant execute on function public.fizz_request_budget(text, text) to service_role;

-- SQL NULL must never make a missing sensor credential pass authentication.
create or replace function public.fizz_ingest_reading(p_sensor_id uuid, p_key text, p_event_id text, p_observed_at timestamptz,
  p_metric text, p_numeric_value double precision, p_boolean_value boolean, p_text_value text, p_unit text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_sensor public.fizz_sensors%rowtype;
begin
  select * into v_sensor from public.fizz_sensors where id=p_sensor_id and deleted_at is null and mode='api' and status='active';
  if not found or p_key is null or p_key !~ '^fizz_[0-9a-f]{64}$'
    or v_sensor.api_key_hash is distinct from extensions.digest(p_key,'sha256') then
    return jsonb_build_object('error','unauthorized');
  end if;
  if not coalesce((case v_sensor.kind
    when 'water' then (p_metric='flow_l_min' and p_numeric_value between 0 and 200) or (p_metric='leak' and p_boolean_value is not null)
    when 'gas' then (p_metric='concentration_ppm' and p_numeric_value between 0 and 10000) or (p_metric='alarm' and p_boolean_value is not null)
    when 'radio' then p_metric='rssi_dbm' and p_numeric_value between -150 and 0
    when 'temperature' then p_metric='temperature_c' and p_numeric_value between -100 and 200
    when 'pressure' then p_metric='pressure_kpa' and p_numeric_value between 0 and 1000
    when 'humidity' then p_metric='humidity_pct' and p_numeric_value between 0 and 100
    when 'sound' then p_metric='sound_db' and p_numeric_value between 0 and 160
    when 'phone' then (p_metric='acceleration_ms2' and p_numeric_value between 0 and 300)
      or (p_metric='orientation_deg' and p_numeric_value between -360 and 360)
    when 'custom' then true else false end), false) then
    return jsonb_build_object('error','invalid_reading');
  end if;
  if not public.fizz_rate_limit_hit('ingest_sensor', v_sensor.id::text, 1200, interval '1 minute')
    or not public.fizz_rate_limit_hit('ingest_customer', v_sensor.customer_id::text, 5000, interval '1 minute') then
    return jsonb_build_object('error','rate_limited');
  end if;
  return public.fizz_write_reading(p_sensor_id,p_event_id,coalesce(p_observed_at,now()),p_metric,p_numeric_value,p_boolean_value,p_text_value,p_unit,'api');
end;
$$;


create or replace function public.fizz_oauth_sign_in(p_user_id uuid, p_email text, p_invite text, p_ip text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_customer public.fizz_customers%rowtype;
  v_invite text := public.fizz_normalize_invite(p_invite);
  v_hash bytea;
  v_base text;
  v_username text;
  v_token bytea;
begin
  if not exists (select 1 from auth.users u where u.id = p_user_id
    and not coalesce(u.is_anonymous, false) and u.deleted_at is null
    and (u.banned_until is null or u.banned_until <= now())) then
    return jsonb_build_object('error', 'unavailable');
  end if;
  select * into v_customer from public.fizz_customers where auth_user_id = p_user_id;
  if not found then
    if v_invite is null then
      return jsonb_build_object('error', 'no_account');
    end if;
    if not public.fizz_rate_limit_hit('register_ip', p_ip, 10, interval '1 hour') then
      return jsonb_build_object('error', 'rate_limited');
    end if;
    v_hash := extensions.digest(v_invite, 'sha256');
    perform 1 from public.fizz_invite_codes
    where code_hash = v_hash and used_at is null and (expires_at is null or expires_at > now())
    for update;
    if not found then
      return jsonb_build_object('error', 'invalid_invite');
    end if;
    v_base := regexp_replace(lower(split_part(coalesce(p_email, ''), '@', 1)), '[^a-z0-9_]', '', 'g');
    if v_base !~ '^[a-z]' then v_base := 'fizz_' || v_base; end if;
    v_base := left(v_base, 18);
    if length(v_base) < 3 then v_base := 'fizz_user'; end if;
    for i in 0..9 loop
      v_username := case when i = 0 then v_base
        else v_base || '_' || lpad(floor(random() * 10000)::int::text, 4, '0') end;
      begin
        insert into public.fizz_customers(username, auth_user_id)
        values (v_username, p_user_id)
        returning * into v_customer;
        exit;
      exception when unique_violation then
        null;
      end;
    end loop;
    if v_customer.id is null then
      return jsonb_build_object('error', 'unavailable');
    end if;
    update public.fizz_invite_codes set used_at = now(), used_by = v_customer.id where code_hash = v_hash;
  end if;
  v_token := extensions.gen_random_bytes(32);
  insert into public.fizz_sessions(token_hash, customer_id, expires_at)
  values (extensions.digest(v_token, 'sha256'), v_customer.id, now() + interval '12 hours');
  return jsonb_build_object('username', v_customer.username, 'token', encode(v_token, 'hex'));
end;
$$;


create or replace function public.fizz_phone_reading(p_device_token text, p_event_id text, p_metric text,
  p_numeric_value double precision, p_unit text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.fizz_phone_devices%rowtype;
begin
  if p_device_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('error', 'unauthorized'); end if;
  select * into v_device from public.fizz_phone_devices
  where token_hash = extensions.digest(decode(p_device_token, 'hex'), 'sha256')
    and revoked_at is null and expires_at > now() for update;
  if not found or not exists (select 1 from public.fizz_sensors where id = v_device.sensor_id and deleted_at is null and kind = 'phone') then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if not public.fizz_rate_limit_hit('fizz_phone_reading', v_device.sensor_id::text, 1200, interval '1 minute') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  if p_metric not in ('acceleration_x', 'acceleration_y', 'acceleration_z', 'rotation_alpha', 'rotation_beta', 'rotation_gamma', 'latitude', 'longitude', 'location_accuracy', 'voice_level')
     or p_numeric_value is null or p_numeric_value = 'NaN'::float8 or abs(p_numeric_value) > 100000
     or length(p_event_id) not between 1 and 100 then
    return jsonb_build_object('error', 'invalid_reading');
  end if;
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
  values (v_device.sensor_id, p_event_id, now(), p_metric, p_numeric_value, p_unit, 'phone')
  on conflict (sensor_id, event_id, metric) do nothing;
  update public.fizz_phone_devices set last_seen_at = now() where token_hash = v_device.token_hash;
  return jsonb_build_object('ok', true, 'sensor_id', v_device.sensor_id);
end;
$$;

create or replace function public.fizz_phone_transcript(p_device_token text, p_event_id text, p_text text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.fizz_phone_devices%rowtype;
begin
  if p_device_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('error', 'unauthorized'); end if;
  select * into v_device from public.fizz_phone_devices
  where token_hash = extensions.digest(decode(p_device_token, 'hex'), 'sha256')
    and revoked_at is null and expires_at > now() for update;
  if not found or not exists (select 1 from public.fizz_sensors where id = v_device.sensor_id and deleted_at is null and kind = 'phone') then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if not public.fizz_rate_limit_hit('fizz_phone_transcript', v_device.sensor_id::text, 60, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  if length(p_event_id) not between 1 and 100 or length(trim(p_text)) not between 1 and 500 then
    return jsonb_build_object('error', 'invalid_transcript');
  end if;
  insert into public.fizz_sensor_readings(sensor_id,event_id,observed_at,metric,text_value,source)
  values (v_device.sensor_id,p_event_id,now(),'voice_transcript',trim(p_text),'phone')
  on conflict (sensor_id,event_id,metric) do nothing;
  update public.fizz_phone_devices set last_seen_at = now() where token_hash = v_device.token_hash;
  return jsonb_build_object('ok', true, 'sensor_id', v_device.sensor_id);
end;
$$;

create or replace function public.fizz_phone_clip(p_device_token text, p_mime_type text, p_audio_base64 text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.fizz_phone_devices%rowtype; v_audio bytea; v_clip_id uuid;
begin
  if p_device_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('error', 'unauthorized'); end if;
  select * into v_device from public.fizz_phone_devices
  where token_hash = extensions.digest(decode(p_device_token, 'hex'), 'sha256')
    and revoked_at is null and expires_at > now() for update;
  if not found or not exists (select 1 from public.fizz_sensors where id = v_device.sensor_id and deleted_at is null and kind = 'phone') then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if not public.fizz_rate_limit_hit('fizz_phone_clip', v_device.sensor_id::text, 20, interval '1 hour') then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  if p_mime_type not in ('audio/webm', 'audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus')
     or length(p_audio_base64) > 349528 then return jsonb_build_object('error', 'invalid_clip'); end if;
  begin v_audio := decode(p_audio_base64, 'base64');
  exception when others then return jsonb_build_object('error', 'invalid_clip'); end;
  if octet_length(v_audio) < 100 or octet_length(v_audio) > 262144 then
    return jsonb_build_object('error', 'invalid_clip');
  end if;
  insert into public.fizz_phone_clips(sensor_id, device_hash, mime_type, audio)
  values (v_device.sensor_id, v_device.token_hash, p_mime_type, v_audio) returning id into v_clip_id;
  insert into public.fizz_sensor_readings(sensor_id, event_id, observed_at, metric, numeric_value, unit, source)
  values (v_device.sensor_id, v_clip_id::text, now(), 'voice_clip', octet_length(v_audio), 'bytes', 'phone');
  update public.fizz_phone_devices set last_seen_at = now() where token_hash = v_device.token_hash;
  return jsonb_build_object('ok', true, 'clip_id', v_clip_id, 'size_bytes', octet_length(v_audio));
end;
$$;
