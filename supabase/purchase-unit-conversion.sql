CREATE OR REPLACE FUNCTION public.crm_convert_inventory_unit(p_id uuid, p_unit text, p_base numeric DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE old_unit text; factor numeric;
BEGIN
 SELECT unit_type INTO old_unit FROM public.inventory_items WHERE id=p_id FOR UPDATE;
 IF old_unit IS NULL THEN RAISE EXCEPTION 'Позиция не найдена'; END IF;
 IF p_unit NOT IN ('piece','bunch','package','percent') OR p_base IS NULL OR p_base<=0 THEN RAISE EXCEPTION 'Некорректная единица или база пересчёта'; END IF;
 IF old_unit=p_unit THEN RETURN; END IF;
 factor:=CASE WHEN p_unit='percent' THEN 100/p_base WHEN old_unit='percent' THEN p_base/100 ELSE 1/p_base END;
 UPDATE public.inventory_items SET quantity=quantity*factor,avg_cost=avg_cost/factor,unit_type=p_unit WHERE id=p_id;
 UPDATE public.purchase_items SET quantity=quantity*factor,unit_cost=unit_cost/factor,unit_type=p_unit WHERE item_id=p_id;
 UPDATE public.reservations SET quantity=quantity*factor,unit_cost=unit_cost/factor WHERE item_id=p_id;
 UPDATE public.writeoffs SET quantity=quantity*factor,unit_cost=unit_cost/factor WHERE item_id=p_id;
END $function$
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

   if iid is not null and (select unit_type from public.inventory_items where id=iid)<>v_unit then
     perform public.crm_convert_inventory_unit(iid,v_unit,coalesce(nullif(x->>'conversion_base','')::numeric,case when (select unit_type from public.inventory_items where id=iid)='piece' and v_unit in ('bunch','package') then v_size else 1 end));
     select quantity,avg_cost into oq,oc from public.inventory_items where id=iid;
   end if;
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

NOTIFY pgrst, 'reload schema';