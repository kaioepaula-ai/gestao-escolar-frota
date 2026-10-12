alter table public.expenses add column paid_at timestamptz;
alter table public.material_purchases add column paid_at timestamptz;
create function yellow_internal.stamp_boolean_payment() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if TG_OP='INSERT' then new.paid_at:=case when new.paid then now() else null end;
 elsif new.paid is distinct from old.paid then new.paid_at:=case when new.paid then now() else null end;
 else new.paid_at:=old.paid_at;end if;
 return new;
end $$;
create trigger stamp_payment_date before insert or update on public.expenses for each row execute function yellow_internal.stamp_boolean_payment();
create trigger stamp_payment_date before insert or update on public.material_purchases for each row execute function yellow_internal.stamp_boolean_payment();
create function yellow_internal.stamp_receivable_payment() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if TG_OP='INSERT' then new.received_at:=case when new.status='received' then (now() at time zone 'America/Fortaleza')::date else null end;
 elsif new.status is distinct from old.status then new.received_at:=case when new.status='received' then (now() at time zone 'America/Fortaleza')::date else null end;
 else new.received_at:=old.received_at;end if;
 if TG_OP='UPDATE' then new.created_by:=old.created_by;new.created_at:=old.created_at;end if;
 return new;
end $$;
create trigger stamp_payment_date before insert or update on public.receivables for each row execute function yellow_internal.stamp_receivable_payment();
create function yellow_internal.stamp_salary_payment() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if TG_TABLE_NAME='driver_payments' then new.paid_at:=now();else new.paid_at:=(now() at time zone 'America/Fortaleza')::date;end if;
 return new;
end $$;
create trigger stamp_payment_date before insert on public.driver_payments for each row execute function yellow_internal.stamp_salary_payment();
create trigger stamp_payment_date before insert on public.office_salary_payments for each row execute function yellow_internal.stamp_salary_payment();
revoke all on function yellow_internal.stamp_boolean_payment(),yellow_internal.stamp_receivable_payment(),yellow_internal.stamp_salary_payment() from public,anon,authenticated;
create policy receivables_employee_update on public.receivables for update to authenticated using(public.can_access_municipality(municipality_id) and created_by=(select auth.uid()) and (select public.has_module_permission('receivables','view')) and (select public.has_module_permission('receivables','update'))) with check(public.can_access_municipality(municipality_id) and created_by=(select auth.uid()) and (select public.has_module_permission('receivables','view')) and (select public.has_module_permission('receivables','update')));
notify pgrst,'reload schema';
