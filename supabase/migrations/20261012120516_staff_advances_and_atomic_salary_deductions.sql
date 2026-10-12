alter table public.user_module_permissions drop constraint user_module_permissions_module_check;
alter table public.user_module_permissions add constraint user_module_permissions_module_check check(module=any(array['summary','vehicles','drivers','assignments','fuelings','machine_fuelings','parts_purchases','service_sales','service_sales_prefeitura','service_sales_diego','service_sales_outros','work_days','incidents','km','maintenance','documents','expenses','routes','receivables','finance','messages','material_deliveries','equipment_services','notes','material_purchases','staff_advances']::text[]));
create table public.office_salary_payments (
 id uuid primary key default gen_random_uuid(),
 municipality_id uuid not null references public.municipalities(id),
 office_employee_id uuid not null references public.office_employees(id),
 competence date not null check (extract(day from competence)=1),
 gross_amount numeric(14,2) not null check(gross_amount>=0),
 deducted_amount numeric(14,2) not null default 0 check(deducted_amount>=0),
 amount numeric(14,2) not null default 0 check(amount>=0),
 paid_at date not null default current_date,
 created_by uuid not null default auth.uid() references public.profiles(id),
 created_at timestamptz not null default now(),
 unique(office_employee_id,competence)
);
create table public.staff_advances (
 id uuid primary key default gen_random_uuid(),
 municipality_id uuid not null references public.municipalities(id),
 driver_id uuid references public.drivers(id),
 office_employee_id uuid references public.office_employees(id),
 advance_date date not null default current_date,
 competence date not null check(extract(day from competence)=1),
 amount numeric(14,2) not null check(amount>0),
 notes text not null default '',
 receipt_url text,
 status text not null default 'pending' check(status in ('pending','deducted','cancelled')),
 driver_payment_id uuid references public.driver_payments(id),
 office_payment_id uuid references public.office_salary_payments(id),
 deducted_at timestamptz,
 cancelled_at timestamptz,
 created_by uuid not null default auth.uid() references public.profiles(id),
 created_at timestamptz not null default now(),
 check(num_nonnulls(driver_id,office_employee_id)=1),
 check((status='deducted' and num_nonnulls(driver_payment_id,office_payment_id)=1 and deducted_at is not null) or (status<>'deducted' and driver_payment_id is null and office_payment_id is null and deducted_at is null))
);
create index staff_advances_municipality_competence on public.staff_advances(municipality_id,competence);
create index staff_advances_driver_pending on public.staff_advances(driver_id,competence) where status='pending';
create index staff_advances_office_pending on public.staff_advances(office_employee_id,competence) where status='pending';
create index staff_advances_created_by on public.staff_advances(created_by);
create index staff_advances_driver_payment on public.staff_advances(driver_payment_id) where driver_payment_id is not null;
create index staff_advances_office_payment on public.staff_advances(office_payment_id) where office_payment_id is not null;
alter table public.driver_payments add column gross_amount numeric(14,2), add column deducted_amount numeric(14,2) not null default 0 check(deducted_amount>=0);
alter table public.staff_advances enable row level security;
alter table public.office_salary_payments enable row level security;
grant select,insert,update on public.staff_advances to authenticated;
grant select,insert,update,delete on public.office_salary_payments to authenticated;
revoke all on public.staff_advances,public.office_salary_payments from anon;
create policy advances_admin on public.staff_advances for all to authenticated using((select public.is_admin())) with check((select public.is_admin()));
create policy advances_view on public.staff_advances for select to authenticated using(driver_id is not null and public.can_access_municipality(municipality_id) and (select public.has_module_permission('staff_advances','view')));
create policy advances_insert on public.staff_advances for insert to authenticated with check(driver_id is not null and public.can_access_municipality(municipality_id) and created_by=(select auth.uid()) and (select public.has_module_permission('staff_advances','view')) and (select public.has_module_permission('staff_advances','insert')));
create policy advances_update on public.staff_advances for update to authenticated using(driver_id is not null and public.can_access_municipality(municipality_id) and created_by=(select auth.uid()) and (select public.has_module_permission('staff_advances','view')) and (select public.has_module_permission('staff_advances','update'))) with check(driver_id is not null and public.can_access_municipality(municipality_id) and created_by=(select auth.uid()) and (select public.has_module_permission('staff_advances','view')) and (select public.has_module_permission('staff_advances','update')));
create policy office_salary_admin on public.office_salary_payments for all to authenticated using((select public.is_admin())) with check((select public.is_admin()));
-- Private triggers serialize payments and advances for the same person. They need
-- full visibility to prevent hidden advances from being deducted twice or missed.
create function yellow_internal.guard_staff_advance() returns trigger language plpgsql security definer set search_path='' as $$
declare mid uuid;
begin
 if auth.uid() is null then raise exception 'Sessão não autorizada'; end if;
 if pg_trigger_depth()>1 then return new; end if;
 if TG_OP='UPDATE' then
  if old.status<>'pending' then raise exception 'Vale descontado ou cancelado não pode ser alterado. Estorne o pagamento antes de corrigir.'; end if;
  if new.driver_id is distinct from old.driver_id or new.office_employee_id is distinct from old.office_employee_id or new.municipality_id<>old.municipality_id then raise exception 'O funcionário e o município não podem ser trocados após o lançamento.'; end if;
  new.created_by:=old.created_by; new.created_at:=old.created_at;
 else new.created_by:=auth.uid(); new.created_at:=now(); end if;
 if new.status not in ('pending','cancelled') or new.driver_payment_id is not null or new.office_payment_id is not null then raise exception 'O desconto é confirmado pelo pagamento do salário.'; end if;
 if new.driver_id is not null then
  select municipality_id into mid from public.drivers where id=new.driver_id for update;
  if mid is null or mid<>new.municipality_id then raise exception 'Selecione um motorista do mesmo município.'; end if;
  if not (public.is_admin() or (public.can_access_municipality(mid) and public.has_module_permission('staff_advances','view') and public.has_module_permission('staff_advances',case when TG_OP='INSERT' then 'insert' else 'update' end) and (TG_OP='INSERT' or old.created_by=auth.uid()))) then raise exception 'Sem permissão para este vale'; end if;
  if new.status='pending' and exists(select 1 from public.driver_payments where driver_id=new.driver_id and competence=new.competence) then raise exception 'O salário deste mês já foi pago. Escolha outro mês de desconto ou estorne o pagamento.'; end if;
 else
  if not public.is_admin() then raise exception 'Funcionários do escritório são exclusivos da administração.'; end if;
  perform 1 from public.office_employees where id=new.office_employee_id for update;
  if not found then raise exception 'Funcionário não encontrado'; end if;
  if new.status='pending' and exists(select 1 from public.office_salary_payments where office_employee_id=new.office_employee_id and competence=new.competence) then raise exception 'O salário deste mês já foi pago. Escolha outro mês de desconto ou estorne o pagamento.'; end if;
 end if;
 new.deducted_at:=null;
 new.cancelled_at:=case when new.status='cancelled' then now() else null end;
 return new;
