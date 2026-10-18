-- Quantities support fractional percentages; costs use sufficient precision.
ALTER TABLE public.inventory_items ALTER COLUMN quantity TYPE numeric USING quantity::numeric, ALTER COLUMN avg_cost TYPE numeric USING avg_cost::numeric;
ALTER TABLE public.purchase_items ALTER COLUMN quantity TYPE numeric USING quantity::numeric, ALTER COLUMN unit_cost TYPE numeric USING unit_cost::numeric;
ALTER TABLE public.reservations ALTER COLUMN quantity TYPE numeric USING quantity::numeric, ALTER COLUMN unit_cost TYPE numeric USING unit_cost::numeric;
ALTER TABLE public.writeoffs ALTER COLUMN quantity TYPE numeric USING quantity::numeric, ALTER COLUMN unit_cost TYPE numeric USING unit_cost::numeric;
ALTER TABLE public.inventory_items DROP CONSTRAINT inventory_items_unit_type_check;
ALTER TABLE public.inventory_items ADD CONSTRAINT inventory_items_unit_type_check CHECK(unit_type IN ('piece','bunch','package','percent'));
ALTER TABLE public.purchase_items DROP CONSTRAINT purchase_items_unit_type_check;
ALTER TABLE public.purchase_items ADD CONSTRAINT purchase_items_unit_type_check CHECK(unit_type IN ('piece','bunch','package','percent'));
CREATE INDEX IF NOT EXISTS purchases_target_client_idx ON public.purchases(target_client_id);


