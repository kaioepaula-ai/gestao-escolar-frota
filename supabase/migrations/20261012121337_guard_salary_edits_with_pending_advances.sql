create or replace function yellow_internal.staff_salary_before() returns trigger language plpgsql security definer set search_path='' as $$
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
   if new.municipality_id is distinct from mid then raise exception 'Motorista de outro município'; end if;
   if (new.driver_id<>old.driver_id or new.competence<>old.competence) and exists(select 1 from public.staff_advances where driver_id=new.driver_id and competence=new.competence and status='pending') then raise exception 'Este mês tem vales pendentes. Estorne e registre o pagamento para aplicar os descontos.'; end if;
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