end $$;
create trigger guard_staff_advance before insert or update on public.staff_advances for each row execute function yellow_internal.guard_staff_advance();
create function yellow_internal.staff_salary_before() returns trigger language plpgsql security definer set search_path='' as $$
declare person uuid; mid uuid; total numeric; gross numeric; has_pending boolean;
begin
 if auth.uid() is null then raise exception 'Sessão não autorizada'; end if;
 if TG_TABLE_NAME='driver_payments' then
  person:=case when TG_OP='DELETE' then old.driver_id else new.driver_id end;
  select municipality_id into mid from public.drivers where id=person for update;
  if not (public.is_admin() or (public.can_access_municipality(mid) and public.has_module_permission('drivers','update') and (TG_OP='INSERT' or old.created_by=auth.uid()))) then raise exception 'Sem permissão para este pagamento'; end if;
 else
  if not public.is_admin() then raise exception 'Sem permissão para pagar funcionários do escritório'; end if;
  person:=case when TG_OP='DELETE' then old.office_employee_id else new.office_employee_id end;
  perform 1 from public.office_employees where id=person for update;
 end if;
 if TG_OP='DELETE' then
  update public.staff_advances set status='pending',driver_payment_id=null,office_payment_id=null,deducted_at=null where (TG_TABLE_NAME='driver_payments' and driver_payment_id=old.id) or (TG_TABLE_NAME='office_salary_payments' and office_payment_id=old.id);
  return old;
 end if;
 if TG_OP='UPDATE' then
  if TG_TABLE_NAME='driver_payments' then
   if old.deducted_amount>0 and (new.driver_id<>old.driver_id or new.competence<>old.competence or new.amount<>old.amount or new.municipality_id<>old.municipality_id) then raise exception 'Pagamento com vales: estorne antes de alterar funcionário, mês ou valor.'; end if;
   new.gross_amount:=case when old.deducted_amount>0 then old.gross_amount else new.amount end;
   new.deducted_amount:=old.deducted_amount;
  else
   if new.office_employee_id<>old.office_employee_id or new.competence<>old.competence or new.amount<>old.amount or new.gross_amount<>old.gross_amount or new.municipality_id<>old.municipality_id then raise exception 'Estorne o pagamento antes de alterar os valores.'; end if;
   new.deducted_amount:=old.deducted_amount;
  end if;
  new.created_by:=old.created_by;new.created_at:=old.created_at;return new;
 end if;
 if extract(day from new.competence)<>1 then raise exception 'Competência inválida'; end if;
 if TG_TABLE_NAME='driver_payments' and (mid is null or new.municipality_id<>mid) then raise exception 'Motorista de outro município'; end if;
 perform 1 from public.staff_advances a where a.status='pending' and a.competence=new.competence and ((TG_TABLE_NAME='driver_payments' and a.driver_id=person) or (TG_TABLE_NAME='office_salary_payments' and a.office_employee_id=person)) order by a.id for update;
 select coalesce(sum(a.amount),0) into total from public.staff_advances a where a.status='pending' and a.competence=new.competence and ((TG_TABLE_NAME='driver_payments' and a.driver_id=person) or (TG_TABLE_NAME='office_salary_payments' and a.office_employee_id=person));
 if total>0 and not public.is_admin() and not public.has_module_permission('staff_advances','view') then raise exception 'Este salário tem vales. Solicite acesso ao módulo Vales e adiantamentos.'; end if;
 gross:=case when TG_TABLE_NAME='driver_payments' then new.amount else new.gross_amount end;
 if gross is null or gross<0 or total>gross then raise exception 'Os vales (%) excedem o valor do mês (%). Corrija o valor ou o mês do desconto antes de pagar.',total,gross; end if;
 new.gross_amount:=gross;new.deducted_amount:=total;new.amount:=gross-total;new.created_by:=auth.uid();new.created_at:=now();
 return new;