CREATE OR REPLACE FUNCTION public.crm_create_client(p_company_name text, p_inn text, p_contact_name text, p_contact_info text, p_status text, p_work_model text, p_subscription jsonb, p_initial_payment numeric, p_notes text, p_default_price numeric, p_mark_paid boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_client uuid; v_subscription uuid; v_payment numeric;
begin
  if p_work_model not in ('subscription','durable','retail') then raise exception 'Некорректный формат клиента'; end if;
  insert into public.clients(company_name,inn,contact_name,contact_info,status,work_model,notes,default_price)
  values(p_company_name,nullif(p_inn,''),nullif(p_contact_name,''),nullif(p_contact_info,''),p_status,p_work_model,nullif(p_notes,''),greatest(0,coalesce(p_default_price,0)))
  returning id into v_client;

  if p_work_model='subscription' and p_subscription is not null then
    insert into public.subscriptions(client_id,start_date,months,deliveries_per_month,bouquet_price,discount_percent,status)
    values(v_client,(p_subscription->>'start_date')::date,(p_subscription->>'months')::numeric,
      (p_subscription->>'deliveries_per_month')::numeric,(p_subscription->>'bouquet_price')::numeric,
      coalesce((p_subscription->>'discount_percent')::numeric,0),'active')
    returning id into v_subscription;
  end if;

  v_payment:=case
    when coalesce(p_initial_payment,0)>0 then p_initial_payment
    when coalesce(p_mark_paid,false) and p_work_model<>'subscription' then greatest(0,coalesce(p_default_price,0))
    else 0 end;

  if v_payment>0 then
    insert into public.payments(client_id,subscription_id,amount,payment_date,note)
    values(v_client,v_subscription,v_payment,current_date,case when p_mark_paid then 'Отмечено оплачено в карточке клиента' else 'Первичная оплата' end);
  end if;

  insert into public.history(event_type,description,client_id,amount)
  values('Клиент','Создан клиент '||p_company_name,v_client,nullif(v_payment,0));
  return v_client;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_expense(p_category text, p_description text, p_amount numeric, p_order_id uuid, p_expense_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare eid uuid; cid uuid;
begin
  if p_amount<=0 then raise exception 'Сумма должна быть больше нуля'; end if;
  if p_order_id is not null then select client_id into cid from public.orders where id=p_order_id; end if;
  insert into public.expenses(expense_date,category,description,amount,client_id,order_id)
  values(coalesce(p_expense_date,current_date),p_category,nullif(p_description,''),p_amount,cid,p_order_id) returning id into eid;
  insert into public.history(event_type,description,client_id,order_id,amount)
  values('Расход',p_category||case when coalesce(p_description,'')<>'' then ' · '||p_description else '' end,cid,p_order_id,p_amount);
  return eid;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_inventory_item(p_category text, p_name text, p_color text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare iid uuid;
begin
  if p_category not in ('fresh','dried') then raise exception 'Некорректный склад'; end if;
  if trim(coalesce(p_name,''))='' then raise exception 'Укажите название позиции'; end if;
  insert into public.inventory_items(category,name,color,quantity,avg_cost)
  values(p_category,trim(p_name),coalesce(nullif(trim(p_color),''),'Без цвета'),0,0)
  returning id into iid;
  insert into public.history(event_type,description,meta)
  values('Склад','Создана позиция '||trim(p_name),jsonb_build_object('item_id',iid));
  return iid;
exception when unique_violation then
  raise exception 'Такая активная позиция уже существует';
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_inventory_item(p_category text, p_name text, p_color text, p_unit_type text DEFAULT 'piece'::text, p_units_per_unit integer DEFAULT 1)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare iid uuid;
begin
 if p_category not in ('fresh','dried') then raise exception 'Некорректный склад'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'Укажите название позиции'; end if;
 if p_unit_type not in ('piece','bunch','package','percent') then raise exception 'Некорректная единица измерения'; end if;
 if p_units_per_unit<=0 then raise exception 'Количество штук в единице должно быть больше нуля'; end if;
 if p_unit_type='piece' then p_units_per_unit:=1; end if;
 insert into public.inventory_items(category,name,color,quantity,avg_cost,unit_type,units_per_unit)
 values(p_category,trim(p_name),coalesce(nullif(trim(p_color),''),'Без цвета'),0,0,p_unit_type,p_units_per_unit)
 returning id into iid;
 insert into public.history(event_type,description,meta)
 values('Склад','Создана позиция '||trim(p_name),jsonb_build_object('item_id',iid,'unit_type',p_unit_type,'units_per_unit',p_units_per_unit));
 return iid;
exception when unique_violation then raise exception 'Такая активная позиция уже существует';
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_order(p_client_id uuid, p_subscription_id uuid, p_delivery_date date, p_sale_price numeric, p_note text, p_reservations jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_order uuid; x jsonb; iid uuid; q numeric; c numeric; available numeric;
begin
  insert into public.orders(client_id,subscription_id,delivery_date,sale_price,note,status)
  values(p_client_id,p_subscription_id,p_delivery_date,greatest(0,p_sale_price),nullif(p_note,''),'draft')
  returning id into v_order;

  for x in select * from jsonb_array_elements(coalesce(p_reservations,'[]'::jsonb)) loop
    iid=(x->>'item_id')::uuid; q=(x->>'quantity')::numeric;
    select i.avg_cost,
      i.quantity-coalesce((select sum(r.quantity) from public.reservations r join public.orders o on o.id=r.order_id where r.item_id=i.id and o.status='reserved'),0)
    into c,available from public.inventory_items i where i.id=iid for update;
    if q<=0 or available<q then raise exception 'Недостаточно свободного остатка'; end if;
    insert into public.reservations(order_id,item_id,quantity,unit_cost) values(v_order,iid,q,c);
  end loop;

  if jsonb_array_length(coalesce(p_reservations,'[]'::jsonb))>0 then
    update public.orders set status='reserved' where id=v_order;
  end if;
  insert into public.history(event_type,description,client_id,order_id)
  values(case when jsonb_array_length(coalesce(p_reservations,'[]'::jsonb))>0 then 'Резерв' else 'Заказ' end,'Создан заказ',p_client_id,v_order);
  return v_order;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_order_v2(p_client_id uuid, p_subscription_id uuid, p_delivery_date date, p_sale_price numeric, p_note text, p_reservations jsonb, p_sales_channel text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_order uuid; x jsonb; iid uuid; q numeric; c numeric; available numeric; total_deliveries numeric;
  v_meta jsonb:=coalesce((select e->'_meta' from jsonb_array_elements(coalesce(p_reservations,'[]'::jsonb)) e where e ? '_meta' limit 1),'{}'::jsonb);
  v_title text:=nullif(trim(coalesce(v_meta->>'title','')),'');
  v_delivery_no numeric:=nullif(v_meta->>'subscription_delivery_no','')::numeric;
  v_lines jsonb:=coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(p_reservations,'[]'::jsonb)) e where not (e ? '_meta')),'[]'::jsonb);
begin
  if p_sales_channel not in ('subscription','one_off','retail') then raise exception 'Некорректный формат продажи'; end if;
  if p_sales_channel<>'retail' and p_client_id is null then raise exception 'Выберите клиента'; end if;
  if p_client_id is not null and not exists(select 1 from public.clients where id=p_client_id and archived_at is null) then raise exception 'Клиент удалён или недоступен'; end if;

  if p_sales_channel='subscription' then
    if p_subscription_id is null then raise exception 'У клиента нет активной подписки'; end if;
    if v_delivery_no is null or v_delivery_no<=0 then raise exception 'Укажите номер поставки по подписке'; end if;
    select months*deliveries_per_month into total_deliveries from public.subscriptions where id=p_subscription_id and client_id=p_client_id;
    if total_deliveries is null then raise exception 'Подписка не найдена'; end if;
    if v_delivery_no>total_deliveries then raise exception 'Номер поставки больше общего количества поставок по подписке (%)',total_deliveries; end if;
  end if;

  insert into public.orders(client_id,subscription_id,delivery_date,sale_price,note,status,sales_channel,title,subscription_delivery_no)
  values(p_client_id,case when p_sales_channel='subscription' then p_subscription_id else null end,p_delivery_date,greatest(0,p_sale_price),
    nullif(p_note,''),'draft',p_sales_channel,v_title,case when p_sales_channel='subscription' then v_delivery_no else null end)
  returning id into v_order;

  for x in select * from jsonb_array_elements(v_lines) loop
    iid=(x->>'item_id')::uuid;q=(x->>'quantity')::numeric;
    select i.avg_cost,i.quantity-coalesce((select sum(r.quantity) from public.reservations r join public.orders o on o.id=r.order_id where r.item_id=i.id and o.status='reserved'),0)
    into c,available from public.inventory_items i where i.id=iid and i.archived_at is null for update;
    if c is null then raise exception 'Позиция склада удалена или не найдена'; end if;
    if q<=0 or available<q then raise exception 'Недостаточно свободного остатка'; end if;
    insert into public.reservations(order_id,item_id,quantity,unit_cost) values(v_order,iid,q,c);
  end loop;

  if jsonb_array_length(v_lines)>0 then update public.orders set status='reserved' where id=v_order; end if;
  insert into public.history(event_type,description,client_id,order_id,meta)
  values(case when jsonb_array_length(v_lines)>0 then 'Резерв' else 'Заказ' end,
    coalesce(v_title,'Создан заказ'),p_client_id,v_order,
    jsonb_build_object('subscription_delivery_no',case when p_sales_channel='subscription' then v_delivery_no else null end));
  return v_order;
exception when unique_violation then
  raise exception 'Поставка № % по этой подписке уже существует',v_delivery_no;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_order_v3(p_client_id uuid, p_subscription_id uuid, p_delivery_date date, p_sale_price numeric, p_note text, p_reservations jsonb, p_sales_channel text, p_title text, p_subscription_delivery_no integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_order uuid; x jsonb; iid uuid; q numeric; c numeric; available numeric; total_deliveries numeric;
begin
  if p_sales_channel not in ('subscription','one_off','retail') then raise exception 'Некорректный формат продажи'; end if;
  if p_sales_channel<>'retail' and p_client_id is null then raise exception 'Выберите клиента'; end if;
  if p_client_id is not null and not exists(select 1 from public.clients where id=p_client_id and archived_at is null) then raise exception 'Клиент удалён или недоступен'; end if;

  if p_sales_channel='subscription' then
    if p_subscription_id is null then raise exception 'У клиента нет активной подписки'; end if;
    if p_subscription_delivery_no is null or p_subscription_delivery_no<=0 then raise exception 'Укажите номер поставки по подписке'; end if;
    select months*deliveries_per_month into total_deliveries from public.subscriptions where id=p_subscription_id and client_id=p_client_id;
    if total_deliveries is null then raise exception 'Подписка не найдена'; end if;
    if p_subscription_delivery_no>total_deliveries then raise exception 'Номер поставки больше общего количества поставок по подписке (%)',total_deliveries; end if;
  end if;

  insert into public.orders(client_id,subscription_id,delivery_date,sale_price,note,status,sales_channel,title,subscription_delivery_no)
  values(
    p_client_id,
    case when p_sales_channel='subscription' then p_subscription_id else null end,
    p_delivery_date,greatest(0,p_sale_price),nullif(p_note,''),'draft',p_sales_channel,
    nullif(trim(p_title),''),
    case when p_sales_channel='subscription' then p_subscription_delivery_no else null end
  ) returning id into v_order;

  for x in select * from jsonb_array_elements(coalesce(p_reservations,'[]'::jsonb)) loop
    iid=(x->>'item_id')::uuid; q=(x->>'quantity')::numeric;
    select i.avg_cost,
      i.quantity-coalesce((select sum(r.quantity) from public.reservations r join public.orders o on o.id=r.order_id where r.item_id=i.id and o.status='reserved'),0)
    into c,available from public.inventory_items i where i.id=iid and i.archived_at is null for update;
    if c is null then raise exception 'Позиция склада удалена или не найдена'; end if;
    if q<=0 or available<q then raise exception 'Недостаточно свободного остатка'; end if;
    insert into public.reservations(order_id,item_id,quantity,unit_cost) values(v_order,iid,q,c);
  end loop;

  if jsonb_array_length(coalesce(p_reservations,'[]'::jsonb))>0 then
    update public.orders set status='reserved' where id=v_order;
  end if;

  insert into public.history(event_type,description,client_id,order_id,meta)
  values(
    case when jsonb_array_length(coalesce(p_reservations,'[]'::jsonb))>0 then 'Резерв' else 'Заказ' end,
    coalesce(nullif(trim(p_title),''),'Создан заказ'),
    p_client_id,v_order,
    jsonb_build_object('subscription_delivery_no',case when p_sales_channel='subscription' then p_subscription_delivery_no else null end)
  );
  return v_order;
exception when unique_violation then
  raise exception 'Поставка № % по этой подписке уже существует',p_subscription_delivery_no;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_payment(p_client_id uuid, p_amount numeric, p_payment_date date, p_note text, p_subscription_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare pid uuid;
begin
  if p_amount<=0 then raise exception 'Сумма должна быть больше нуля'; end if;
  if not exists(select 1 from public.clients where id=p_client_id) then raise exception 'Клиент не найден'; end if;
  insert into public.payments(client_id,subscription_id,amount,payment_date,note)
  values(p_client_id,p_subscription_id,p_amount,p_payment_date,nullif(p_note,''))
  returning id into pid;
  insert into public.history(event_type,description,client_id,amount)
  values('Оплата','Получена оплата',p_client_id,p_amount);
  return pid;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_purchase(p_purchase_date date, p_supplier text, p_target_order_id uuid, p_items jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_purchase uuid; x jsonb; iid uuid; cat text; nm text; clr text; q numeric; u numeric; oq numeric; oc numeric; cid uuid;
begin
  insert into public.purchases(purchase_date,supplier,target_order_id)
  values(p_purchase_date,nullif(p_supplier,''),p_target_order_id) returning id into v_purchase;

  if p_target_order_id is not null then
    select client_id into cid from public.orders where id=p_target_order_id;
    if cid is null and not exists(select 1 from public.orders where id=p_target_order_id) then raise exception 'Заказ не найден'; end if;
  end if;

  for x in select * from jsonb_array_elements(p_items) loop
    cat=x->>'category'; nm=trim(x->>'name'); clr=coalesce(nullif(trim(x->>'color'),''),'Без цвета');
    q=(x->>'quantity')::numeric; u=(x->>'unit_cost')::numeric;
    if q<=0 or u<0 or nm='' or cat not in ('fresh','dried') then raise exception 'Некорректная закупка'; end if;

    select id,quantity,avg_cost into iid,oq,oc from public.inventory_items
      where archived_at is null and category=cat and lower(name)=lower(nm) and lower(color)=lower(clr) for update;
    if iid is null then
      insert into public.inventory_items(category,name,color,quantity,avg_cost)
      values(cat,nm,clr,q,u) returning id into iid;
    else
      update public.inventory_items
      set avg_cost=case when oq+q=0 then u else ((oq*oc)+(q*u))/(oq+q) end, quantity=oq+q where id=iid;
    end if;

    insert into public.purchase_items(purchase_id,item_id,quantity,unit_cost) values(v_purchase,iid,q,u);

    if p_target_order_id is not null then
      insert into public.reservations(order_id,item_id,quantity,unit_cost)
      values(p_target_order_id,iid,q,u)
      on conflict(order_id,item_id) do update set
        unit_cost=((public.reservations.quantity*public.reservations.unit_cost)+(excluded.quantity*excluded.unit_cost))/(public.reservations.quantity+excluded.quantity),
        quantity=public.reservations.quantity+excluded.quantity;
      update public.orders set status='reserved' where id=p_target_order_id and status in ('draft','reserved');
    end if;
  end loop;

  insert into public.history(event_type,description,client_id,order_id,amount)
  select 'Закупка','Новая закупка',cid,p_target_order_id,sum(quantity*unit_cost)
  from public.purchase_items where purchase_id=v_purchase;
  return v_purchase;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_purchase(p_purchase_date date, p_supplier text, p_target_order_id uuid, p_items jsonb, p_title text, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  meta jsonb:=coalesce((select x->'_meta' from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x where x ? '_meta' limit 1),'{}'::jsonb);
  lines jsonb:=coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x where not (x ? '_meta')),'[]'::jsonb);
  target_client uuid:=nullif(meta->>'target_client_id','')::uuid;
  edit_id uuid:=nullif(meta->>'edit_purchase_id','')::uuid;
  merge_ids uuid[];
begin
  if edit_id is not null then
    return public.crm_edit_purchase(edit_id,lines);
  end if;

  if meta ? 'merge_purchase_ids' then
    select array_agg(value::uuid) into merge_ids from jsonb_array_elements_text(meta->'merge_purchase_ids');
    return public.crm_merge_purchases(merge_ids,p_title,p_supplier);
  end if;

  return public.crm_create_purchase(p_purchase_date,p_supplier,target_client,p_target_order_id,lines,p_title,p_note);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_purchase(p_purchase_date date, p_supplier text, p_target_client_id uuid, p_target_order_id uuid, p_items jsonb, p_title text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_purchase uuid; x jsonb; iid uuid; cat text; nm text; clr text; q numeric; u numeric;
 oq numeric; oc numeric; cid uuid; v_total numeric:=0; v_unit text; v_size numeric;
begin
 if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Добавьте хотя бы одну позицию'; end if;
 cid:=p_target_client_id;
 if cid is not null and not exists(select 1 from public.clients where id=cid and archived_at is null) then raise exception 'Клиент не найден'; end if;
 if p_target_order_id is not null then
   select client_id into cid from public.orders where id=p_target_order_id;
   if not exists(select 1 from public.orders where id=p_target_order_id and status in ('draft','reserved')) then raise exception 'Заказ не найден или уже отгружен'; end if;
   if p_target_client_id is not null and cid is distinct from p_target_client_id then raise exception 'Выбранный заказ относится к другому клиенту'; end if;
 end if;

 insert into public.purchases(purchase_date,supplier,target_client_id,target_order_id,title,note)
 values(p_purchase_date,nullif(p_supplier,''),cid,p_target_order_id,nullif(trim(p_title),''),nullif(trim(p_note),''))
 returning id into v_purchase;

 for x in select * from jsonb_array_elements(p_items) loop
   cat=x->>'category'; nm=trim(x->>'name'); clr=coalesce(nullif(trim(x->>'color'),''),'Без цвета');
   q=(x->>'quantity')::numeric; u=(x->>'unit_cost')::numeric;
   v_unit:=coalesce(nullif(x->>'unit_type',''),'piece');
   v_size:=coalesce(nullif(x->>'units_per_unit','')::numeric,1);
   if v_unit not in ('piece','bunch','package','percent') then raise exception 'Некорректная единица измерения'; end if;
   if v_unit='piece' then v_size:=1; end if;
   if v_size<=0 then raise exception 'Количество штук в единице должно быть больше нуля'; end if;
   if q<=0 or u<0 or nm='' or cat not in ('fresh','dried') then raise exception 'Некорректная позиция закупки'; end if;

   select id,quantity,avg_cost into iid,oq,oc from public.inventory_items
   where archived_at is null and category=cat and lower(name)=lower(nm) and lower(color)=lower(clr) for update;

   if iid is not null and (select unit_type from public.inventory_items where id=iid)<>v_unit then raise exception 'Единица позиции отличается от склада. Сначала измените единицу в карточке позиции или создайте позицию с другим названием'; end if;
   if iid is null then
     insert into public.inventory_items(category,name,color,quantity,avg_cost,unit_type,units_per_unit)
     values(cat,nm,clr,q,u,v_unit,v_size) returning id into iid;
   else
     update public.inventory_items
     set avg_cost=case when oq+q=0 then u else ((oq*oc)+(q*u))/(oq+q) end,
         quantity=oq+q,unit_type=v_unit,units_per_unit=v_size
     where id=iid;
   end if;

   insert into public.purchase_items(purchase_id,item_id,quantity,unit_cost,unit_type,units_per_unit)
   values(v_purchase,iid,q,u,v_unit,v_size);
   v_total:=v_total+(q*u);
 end loop;

 insert into public.history(event_type,description,client_id,order_id,amount,meta)
 values('Закупка',coalesce(nullif(trim(p_title),''),'Новая закупка'),cid,p_target_order_id,v_total,jsonb_build_object('purchase_id',v_purchase));
 return v_purchase;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_writeoff(p_item_id uuid, p_quantity integer, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare iid uuid; c numeric; available numeric; wid uuid;
begin
  select i.id,i.avg_cost,
    i.quantity-coalesce((select sum(r.quantity) from public.reservations r join public.orders o on o.id=r.order_id where r.item_id=i.id and o.status='reserved'),0)
  into iid,c,available from public.inventory_items i where i.id=p_item_id and i.archived_at is null for update;
  if iid is null then raise exception 'Позиция склада удалена или не найдена'; end if;
  if p_quantity<=0 or available<p_quantity then raise exception 'Недостаточно свободного остатка'; end if;
  update public.inventory_items set quantity=quantity-p_quantity where id=p_item_id;
  insert into public.writeoffs(item_id,quantity,unit_cost,reason)
  values(p_item_id,p_quantity,c,p_reason) returning id into wid;
  insert into public.history(event_type,description,amount,meta)
  values('Списание',p_reason,p_quantity*c,jsonb_build_object('writeoff_id',wid,'item_id',p_item_id));
  return wid;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_create_writeoff_fractional(p_item_id uuid, p_quantity numeric, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare iid uuid; c numeric; available numeric; wid uuid;
begin
  select i.id,i.avg_cost,
    i.quantity-coalesce((select sum(r.quantity) from public.reservations r join public.orders o on o.id=r.order_id where r.item_id=i.id and o.status='reserved'),0)
  into iid,c,available from public.inventory_items i where i.id=p_item_id and i.archived_at is null for update;
  if iid is null then raise exception 'Позиция склада удалена или не найдена'; end if;
  if p_quantity<=0 or available<p_quantity then raise exception 'Недостаточно свободного остатка'; end if;
  update public.inventory_items set quantity=quantity-p_quantity where id=p_item_id;
  insert into public.writeoffs(item_id,quantity,unit_cost,reason)
  values(p_item_id,p_quantity,c,p_reason) returning id into wid;
  insert into public.history(event_type,description,amount,meta)
  values('Списание',p_reason,p_quantity*c,jsonb_build_object('writeoff_id',wid,'item_id',p_item_id));
  return wid;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_delete_client(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_client public.clients%rowtype; v_orders text;
begin
  select * into v_client from public.clients where id=p_id and archived_at is null for update;
  if v_client.id is null then raise exception 'Клиент не найден'; end if;

  select string_agg('#'||order_no::text, ', ' order by order_no)
  into v_orders
  from public.orders
  where client_id=p_id and status in ('draft','reserved');

  if v_orders is not null then
    raise exception 'Нельзя удалить клиента: есть незавершённый заказ(ы) %. Сначала завершите или удалите его.',v_orders;
  end if;

  update public.clients set archived_at=now(), status='Завершён' where id=p_id;
  update public.subscriptions set status='completed' where client_id=p_id and status in ('active','paused');

  insert into public.history(event_type,description,client_id)
  values('Удаление','Клиент удалён из рабочего списка (история сохранена)',p_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_delete_expense(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid; oid uuid; amt numeric;
begin
  select client_id,order_id,amount into cid,oid,amt from public.expenses where id=p_id;
  if amt is null then raise exception 'Расход не найден'; end if;
  delete from public.expenses where id=p_id;
  insert into public.history(event_type,description,client_id,order_id,amount)
  values('Удаление','Удалён ошибочный расход',cid,oid,amt);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_delete_inventory_item(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_item public.inventory_items%rowtype;
  v_orders text;
begin
  select * into v_item from public.inventory_items where id=p_id and archived_at is null for update;
  if v_item.id is null then raise exception 'Позиция не найдена'; end if;

  select string_agg('#'||o.order_no::text, ', ' order by o.order_no)
  into v_orders
  from public.reservations r
  join public.orders o on o.id=r.order_id
  where r.item_id=p_id and o.status='reserved';

  if v_orders is not null then
    raise exception 'Нельзя удалить: позиция сейчас зарезервирована в заказе(ах) %.',v_orders;
  end if;

  update public.inventory_items
  set archived_at=now(), quantity=0
  where id=p_id;

  insert into public.history(event_type,description,amount,meta)
  values(
    'Удаление',
    'Позиция удалена из рабочего склада: '||v_item.name||' · '||v_item.color,
    v_item.quantity*v_item.avg_cost,
    jsonb_build_object('item_id',p_id,'removed_quantity',v_item.quantity,'avg_cost',v_item.avg_cost)
  );
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_delete_order(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype;
begin
  select * into o from public.orders where id=p_order_id for update;
  if o.id is null then raise exception 'Заказ не найден'; end if;
  if o.status='shipped' then raise exception 'Отгруженный заказ удалить нельзя'; end if;

  delete from public.reservations where order_id=p_order_id;
  update public.expenses set order_id=null where order_id=p_order_id;
  update public.purchases set target_order_id=null where target_order_id=p_order_id;

  insert into public.history(event_type,description,client_id,meta)
  values('Удаление','Удалён заказ '||coalesce(nullif(o.title,''),'#'||o.order_no),o.client_id,jsonb_build_object('deleted_order_no',o.order_no));
  delete from public.orders where id=p_order_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_delete_payment(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid; amt numeric;
begin
  select client_id,amount into cid,amt from public.payments where id=p_id;
  if cid is null then raise exception 'Оплата не найдена'; end if;
  delete from public.payments where id=p_id;
  insert into public.history(event_type,description,client_id,amount) values('Удаление','Удалена ошибочная оплата',cid,amt);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_delete_purchase(p_purchase_id uuid)
 RETURNS void LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $function$
DECLARE ln record; stock numeric; reserved numeric;
BEGIN
 PERFORM 1 FROM public.purchases WHERE id=p_purchase_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Закупка не найдена'; END IF;
 FOR ln IN SELECT pi.item_id,sum(pi.quantity) qty,sum(pi.quantity*pi.unit_cost) value FROM public.purchase_items pi WHERE pi.purchase_id=p_purchase_id GROUP BY pi.item_id ORDER BY pi.item_id LOOP
  SELECT quantity INTO stock FROM public.inventory_items WHERE id=ln.item_id FOR UPDATE;
  SELECT coalesce(sum(r.quantity),0) INTO reserved FROM public.reservations r JOIN public.orders o ON o.id=r.order_id WHERE r.item_id=ln.item_id AND o.status='reserved';
  IF stock-ln.qty<reserved THEN RAISE EXCEPTION 'Нельзя удалить закупку: материал уже использован или зарезервирован. Сначала измените связанные операции'; END IF;
  UPDATE public.inventory_items SET quantity=stock-ln.qty,avg_cost=CASE WHEN stock=ln.qty THEN 0 ELSE greatest(0,(stock*avg_cost-ln.value)/(stock-ln.qty)) END WHERE id=ln.item_id;
 END LOOP;
 DELETE FROM public.history WHERE meta->>'purchase_id'=p_purchase_id::text;
 DELETE FROM public.purchase_items WHERE purchase_id=p_purchase_id;
 DELETE FROM public.purchases WHERE id=p_purchase_id;
END $function$;

CREATE OR REPLACE FUNCTION public.crm_delete_writeoff(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare iid uuid; qty numeric; amt numeric; moved numeric;
begin
  select item_id,quantity,quantity*unit_cost into iid,qty,amt from public.writeoffs where id=p_id for update;
  if iid is null then raise exception 'Списание не найдено'; end if;

  update public.inventory_items set quantity=quantity+qty where id=iid and archived_at is null;
  get diagnostics moved=row_count;

  if moved=0 then
    update public.inventory_items active
      set quantity=active.quantity+qty
    from public.inventory_items old
    where old.id=iid and old.archived_at is not null
      and active.archived_at is null and active.category=old.category
      and lower(active.name)=lower(old.name) and lower(active.color)=lower(old.color);
    get diagnostics moved=row_count;
  end if;

  if moved=0 then
    update public.inventory_items set archived_at=null,quantity=qty where id=iid;
  end if;

  delete from public.writeoffs where id=p_id;
  insert into public.history(event_type,description,amount) values('Удаление','Списание отменено, товар возвращён на склад',amt);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_edit_purchase(p_purchase_id uuid, p_items jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 p public.purchases%rowtype; rec record;
 cur_qty numeric; cur_cost numeric; new_stock numeric; new_value numeric;
 reserved_total numeric; excess numeric; rr record; total_amount numeric;
 x jsonb; v_unit text; v_size numeric; v_color text;
begin
 select * into p from public.purchases where id=p_purchase_id for update;
 if p.id is null then raise exception 'Закупка не найдена'; end if;
 if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'В закупке должна остаться хотя бы одна позиция'; end if;

 for x in select * from jsonb_array_elements(p_items) loop
   v_unit:=coalesce(nullif(x->>'unit_type',''),'piece');
   v_size:=coalesce(nullif(x->>'units_per_unit','')::numeric,1);
   if v_unit not in ('piece','bunch','package','percent') then raise exception 'Некорректная единица измерения'; end if;
   if v_unit='piece' then v_size:=1; end if;
   if v_size<=0 then raise exception 'Количество штук в единице должно быть больше нуля'; end if;
   v_color:=coalesce(nullif(trim(x->>'color'),''),(select color from public.inventory_items where id=(x->>'item_id')::uuid),'Без цвета');
   perform public.crm_convert_inventory_unit((x->>'item_id')::uuid,v_unit,coalesce((x->>'conversion_base')::numeric,1));
   update public.inventory_items
   set color=v_color,unit_type=v_unit,units_per_unit=v_size
   where id=(x->>'item_id')::uuid and archived_at is null;
 end loop;

 for rec in
   with old_rows as (
     select item_id,sum(quantity)::numeric old_qty,sum(quantity*unit_cost)::numeric old_value
     from public.purchase_items where purchase_id=p_purchase_id group by item_id
   ), new_rows as (
     select (entry.value->>'item_id')::uuid item_id,
            sum((entry.value->>'quantity')::numeric)::numeric new_qty,
            sum(((entry.value->>'quantity')::numeric)*((entry.value->>'unit_cost')::numeric))::numeric new_value
     from jsonb_array_elements(p_items) AS entry(value) group by (entry.value->>'item_id')::uuid
   )
   select coalesce(o.item_id,n.item_id) item_id,
          coalesce(o.old_qty,0) old_qty,coalesce(o.old_value,0) old_value,
          coalesce(n.new_qty,0) new_qty,coalesce(n.new_value,0) new_value
   from old_rows o full join new_rows n on n.item_id=o.item_id
 loop
   if rec.new_qty<0 or rec.new_value<0 then raise exception 'Количество и цена не могут быть отрицательными'; end if;
   select quantity,avg_cost into cur_qty,cur_cost from public.inventory_items where id=rec.item_id for update;
   if cur_qty is null then raise exception 'Позиция склада не найдена'; end if;
   new_stock:=cur_qty+(rec.new_qty-rec.old_qty);
   if new_stock<0 then raise exception 'Нельзя уменьшить закупку: часть этой позиции уже использована в отгрузках'; end if;
   new_value:=(cur_qty*cur_cost)+(rec.new_value-rec.old_value);
   update public.inventory_items set quantity=new_stock,
     avg_cost=case when new_stock=0 then 0 else greatest(0,new_value/new_stock) end where id=rec.item_id;

   select coalesce(sum(rs.quantity),0) into reserved_total
   from public.reservations rs join public.orders oo on oo.id=rs.order_id
   where rs.item_id=rec.item_id and oo.status='reserved';
   excess:=greatest(0,reserved_total-new_stock);
   if excess>0 then raise exception 'Нельзя уменьшить закупку: материал зарезервирован в заказах. Сначала измените резерв'; end if;
 end loop;

 delete from public.purchase_items where purchase_id=p_purchase_id;
 insert into public.purchase_items(purchase_id,item_id,quantity,unit_cost,unit_type,units_per_unit)
 select p_purchase_id,(entry.value->>'item_id')::uuid,(entry.value->>'quantity')::numeric,(entry.value->>'unit_cost')::numeric,
        coalesce(nullif(entry.value->>'unit_type',''),'piece'),
        case when coalesce(nullif(entry.value->>'unit_type',''),'piece')='piece' then 1 else coalesce(nullif(entry.value->>'units_per_unit','')::numeric,1) end
 from jsonb_array_elements(p_items) AS entry(value)
 where (entry.value->>'quantity')::numeric>0 and (entry.value->>'unit_cost')::numeric>=0;

 if p.target_order_id is not null then
   update public.reservations rs set unit_cost=x.avg_cost
   from (select item_id,sum(quantity*unit_cost)/nullif(sum(quantity),0) avg_cost
         from public.purchase_items where purchase_id=p_purchase_id group by item_id) x
   where rs.order_id=p.target_order_id and rs.item_id=x.item_id;
 end if;

 update public.orders oo set status='draft'
 where oo.status='reserved' and not exists(select 1 from public.reservations rs where rs.order_id=oo.id);

 select coalesce(sum(quantity*unit_cost),0) into total_amount from public.purchase_items where purchase_id=p_purchase_id;
 delete from public.history where meta->>'purchase_id'=p_purchase_id::text;
 insert into public.history(event_type,description,client_id,order_id,amount,meta)
 values('Закупка',coalesce(p.title,'Закупка')||' · изменена',p.target_client_id,p.target_order_id,total_amount,jsonb_build_object('purchase_id',p_purchase_id));
 return p_purchase_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_merge_purchases(p_purchase_ids uuid[], p_title text, p_supplier text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  new_id uuid; ids_count numeric; common_client uuid; common_order uuid; merged_date date; total_amount numeric;
begin
  ids_count:=coalesce(array_length(p_purchase_ids,1),0);
  if ids_count<2 then raise exception 'Выберите минимум две закупки'; end if;
  if (select count(*) from public.purchases where id=any(p_purchase_ids))<>ids_count then raise exception 'Одна из закупок не найдена'; end if;

  select max(purchase_date),
    case when count(distinct coalesce(target_client_id::text,'NULL'))=1 then (array_agg(target_client_id))[1] else null end,
    case when count(distinct coalesce(target_order_id::text,'NULL'))=1 then (array_agg(target_order_id))[1] else null end
  into merged_date,common_client,common_order
  from public.purchases where id=any(p_purchase_ids);

  insert into public.purchases(purchase_date,supplier,target_client_id,target_order_id,title,note)
  values(merged_date,nullif(trim(p_supplier),''),common_client,common_order,coalesce(nullif(trim(p_title),''),'Объединённая закупка'),'Объединено из нескольких закупок')
  returning id into new_id;

  update public.purchase_items set purchase_id=new_id where purchase_id=any(p_purchase_ids);

  delete from public.history where meta->>'purchase_id'=any(select x::text from unnest(p_purchase_ids) x);
  delete from public.purchases where id=any(p_purchase_ids);

  select coalesce(sum(quantity*unit_cost),0) into total_amount from public.purchase_items where purchase_id=new_id;
  insert into public.history(event_type,description,client_id,order_id,amount,meta)
  values('Закупка',coalesce(nullif(trim(p_title),''),'Объединённая закупка'),common_client,common_order,total_amount,
    jsonb_build_object('purchase_id',new_id,'merged_from',to_jsonb(p_purchase_ids)));
  return new_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_refresh_subscription_status(p_subscription_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if p_subscription_id is null then return; end if;
  update public.subscriptions s
  set status=case
    when (select count(*) from public.orders o where o.subscription_id=s.id and o.status='shipped') >= s.months*s.deliveries_per_month
      then 'completed'
    when s.status='completed' then 'active'
    else s.status
  end
  where s.id=p_subscription_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_release_reserve(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare oid uuid; cid uuid; st text;
begin
  select id,client_id,status into oid,cid,st from public.orders where id=p_order_id for update;
  if oid is null then raise exception 'Заказ не найден'; end if;
  if st<>'reserved' then raise exception 'Активного резерва нет'; end if;
  delete from public.reservations where order_id=p_order_id;
  update public.orders set status='draft' where id=p_order_id;
  insert into public.history(event_type,description,client_id,order_id)
  values('Снят резерв','Резерв по заказу удалён',cid,p_order_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_ship_order(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_order public.orders%rowtype;
  v_res record;
begin
  select * into v_order from public.orders where id=p_order_id for update;
  if v_order.id is null then raise exception 'Заказ не найден'; end if;
  if v_order.status<>'reserved' then raise exception 'Сначала нужен резерв'; end if;

  for v_res in
    select rr.item_id,rr.quantity,i.quantity as stock
    from public.reservations rr
    join public.inventory_items i on i.id=rr.item_id
    where rr.order_id=p_order_id
    for update of i
  loop
    if v_res.stock<v_res.quantity then
      raise exception 'Недостаточно товара на складе';
    end if;
  end loop;

  update public.inventory_items i
  set quantity=i.quantity-res.quantity
  from public.reservations res
  where res.order_id=p_order_id and res.item_id=i.id;

  update public.orders
  set status='shipped',shipped_at=now()
  where id=p_order_id;

  update public.subscriptions s
  set status=case
    when (
      select count(*) from public.orders oo
      where oo.subscription_id=s.id and oo.status='shipped'
    ) >= s.months*s.deliveries_per_month
    then 'completed' else s.status end
  where s.id=v_order.subscription_id;

  insert into public.history(event_type,description,client_id,order_id,amount)
  values('Отгрузка','Заказ подтверждён и отгружен',v_order.client_id,p_order_id,v_order.sale_price);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_snapshot()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'clients', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from public.clients t),'[]'::jsonb),
    'subscriptions', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from public.subscriptions t),'[]'::jsonb),
    'inventory', coalesce((select jsonb_agg(to_jsonb(t) order by t.name) from public.inventory_items t),'[]'::jsonb),
    'orders', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from public.orders t),'[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(to_jsonb(t)) from public.reservations t),'[]'::jsonb),
    'purchases', coalesce((select jsonb_agg(to_jsonb(t) order by t.purchase_date desc) from public.purchases t),'[]'::jsonb),
    'purchaseItems', coalesce((select jsonb_agg(to_jsonb(t)) from public.purchase_items t),'[]'::jsonb),
    'payments', coalesce((select jsonb_agg(to_jsonb(t) order by t.payment_date desc) from public.payments t),'[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(to_jsonb(t) order by t.expense_date desc) from public.expenses t),'[]'::jsonb),
    'writeoffs', coalesce((select jsonb_agg(to_jsonb(t) order by t.writeoff_date desc) from public.writeoffs t),'[]'::jsonb),
    'history', coalesce((select jsonb_agg(to_jsonb(x) order by x.event_date desc) from (select * from public.history order by event_date desc limit 500) x),'[]'::jsonb),
    'settings', coalesce((select to_jsonb(t) from public.app_settings t where id=1),'{"id":1,"show_markup":false,"markup_multiplier":2.5}'::jsonb)
  );
$function$
;

CREATE OR REPLACE FUNCTION public.crm_transfer_reservation(p_from_order uuid, p_to_order uuid, p_item_id uuid, p_quantity integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare src public.reservations%rowtype; target_status text;
begin
  if p_from_order=p_to_order then raise exception 'Выберите другой заказ'; end if;
  if p_quantity<=0 then raise exception 'Количество должно быть больше нуля'; end if;

  select * into src from public.reservations
  where order_id=p_from_order and item_id=p_item_id for update;
  if src.id is null or src.quantity<p_quantity then raise exception 'В исходном резерве недостаточно цветов'; end if;

  select status into target_status from public.orders where id=p_to_order for update;
  if target_status is null then raise exception 'Заказ-получатель не найден'; end if;
  if target_status not in ('draft','reserved') then raise exception 'Переносить можно только в черновик или активный резерв'; end if;

  if src.quantity=p_quantity then delete from public.reservations where id=src.id;
  else update public.reservations set quantity=quantity-p_quantity where id=src.id;
  end if;

  insert into public.reservations(order_id,item_id,quantity,unit_cost)
  values(p_to_order,p_item_id,p_quantity,src.unit_cost)
  on conflict(order_id,item_id) do update set
    unit_cost=((public.reservations.quantity*public.reservations.unit_cost)+(excluded.quantity*excluded.unit_cost))/(public.reservations.quantity+excluded.quantity),
    quantity=public.reservations.quantity+excluded.quantity;

  update public.orders set status='reserved' where id=p_to_order;
  if not exists(select 1 from public.reservations where order_id=p_from_order) then
    update public.orders set status='draft' where id=p_from_order and status='reserved';
  end if;

  insert into public.history(event_type,description,order_id,meta)
  values('Перенос резерва','Перенесено '||p_quantity||' шт. между заказами',p_to_order,
    jsonb_build_object('from_order',p_from_order,'to_order',p_to_order,'item_id',p_item_id,'quantity',p_quantity));
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_transfer_reservation_fractional(p_from_order uuid, p_to_order uuid, p_item_id uuid, p_quantity numeric)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare src public.reservations%rowtype; target_status text;
begin
  if p_from_order=p_to_order then raise exception 'Выберите другой заказ'; end if;
  if p_quantity<=0 then raise exception 'Количество должно быть больше нуля'; end if;

  select * into src from public.reservations
  where order_id=p_from_order and item_id=p_item_id for update;
  if src.id is null or src.quantity<p_quantity then raise exception 'В исходном резерве недостаточно цветов'; end if;

  select status into target_status from public.orders where id=p_to_order for update;
  if target_status is null then raise exception 'Заказ-получатель не найден'; end if;
  if target_status not in ('draft','reserved') then raise exception 'Переносить можно только в черновик или активный резерв'; end if;

  if src.quantity=p_quantity then delete from public.reservations where id=src.id;
  else update public.reservations set quantity=quantity-p_quantity where id=src.id;
  end if;

  insert into public.reservations(order_id,item_id,quantity,unit_cost)
  values(p_to_order,p_item_id,p_quantity,src.unit_cost)
  on conflict(order_id,item_id) do update set
    unit_cost=((public.reservations.quantity*public.reservations.unit_cost)+(excluded.quantity*excluded.unit_cost))/(public.reservations.quantity+excluded.quantity),
    quantity=public.reservations.quantity+excluded.quantity;

  update public.orders set status='reserved' where id=p_to_order;
  if not exists(select 1 from public.reservations where order_id=p_from_order) then
    update public.orders set status='draft' where id=p_from_order and status='reserved';
  end if;

  insert into public.history(event_type,description,order_id,meta)
  values('Перенос резерва','Перенесено '||p_quantity||' шт. между заказами',p_to_order,
    jsonb_build_object('from_order',p_from_order,'to_order',p_to_order,'item_id',p_item_id,'quantity',p_quantity));
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_client_full(p_id uuid, p_company_name text, p_inn text, p_contact_name text, p_contact_info text, p_status text, p_work_model text, p_notes text, p_subscription jsonb, p_default_price numeric, p_mark_paid boolean)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare sid uuid; v_paid numeric;
begin
  if p_work_model not in ('subscription','durable','retail') then raise exception 'Некорректный формат клиента'; end if;
  if not exists(select 1 from public.clients where id=p_id) then raise exception 'Клиент не найден'; end if;

  update public.clients set company_name=p_company_name,inn=nullif(p_inn,''),contact_name=nullif(p_contact_name,''),
    contact_info=nullif(p_contact_info,''),status=p_status,work_model=p_work_model,notes=nullif(p_notes,''),
    default_price=greatest(0,coalesce(p_default_price,0))
  where id=p_id;

  select id into sid from public.subscriptions where client_id=p_id order by created_at desc limit 1;

  if p_work_model='subscription' and p_subscription is not null then
    if sid is null then
      insert into public.subscriptions(client_id,start_date,months,deliveries_per_month,bouquet_price,discount_percent,status)
      values(p_id,(p_subscription->>'start_date')::date,(p_subscription->>'months')::numeric,
        (p_subscription->>'deliveries_per_month')::numeric,(p_subscription->>'bouquet_price')::numeric,
        coalesce((p_subscription->>'discount_percent')::numeric,0),
        coalesce(nullif(p_subscription->>'status',''),'active'));
    else
      update public.subscriptions set
        start_date=(p_subscription->>'start_date')::date,
        months=(p_subscription->>'months')::numeric,
        deliveries_per_month=(p_subscription->>'deliveries_per_month')::numeric,
        bouquet_price=(p_subscription->>'bouquet_price')::numeric,
        discount_percent=coalesce((p_subscription->>'discount_percent')::numeric,0),
        status=coalesce(nullif(p_subscription->>'status',''),'active')
      where id=sid;
    end if;
  elsif sid is not null and exists(select 1 from public.subscriptions where id=sid and status='active') then
    update public.subscriptions set status='completed' where id=sid;
  end if;

  if coalesce(p_mark_paid,false) and p_work_model<>'subscription' then
    select coalesce(sum(amount),0) into v_paid from public.payments where client_id=p_id;
    if v_paid=0 and coalesce(p_default_price,0)>0 then
      insert into public.payments(client_id,subscription_id,amount,payment_date,note)
      values(p_id,null,p_default_price,current_date,'Отмечено оплачено в карточке клиента');
    end if;
  end if;

  insert into public.history(event_type,description,client_id)
  values('Клиент','Карточка клиента отредактирована',p_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_expense(p_id uuid, p_category text, p_description text, p_amount numeric, p_order_id uuid, p_expense_date date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid;
begin
  if p_amount<=0 then raise exception 'Сумма должна быть больше нуля'; end if;
  if not exists(select 1 from public.expenses where id=p_id) then raise exception 'Расход не найден'; end if;
  if p_order_id is not null then select client_id into cid from public.orders where id=p_order_id; end if;
  update public.expenses set expense_date=p_expense_date,category=p_category,description=nullif(p_description,''),
    amount=p_amount,client_id=cid,order_id=p_order_id where id=p_id;
  insert into public.history(event_type,description,client_id,order_id,amount)
  values('Расход','Расход отредактирован',cid,p_order_id,p_amount);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_inventory_item(p_id uuid, p_category text, p_name text, p_color text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if p_category not in ('fresh','dried') then raise exception 'Некорректный склад'; end if;
  if trim(coalesce(p_name,''))='' then raise exception 'Укажите название позиции'; end if;
  if not exists(select 1 from public.inventory_items where id=p_id) then raise exception 'Позиция не найдена'; end if;
  update public.inventory_items
  set category=p_category,name=trim(p_name),color=coalesce(nullif(trim(p_color),''),'Без цвета')
  where id=p_id;
  insert into public.history(event_type,description) values('Склад','Позиция склада отредактирована');
exception when unique_violation then
  raise exception 'Такая позиция уже существует';
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_inventory_item(p_id uuid, p_category text, p_name text, p_color text, p_avg_cost numeric)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if p_category not in ('fresh','dried') then raise exception 'Некорректный склад'; end if;
  if trim(coalesce(p_name,''))='' then raise exception 'Укажите название позиции'; end if;
  if p_avg_cost<0 then raise exception 'Цена не может быть отрицательной'; end if;
  if not exists(select 1 from public.inventory_items where id=p_id and archived_at is null) then raise exception 'Позиция не найдена'; end if;

  update public.inventory_items
  set category=p_category,name=trim(p_name),color=coalesce(nullif(trim(p_color),''),'Без цвета'),avg_cost=p_avg_cost
  where id=p_id;

  insert into public.history(event_type,description,meta)
  values('Склад','Позиция склада отредактирована',jsonb_build_object('item_id',p_id,'avg_cost',p_avg_cost));
exception when unique_violation then
  raise exception 'Такая активная позиция уже существует';
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_inventory_item(p_id uuid, p_category text, p_name text, p_color text, p_avg_cost numeric, p_unit_type text DEFAULT 'piece'::text, p_units_per_unit integer DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
 if p_category not in ('fresh','dried') then raise exception 'Некорректный склад'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'Укажите название позиции'; end if;
 if p_avg_cost<0 then raise exception 'Цена не может быть отрицательной'; end if;
 if p_unit_type not in ('piece','bunch','package','percent') then raise exception 'Некорректная единица измерения'; end if;
 if p_units_per_unit<=0 then raise exception 'Количество штук в единице должно быть больше нуля'; end if;
 if p_unit_type='piece' then p_units_per_unit:=1; end if;
 if not exists(select 1 from public.inventory_items where id=p_id and archived_at is null) then raise exception 'Позиция не найдена'; end if;
 update public.inventory_items
 set category=p_category,name=trim(p_name),color=coalesce(nullif(trim(p_color),''),'Без цвета'),
     avg_cost=p_avg_cost,unit_type=p_unit_type,units_per_unit=p_units_per_unit
 where id=p_id;
 insert into public.history(event_type,description,meta)
 values('Склад','Позиция склада отредактирована',
   jsonb_build_object('item_id',p_id,'avg_cost',p_avg_cost,'unit_type',p_unit_type,'units_per_unit',p_units_per_unit));
exception when unique_violation then raise exception 'Такая активная позиция уже существует';
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_order(p_order_id uuid, p_client_id uuid, p_subscription_id uuid, p_delivery_date date, p_sale_price numeric, p_note text, p_reservations jsonb, p_sales_channel text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  o public.orders%rowtype; old_sub uuid;
  x jsonb;iid uuid;q numeric;c numeric;available numeric;total_deliveries numeric;line_cost numeric;
  oldr record; old_costs jsonb:='{}'::jsonb;
  v_meta jsonb:=coalesce((select e->'_meta' from jsonb_array_elements(coalesce(p_reservations,'[]'::jsonb)) e where e ? '_meta' limit 1),'{}'::jsonb);
  v_title text:=nullif(trim(coalesce(v_meta->>'title','')),'');
  v_delivery_no numeric:=nullif(v_meta->>'subscription_delivery_no','')::numeric;
  v_lines jsonb:=coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(p_reservations,'[]'::jsonb)) e where not (e ? '_meta')),'[]'::jsonb);
  was_shipped boolean;
begin
  select * into o from public.orders where id=p_order_id for update;
  if o.id is null then raise exception 'Заказ не найден'; end if;
  old_sub:=o.subscription_id; was_shipped:=o.status='shipped';

  if p_sales_channel not in ('subscription','one_off','retail') then raise exception 'Некорректный формат продажи'; end if;
  if p_sales_channel<>'retail' and p_client_id is null then raise exception 'Выберите клиента'; end if;
  if p_client_id is not null and not exists(select 1 from public.clients where id=p_client_id and archived_at is null) then raise exception 'Клиент удалён или недоступен'; end if;

  if p_sales_channel='subscription' then
    if p_subscription_id is null then raise exception 'У клиента нет активной подписки'; end if;
    if v_delivery_no is null or v_delivery_no<=0 then raise exception 'Укажите номер поставки по подписке'; end if;
    select months*deliveries_per_month into total_deliveries
    from public.subscriptions where id=p_subscription_id and client_id=p_client_id;
    if total_deliveries is null then raise exception 'Подписка не найдена'; end if;
    if v_delivery_no>total_deliveries then raise exception 'Номер поставки больше общего количества поставок по подписке (%)',total_deliveries; end if;
  end if;

  if was_shipped then
    for oldr in select item_id,quantity,unit_cost from public.reservations where order_id=p_order_id loop
      old_costs:=old_costs||jsonb_build_object(oldr.item_id::text,oldr.unit_cost);
      update public.inventory_items i
      set avg_cost=case when i.quantity+oldr.quantity=0 then i.avg_cost
                        else ((i.quantity*i.avg_cost)+(oldr.quantity*oldr.unit_cost))/(i.quantity+oldr.quantity) end,
          quantity=i.quantity+oldr.quantity
      where i.id=oldr.item_id;
    end loop;
  end if;

  delete from public.reservations where order_id=p_order_id;

  update public.orders set
    client_id=p_client_id,
    subscription_id=case when p_sales_channel='subscription' then p_subscription_id else null end,
    delivery_date=p_delivery_date,
    sale_price=greatest(0,p_sale_price),
    note=nullif(p_note,''),
    sales_channel=p_sales_channel,
    title=v_title,
    subscription_delivery_no=case when p_sales_channel='subscription' then v_delivery_no else null end,
    status=case when was_shipped then 'shipped' else 'draft' end
  where id=p_order_id;

  for x in select * from jsonb_array_elements(v_lines) loop
    iid=(x->>'item_id')::uuid;q=(x->>'quantity')::numeric;
    select i.avg_cost,
      i.quantity-coalesce((select sum(r.quantity) from public.reservations r join public.orders oo on oo.id=r.order_id where r.item_id=i.id and oo.status='reserved'),0)
    into c,available
    from public.inventory_items i where i.id=iid and i.archived_at is null for update;

    if c is null then raise exception 'Позиция склада удалена или не найдена'; end if;
    if q<=0 or available<q then raise exception 'Недостаточно свободного остатка для обновлённого заказа'; end if;

    line_cost:=case when was_shipped and old_costs ? iid::text then (old_costs->>iid::text)::numeric else c end;
    insert into public.reservations(order_id,item_id,quantity,unit_cost) values(p_order_id,iid,q,line_cost);

    if was_shipped then
      update public.inventory_items set quantity=quantity-q where id=iid;
    end if;
  end loop;

  if not was_shipped and jsonb_array_length(v_lines)>0 then
    update public.orders set status='reserved' where id=p_order_id;
  end if;

  perform public.crm_refresh_subscription_status(old_sub);
  perform public.crm_refresh_subscription_status(case when p_sales_channel='subscription' then p_subscription_id else null end);

  insert into public.history(event_type,description,client_id,order_id,amount,meta)
  values('Заказ',case when was_shipped then 'Отгруженный заказ пересчитан' else 'Заказ отредактирован' end,p_client_id,p_order_id,p_sale_price,
    jsonb_build_object('recalculated',was_shipped));
exception when unique_violation then
  raise exception 'Поставка № % по этой подписке уже существует',v_delivery_no;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_order_v2(p_order_id uuid, p_client_id uuid, p_subscription_id uuid, p_delivery_date date, p_sale_price numeric, p_note text, p_reservations jsonb, p_sales_channel text, p_title text, p_subscription_delivery_no integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; x jsonb; iid uuid; q numeric; c numeric; available numeric; total_deliveries numeric;
begin
  select * into o from public.orders where id=p_order_id for update;
  if o.id is null then raise exception 'Заказ не найден'; end if;
  if o.status='shipped' then raise exception 'Отгруженный заказ нельзя редактировать'; end if;
  if p_sales_channel not in ('subscription','one_off','retail') then raise exception 'Некорректный формат продажи'; end if;
  if p_sales_channel<>'retail' and p_client_id is null then raise exception 'Выберите клиента'; end if;
  if p_client_id is not null and not exists(select 1 from public.clients where id=p_client_id and archived_at is null) then raise exception 'Клиент удалён или недоступен'; end if;

  if p_sales_channel='subscription' then
    if p_subscription_id is null then raise exception 'У клиента нет активной подписки'; end if;
    if p_subscription_delivery_no is null or p_subscription_delivery_no<=0 then raise exception 'Укажите номер поставки по подписке'; end if;
    select months*deliveries_per_month into total_deliveries from public.subscriptions where id=p_subscription_id and client_id=p_client_id;
    if total_deliveries is null then raise exception 'Подписка не найдена'; end if;
    if p_subscription_delivery_no>total_deliveries then raise exception 'Номер поставки больше общего количества поставок по подписке (%)',total_deliveries; end if;
  end if;

  delete from public.reservations where order_id=p_order_id;

  update public.orders
  set client_id=p_client_id,
      subscription_id=case when p_sales_channel='subscription' then p_subscription_id else null end,
      delivery_date=p_delivery_date,
      sale_price=greatest(0,p_sale_price),
      note=nullif(p_note,''),
      sales_channel=p_sales_channel,
      title=nullif(trim(p_title),''),
      subscription_delivery_no=case when p_sales_channel='subscription' then p_subscription_delivery_no else null end,
      status='draft'
  where id=p_order_id;

  for x in select * from jsonb_array_elements(coalesce(p_reservations,'[]'::jsonb)) loop
    iid=(x->>'item_id')::uuid; q=(x->>'quantity')::numeric;
    select i.avg_cost,
      i.quantity-coalesce((select sum(r.quantity) from public.reservations r join public.orders oo on oo.id=r.order_id where r.item_id=i.id and oo.status='reserved'),0)
    into c,available from public.inventory_items i where i.id=iid and i.archived_at is null for update;
    if c is null then raise exception 'Позиция склада удалена или не найдена'; end if;
    if q<=0 or available<q then raise exception 'Недостаточно свободного остатка для нового резерва'; end if;
    insert into public.reservations(order_id,item_id,quantity,unit_cost) values(p_order_id,iid,q,c);
  end loop;

  if jsonb_array_length(coalesce(p_reservations,'[]'::jsonb))>0 then
    update public.orders set status='reserved' where id=p_order_id;
  end if;

  insert into public.history(event_type,description,client_id,order_id)
  values('Заказ','Заказ отредактирован',p_client_id,p_order_id);
exception when unique_violation then
  raise exception 'Поставка № % по этой подписке уже существует',p_subscription_delivery_no;
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_payment(p_id uuid, p_client_id uuid, p_amount numeric, p_payment_date date, p_note text, p_subscription_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if p_amount<=0 then raise exception 'Сумма должна быть больше нуля'; end if;
  if not exists(select 1 from public.payments where id=p_id) then raise exception 'Оплата не найдена'; end if;
  if not exists(select 1 from public.clients where id=p_client_id) then raise exception 'Клиент не найден'; end if;
  update public.payments set client_id=p_client_id,subscription_id=p_subscription_id,amount=p_amount,
    payment_date=p_payment_date,note=nullif(p_note,'') where id=p_id;
  insert into public.history(event_type,description,client_id,amount) values('Оплата','Оплата отредактирована',p_client_id,p_amount);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_writeoff(p_id uuid, p_item_id uuid, p_quantity integer, p_reason text, p_writeoff_date date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare old_item uuid; old_qty numeric; new_cost numeric; available numeric;
begin
  select item_id,quantity into old_item,old_qty from public.writeoffs where id=p_id for update;
  if old_item is null then raise exception 'Списание не найдено'; end if;

  -- restore previous quantity. If old item was archived, restore into an active matching item when possible.
  if exists(select 1 from public.inventory_items where id=old_item and archived_at is null) then
    update public.inventory_items set quantity=quantity+old_qty where id=old_item;
  else
    update public.inventory_items active
      set quantity=active.quantity+old_qty
    from public.inventory_items old
    where old.id=old_item and old.archived_at is not null
      and active.archived_at is null and active.category=old.category
      and lower(active.name)=lower(old.name) and lower(active.color)=lower(old.color);
  end if;

  select i.avg_cost,
    i.quantity-coalesce((select sum(r.quantity) from public.reservations r join public.orders o on o.id=r.order_id where r.item_id=i.id and o.status='reserved'),0)
  into new_cost,available from public.inventory_items i where i.id=p_item_id and i.archived_at is null for update;
  if new_cost is null or p_quantity<=0 or available<p_quantity then raise exception 'Недостаточно свободного остатка'; end if;

  update public.inventory_items set quantity=quantity-p_quantity where id=p_item_id;
  update public.writeoffs set item_id=p_item_id,quantity=p_quantity,unit_cost=new_cost,reason=p_reason,writeoff_date=p_writeoff_date where id=p_id;
  insert into public.history(event_type,description,amount) values('Списание','Списание отредактировано',p_quantity*new_cost);
end $function$
;

CREATE OR REPLACE FUNCTION public.crm_update_writeoff_fractional(p_id uuid, p_item_id uuid, p_quantity numeric, p_reason text, p_writeoff_date date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare old_item uuid; old_qty numeric; new_cost numeric; available numeric;
begin
  select item_id,quantity into old_item,old_qty from public.writeoffs where id=p_id for update;
  if old_item is null then raise exception 'Списание не найдено'; end if;

  -- restore previous quantity. If old item was archived, restore into an active matching item when possible.
  if exists(select 1 from public.inventory_items where id=old_item and archived_at is null) then
    update public.inventory_items set quantity=quantity+old_qty where id=old_item;
  else
    update public.inventory_items active
      set quantity=active.quantity+old_qty
    from public.inventory_items old
    where old.id=old_item and old.archived_at is not null
      and active.archived_at is null and active.category=old.category
      and lower(active.name)=lower(old.name) and lower(active.color)=lower(old.color);
  end if;

  select i.avg_cost,
    i.quantity-coalesce((select sum(r.quantity) from public.reservations r join public.orders o on o.id=r.order_id where r.item_id=i.id and o.status='reserved'),0)
  into new_cost,available from public.inventory_items i where i.id=p_item_id and i.archived_at is null for update;
  if new_cost is null or p_quantity<=0 or available<p_quantity then raise exception 'Недостаточно свободного остатка'; end if;

  update public.inventory_items set quantity=quantity-p_quantity where id=p_item_id;
  update public.writeoffs set item_id=p_item_id,quantity=p_quantity,unit_cost=new_cost,reason=p_reason,writeoff_date=p_writeoff_date where id=p_id;
  insert into public.history(event_type,description,amount) values('Списание','Списание отредактировано',p_quantity*new_cost);
end $function$
;


CREATE OR REPLACE FUNCTION public.crm_convert_inventory_unit(p_id uuid,p_unit text,p_base numeric DEFAULT 1)
RETURNS void LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $function$
DECLARE old_unit text; factor numeric;
BEGIN
 SELECT unit_type INTO old_unit FROM public.inventory_items WHERE id=p_id FOR UPDATE;
 IF old_unit IS NULL THEN RAISE EXCEPTION 'Позиция не найдена'; END IF;
 IF p_unit NOT IN ('piece','bunch','package','percent') OR p_base IS NULL OR p_base<=0 THEN RAISE EXCEPTION 'Некорректная единица или база пересчёта'; END IF;
 IF old_unit=p_unit THEN RETURN; END IF;
 IF old_unit<>'percent' AND p_unit<>'percent' THEN RETURN; END IF;
 factor:=CASE WHEN p_unit='percent' THEN 100/p_base ELSE p_base/100 END;
 UPDATE public.inventory_items SET quantity=quantity*factor,avg_cost=avg_cost/factor,unit_type=p_unit WHERE id=p_id;
 UPDATE public.purchase_items SET quantity=quantity*factor,unit_cost=unit_cost/factor,unit_type=p_unit WHERE item_id=p_id;
 UPDATE public.reservations SET quantity=quantity*factor,unit_cost=unit_cost/factor WHERE item_id=p_id;
 UPDATE public.writeoffs SET quantity=quantity*factor,unit_cost=unit_cost/factor WHERE item_id=p_id;
END $function$;
CREATE OR REPLACE FUNCTION public.crm_update_inventory_item_v2(p_id uuid,p_category text,p_name text,p_color text,p_avg_cost numeric,p_unit_type text,p_units_per_unit integer,p_conversion_base numeric DEFAULT 1)
RETURNS void LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $function$
BEGIN
 PERFORM public.crm_convert_inventory_unit(p_id,p_unit_type,p_conversion_base);
 IF p_category NOT IN ('fresh','dried') OR trim(coalesce(p_name,''))='' OR p_avg_cost<0 OR p_units_per_unit<=0 THEN RAISE EXCEPTION 'Проверьте название, категорию и себестоимость'; END IF;
 UPDATE public.inventory_items SET category=p_category,name=trim(p_name),color=coalesce(nullif(trim(p_color),''),'Без цвета'),avg_cost=p_avg_cost,unit_type=p_unit_type,units_per_unit=CASE WHEN p_unit_type IN ('piece','percent') THEN 1 ELSE p_units_per_unit END WHERE id=p_id;
 INSERT INTO public.history(event_type,description,meta) VALUES('Склад','Позиция склада отредактирована',jsonb_build_object('item_id',p_id,'unit_type',p_unit_type));
END $function$;


DO $permissions$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'crm_%' LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',f.sig);
 EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f.sig);
 END LOOP; END $permissions$;
NOTIFY pgrst, 'reload schema';