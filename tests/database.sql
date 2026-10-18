BEGIN;
DO $test$
DECLARE c uuid; p uuid; i uuid; o uuid; o2 uuid; w uuid; v numeric; v2 numeric; caught boolean;
BEGIN
 c:=public.crm_create_client('__CRM_TEST__','','','', 'В работе','durable',null,0,'',7000,false);
 p:=public.crm_create_purchase(current_date,'',null::uuid,null::uuid,jsonb_build_array(jsonb_build_object('category','dried','name','__CRM_TEST__','color','test','quantity',1,'unit_cost',1000,'unit_type','bunch','units_per_unit',50)),'Test','');
 SELECT item_id INTO i FROM public.purchase_items WHERE purchase_id=p;
 -- Exercise original failing purchase edit path.
 PERFORM public.crm_create_purchase(current_date,'',null::uuid,jsonb_build_array(jsonb_build_object('_meta',jsonb_build_object('edit_purchase_id',p)),jsonb_build_object('item_id',i,'color','test','quantity',1,'unit_cost',1000,'unit_type','bunch','units_per_unit',50)),'Test','');
 PERFORM public.crm_update_inventory_item_v2(i,'dried','__CRM_TEST__','test',10,'percent',1,1);
 SELECT quantity*avg_cost INTO v FROM public.inventory_items WHERE id=i;
 IF abs(v-1000)>0.000001 THEN RAISE EXCEPTION 'Conversion value mismatch %',v; END IF;
 SELECT quantity INTO v FROM public.purchase_items WHERE purchase_id=p;
 IF v<>100 THEN RAISE EXCEPTION 'Purchase conversion mismatch %',v; END IF;
 o:=public.crm_create_order_v2(c,null,current_date,2000,'',jsonb_build_array(jsonb_build_object('item_id',i,'quantity',10)),'one_off');
 SELECT sum(quantity*unit_cost) INTO v FROM public.reservations WHERE order_id=o;
 IF v<>100 THEN RAISE EXCEPTION '10 percent must cost 100, got %',v; END IF;
 PERFORM public.crm_ship_order(o);
 SELECT quantity INTO v FROM public.inventory_items WHERE id=i;
 IF v<>90 THEN RAISE EXCEPTION 'After shipment expected 90, got %',v; END IF;
 -- Editing a shipped order recalculates stock and COGS, including fractional quantities.
 PERFORM public.crm_update_order(o,c,null,current_date,2000,'',jsonb_build_array(jsonb_build_object('item_id',i,'quantity',12.5)),'one_off');
 SELECT quantity INTO v FROM public.inventory_items WHERE id=i;
 IF v<>87.5 THEN RAISE EXCEPTION 'Shipped edit expected 87.5 got %',v; END IF;
 w:=public.crm_create_writeoff_fractional(i,2.5,'Test');
 PERFORM public.crm_update_writeoff_fractional(w,i,3.5,'Test',current_date);
 PERFORM public.crm_delete_writeoff(w);
 SELECT quantity INTO v FROM public.inventory_items WHERE id=i;
 IF v<>87.5 THEN RAISE EXCEPTION 'Writeoff undo mismatch %',v; END IF;
 o2:=public.crm_create_order_v2(c,null,current_date,2000,'',jsonb_build_array(jsonb_build_object('item_id',i,'quantity',5.5)),'one_off');
 caught:=false;
 BEGIN PERFORM public.crm_create_order_v2(c,null,current_date,2000,'',jsonb_build_array(jsonb_build_object('item_id',i,'quantity',100)),'one_off'); EXCEPTION WHEN others THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Oversell allowed'; END IF;
 PERFORM public.crm_update_inventory_item_v2(i,'dried','__CRM_TEST__','test',1000,'bunch',50,1);
 SELECT sum(quantity*unit_cost) INTO v FROM public.reservations WHERE order_id=o;
 IF abs(v-125)>0.000001 THEN RAISE EXCEPTION 'Historic COGS changed %',v; END IF;
 PERFORM public.crm_update_inventory_item_v2(i,'dried','__CRM_TEST__','test',10,'percent',1,1);
 SELECT quantity INTO v FROM public.inventory_items WHERE id=i;
 IF abs(v-87.5)>0.000001 THEN RAISE EXCEPTION 'Reverse conversion mismatch %',v; END IF;
 PERFORM public.crm_delete_order(o2);
 -- Native new percent purchase and editable fractional amount.
 p:=public.crm_create_purchase(current_date,'',null::uuid,null::uuid,jsonb_build_array(jsonb_build_object('category','dried','name','__CRM_TEST_PCT__','color','test','quantity',100,'unit_cost',10,'unit_type','percent','units_per_unit',1)),'Test','');
 SELECT item_id INTO i FROM public.purchase_items WHERE purchase_id=p;
 PERFORM public.crm_edit_purchase(p,jsonb_build_array(jsonb_build_object('item_id',i,'color','test','quantity',100,'unit_cost',12,'unit_type','percent','units_per_unit',1)));
 SELECT quantity*avg_cost INTO v FROM public.inventory_items WHERE id=i;
 IF v<>1200 THEN RAISE EXCEPTION 'Percent purchase edit mismatch %',v; END IF;
 PERFORM public.crm_delete_purchase(p);
 SELECT quantity INTO v FROM public.inventory_items WHERE id=i;
 IF v<>0 THEN RAISE EXCEPTION 'Purchase deletion mismatch %',v; END IF;
 RAISE NOTICE 'PASS: purchase edit, percentage conversion, order create/update/ship, fractional writeoffs, oversell rejection, historic COGS, purchase deletion';
END $test$;
ROLLBACK;