end $$;
create function yellow_internal.staff_salary_after() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sessão não autorizada'; end if;
 if TG_TABLE_NAME='driver_payments' then
  update public.staff_advances set status='deducted',driver_payment_id=new.id,deducted_at=now() where driver_id=new.driver_id and competence=new.competence and status='pending';
 else
  update public.staff_advances set status='deducted',office_payment_id=new.id,deducted_at=now() where office_employee_id=new.office_employee_id and competence=new.competence and status='pending';
 end if;
 return new;
end $$;
create trigger staff_salary_before before insert or update or delete on public.driver_payments for each row execute function yellow_internal.staff_salary_before();
create trigger staff_salary_after after insert on public.driver_payments for each row execute function yellow_internal.staff_salary_after();
create trigger staff_salary_before before insert or update or delete on public.office_salary_payments for each row execute function yellow_internal.staff_salary_before();
create trigger staff_salary_after after insert on public.office_salary_payments for each row execute function yellow_internal.staff_salary_after();
create function yellow_internal.audit_staff_changes() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME not in ('staff_advances','office_salary_payments') then raise exception 'Tabela inválida'; end if;
 insert into public.audit_log(table_name,record_id,action,user_id,changed_at,old_data,new_data) values(TG_TABLE_NAME,coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id'),TG_OP,auth.uid(),now(),case when TG_OP in ('UPDATE','DELETE') then to_jsonb(old) end,case when TG_OP in ('INSERT','UPDATE') then to_jsonb(new) end);
 return coalesce(new,old);
end $$;
create trigger audit_staff_changes after insert or update or delete on public.staff_advances for each row execute function yellow_internal.audit_staff_changes();
create trigger audit_staff_changes after insert or update or delete on public.office_salary_payments for each row execute function yellow_internal.audit_staff_changes();
revoke all on function yellow_internal.guard_staff_advance(),yellow_internal.staff_salary_before(),yellow_internal.staff_salary_after(),yellow_internal.audit_staff_changes() from public,anon,authenticated;
create policy advances_receipt_read on storage.objects for select to authenticated using(bucket_id='fuel-receipts' and exists(select 1 from public.staff_advances a where a.receipt_url=objects.name));
notify pgrst,'reload schema';
