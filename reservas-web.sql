begin;

create table umec2_portal.requests (
  account_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  company_id uuid not null references public.umec2_companies(id),
  pack integer not null,
  minutes integer not null,
  day date not null,
  start time not null,
  method text not null,
  name text not null,
  phone text not null,
  address text not null,
  zone text not null,
  beneficiary text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  service_id uuid unique references public.umec2_services(id) on delete set null,
  primary key (account_id, request_id)
);
alter table umec2_portal.requests enable row level security;
revoke all on umec2_portal.requests from public, anon, authenticated;
create index on umec2_portal.requests (company_id, created_at) where status = 'pending';
create unique index on umec2_portal.requests (account_id, company_id, day, start)
  where status = 'pending';

CREATE OR REPLACE FUNCTION umec2_portal.book(p_request uuid, p_pack integer, p_minutes integer, p_day date, p_start time without time zone, p_method text, p_name text, p_phone text, p_address text, p_zone text, p_beneficiary text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  account uuid := auth.uid();
  company uuid;
begin
  if account is null or not exists (select 1 from auth.users where id = account
      and email_confirmed_at is not null and email is not null) then
    raise exception 'Confirma tu correo antes de solicitar una cita.';
  end if;
  if p_request is null then raise exception 'Falta la referencia de solicitud.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('umec2-customer:' || account, 0));
  if exists (select 1 from umec2_portal.requests where account_id = account and request_id = p_request) then
    return p_request;
  end if;
  select company_id into company from umec2_portal.configuration where enabled;
  if company is null then raise exception 'Las reservas aún no están abiertas.'; end if;
  if exists (select 1 from public.umec2_profiles where user_id = account and company_id = company) then
    raise exception 'Usa una cuenta de cliente para reservar.';
  end if;
  if p_pack is null or p_pack not in (3,6,12) or p_minutes is null or
     p_minutes not between 30 and p_pack * 60 or p_minutes % 30 <> 0 or p_day is null or p_start is null then
    raise exception 'Revisa el pack y la duración.';
  end if;
  if p_method is null or not ((umec2_portal.settings()->'methods') ? p_method) then
    raise exception 'Ese método de pago no está disponible.';
  end if;
  if coalesce(length(trim(p_name)),0) not between 2 and 120 or
     coalesce(length(regexp_replace(p_phone,'[^0-9]','','g')),0) not between 7 and 15 or
     coalesce(length(trim(p_address)),0) not between 4 and 240 or
     coalesce(length(trim(p_zone)),0) not between 2 and 100 or length(coalesce(p_beneficiary,'')) > 120 then
    raise exception 'Revisa el nombre, el teléfono, la dirección y la localidad.';
  end if;
  if length(p_phone) > 80 then raise exception 'Revisa el teléfono.'; end if;
  if not exists (select 1 from umec2_portal.candidates(p_day,p_minutes) c where c.starts=p_start) then
    raise exception 'El hueco ya no está libre. Actualiza el calendario.';
  end if;
  if exists (select 1 from umec2_portal.requests r where r.account_id=account
      and r.company_id=company and r.day=p_day and r.start=p_start and r.status='pending') then
    raise exception 'Ya tienes una solicitud pendiente en ese horario.';
  end if;
  if (select count(*) from umec2_portal.requests r where r.account_id=account
      and r.status='pending' and r.day >= (now() at time zone 'Europe/Madrid')::date) >= 5 then
    raise exception 'Ya tienes cinco solicitudes pendientes. Contacta con Una Mano en Casa.';
  end if;
  insert into umec2_portal.requests(account_id,request_id,company_id,pack,minutes,day,start,method,name,phone,address,zone,beneficiary)
  values(account,p_request,company,p_pack,p_minutes,p_day,p_start,p_method,trim(p_name),trim(p_phone),trim(p_address),trim(p_zone),nullif(trim(p_beneficiary),''));
  return p_request;
end;
$$;

create or replace function umec2_portal.mine() returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(v) order by v.day desc,v.start desc), '[]'::jsonb)
  from (
    select r.request_id as id, coalesce(s.date,r.day) as day, to_char(coalesce(s.start,r.start),'HH24:MI') as start,
      r.pack, coalesce(extract(epoch from s."end"-s.start)::integer / 60,r.minutes) as minutes, case when r.status='approved' then coalesce(s.status,'cancelado')
        else r.status end as status
    from umec2_portal.requests r
    left join public.umec2_services s on s.id=r.service_id
    where r.account_id=auth.uid()
    union all
    select s.id,s.date,to_char(s.start,'HH24:MI'),o.pack_hours,o.visit_minutes,s.status
    from umec2_portal.orders o join public.umec2_services s on s.id=o.service_id
    where o.account_id=auth.uid() and not exists (
      select 1 from umec2_portal.requests r where r.account_id=o.account_id and r.request_id=o.request_id)
  ) v;
$$;

create function umec2_portal.pending(p_company uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not umec2_private.is_admin(p_company) then raise exception 'Acceso reservado a administración.'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('email',u.email)
    order by r.day,r.start,r.created_at), '[]'::jsonb)
    from umec2_portal.requests r join auth.users u on u.id=r.account_id
    where r.company_id=p_company and r.status='pending');
end;
$$;

create function umec2_portal.review(p_company uuid,p_account uuid,p_request uuid,p_approve boolean,p_client uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  company uuid := p_company;
  account uuid := p_account;
  request umec2_portal.requests;
  customer uuid;
  booking uuid;
  confirmed_email text;
  candidate record;
  final_time time;
  title text;
begin
  if not umec2_private.is_admin(company) then raise exception 'Acceso reservado a administración.'; end if;
  if p_approve is null then raise exception 'Indica la decisión.'; end if;
  select * into request from umec2_portal.requests
    where company_id=company and account_id=account and request_id=p_request for update;
  if not found then raise exception 'Solicitud no disponible.'; end if;
  if request.status='approved' and p_approve then
    return request.service_id;
  end if;
  if request.status='rejected' and not p_approve then return null; end if;
  if request.status<>'pending' then raise exception 'Esta solicitud ya fue revisada.'; end if;
  if not p_approve then
    update umec2_portal.requests set status='rejected' where account_id=account and request_id=p_request;
    return null;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('umec2-web-company:' || company, 0));
  if not exists (select 1 from umec2_portal.configuration c where c.company_id=company and c.enabled) then
    raise exception 'Activa el portal antes de confirmar solicitudes.';
  end if;
  select email into confirmed_email from auth.users where id=account and email_confirmed_at is not null;
  if confirmed_email is null then raise exception 'El cliente debe confirmar su correo.'; end if;
  for candidate in select c.worker_id from umec2_portal.candidates(request.day,request.minutes) c
    where c.starts = request.start order by c.worker_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(candidate.worker_id::text,0));
    select c.ends into final_time from umec2_portal.candidates(request.day,request.minutes) c
    where c.worker_id = candidate.worker_id and c.starts = request.start;
    exit when found;
  end loop;
  if final_time is null then raise exception 'El hueco ya no está libre. Actualiza el calendario.'; end if;
  if p_client is not null then
    if not exists (select 1 from public.umec2_clients where company_id=company and id=p_client)
      or exists (select 1 from umec2_portal.customer_links l where l.company_id=company and
      ((l.client_id=p_client and l.account_id<>account) or (l.account_id=account and l.client_id<>p_client))) then
      raise exception 'La ficha no está disponible para vincular.';
    end if;
    insert into umec2_portal.customer_links(company_id,account_id,client_id) values(company,account,p_client)
    on conflict do nothing;
  end if;
  select client_id into customer from umec2_portal.customer_links
    where company_id = company and account_id = account;
  if customer is null then
    if exists (select 1 from public.umec2_clients c where c.company_id = company and
      (lower(c.email) = lower(confirmed_email) or regexp_replace(regexp_replace(c.phone,'[^0-9]','','g'),'^(0034|34)([0-9]{9})$','\2') =
        regexp_replace(regexp_replace(request.phone,'[^0-9]','','g'),'^(0034|34)([0-9]{9})$','\2'))) then
      raise exception 'Ya existe una ficha con ese correo o teléfono. Vincula la ficha antes de confirmar.';
    end if;
    customer := gen_random_uuid();
    insert into public.umec2_clients(id, company_id, name, phone, email, address, zone, notes)
    values(customer,company,trim(request.name),trim(request.phone),confirmed_email,trim(request.address),trim(request.zone),'');
    insert into umec2_portal.customer_links values(company,account,customer);
  end if;
  booking := gen_random_uuid();
  title := 'Reserva web · Pack de ' || request.pack || ' h';
  insert into public.umec2_services(id,company_id,client_id,worker_id,date,start,"end",title,status,amount,paid,payment_method,notes)
  values(booking,company,customer,candidate.worker_id,request.day,request.start,final_time,title,'asignado',request.pack*18,false,request.method,
    concat_ws(' · ', 'Cita web confirmada. Pago pendiente.', 'Dirección de la visita: ' || trim(request.address), 'Localidad: ' || trim(request.zone),
      case when nullif(trim(request.beneficiary),'') is not null then 'Persona a acompañar: ' || trim(request.beneficiary) end));
  update umec2_portal.requests set status='approved', service_id=booking where account_id=account and request_id=p_request;
  return booking;
end;
$$;

create function umec2_portal.manage(p_company uuid,p_enabled boolean default null,p_worker uuid default null,
  p_day date default null,p_start time default null,p_end time default null,p_remove boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not umec2_private.is_admin(p_company) then raise exception 'Acceso reservado a administración.'; end if;
  if p_enabled is not null or p_worker is not null then
    perform pg_advisory_xact_lock(hashtextextended('umec2-web-company:' || p_company, 0));
    if exists (select 1 from umec2_portal.configuration where company_id<>p_company) then
      raise exception 'El portal pertenece a otra empresa.';
    end if;
  end if;
  if p_enabled is not null then
    insert into umec2_portal.configuration(singleton,company_id,enabled) values(true,p_company,p_enabled)
    on conflict (singleton) do update set enabled=excluded.enabled where configuration.company_id=p_company;
  end if;
  if p_worker is not null then
    if not exists (select 1 from public.umec2_workers where company_id=p_company and id=p_worker)
      or p_day is null or p_start is null or p_end is null or p_start>=p_end or p_end>=time '24:00'
      or (not p_remove and p_day not between (now() at time zone 'Europe/Madrid')::date
        and (now() at time zone 'Europe/Madrid')::date + 90) then
      raise exception 'Revisa el trabajador, la fecha y la franja.';
    end if;
    if p_remove then
      delete from umec2_portal.booking_windows where (worker_id,day,starts,ends)=(p_worker,p_day,p_start,p_end);
    else
      insert into umec2_portal.booking_windows(worker_id,day,starts,ends) values(p_worker,p_day,p_start,p_end)
      on conflict do nothing;
    end if;
  end if;
  return jsonb_build_object(
    'enabled',coalesce((select enabled from umec2_portal.configuration where company_id=p_company),false),
    'windows',(select coalesce(jsonb_agg(to_jsonb(b) order by b.day,b.starts), '[]'::jsonb)
     from umec2_portal.booking_windows b join public.umec2_workers w on w.id=b.worker_id
     where w.company_id=p_company and b.day >= (now() at time zone 'Europe/Madrid')::date));
end;
$$;

create function public.umec2_web_pending(p_company uuid) returns jsonb
language sql set search_path = '' as $$ select umec2_portal.pending(p_company); $$;
create function public.umec2_web_review(p_company uuid,p_account uuid,p_request uuid,p_approve boolean,p_client uuid default null) returns uuid
language sql set search_path = '' as $$ select umec2_portal.review(p_company,p_account,p_request,p_approve,p_client); $$;
create function public.umec2_web_manage(p_company uuid,p_enabled boolean default null,p_worker uuid default null,
  p_day date default null,p_start time default null,p_end time default null,p_remove boolean default false) returns jsonb
language sql set search_path = '' as $$ select umec2_portal.manage(p_company,p_enabled,p_worker,p_day,p_start,p_end,p_remove); $$;

revoke all on function umec2_portal.pending(uuid), umec2_portal.review(uuid,uuid,uuid,boolean,uuid),
  umec2_portal.manage(uuid,boolean,uuid,date,time,time,boolean),
  public.umec2_web_pending(uuid), public.umec2_web_review(uuid,uuid,uuid,boolean,uuid),
  public.umec2_web_manage(uuid,boolean,uuid,date,time,time,boolean)
  from public, anon, authenticated;
grant execute on function umec2_portal.pending(uuid), umec2_portal.review(uuid,uuid,uuid,boolean,uuid),
  umec2_portal.manage(uuid,boolean,uuid,date,time,time,boolean),
  public.umec2_web_pending(uuid), public.umec2_web_review(uuid,uuid,uuid,boolean,uuid),
  public.umec2_web_manage(uuid,boolean,uuid,date,time,time,boolean)
  to authenticated;

-- El alta antigua de empleados ya exige nombre y teléfono. El portal no envía esos metadatos a Auth.
CREATE OR REPLACE FUNCTION umec_private.register_confirmed_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c uuid; n text; p text;
begin
 if new.email_confirmed_at is null or new.email is null then return new; end if;
 select id into c from public.companies where slug='umec-coordinacion' and status='active';
 if c is null or exists(select 1 from public.company_members where company_id=c and user_id=new.id and active)
 or exists(select 1 from umec_private.admin_invitations where email=lower(new.email)) then return new; end if;
 n:=left(coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'),''),split_part(new.email,'@',1)),160);
 p:=left(coalesce(new.raw_user_meta_data->>'phone',''),40);
 if nullif(trim(new.raw_user_meta_data->>'full_name'),'') is null
 or length(regexp_replace(p,'[^0-9]','','g')) not between 7 and 15 then return new; end if;
 insert into public.coord_join_requests(company_id,user_id,full_name,email,phone) values(c,new.id,n,new.email,p)
 on conflict(company_id,user_id) do nothing;
 return new;
end;
$function$;

commit;
