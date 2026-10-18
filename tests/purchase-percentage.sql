BEGIN;
DO $test$
DECLARE p uuid; p2 uuid; i uuid; v numeric; cat text;
BEGIN
 FOREACH cat IN ARRAY ARRAY['fresh','dried'] LOOP
  p:=public.crm_create_purchase(current_date,'',null::uuid,null::uuid,jsonb_build_array(jsonb_build_object('category',cat,'name','__FOLLOWUP__','color','test','quantity',2,'unit_cost',1000,'unit_type','bunch','units_per_unit',50)),'Test','');
  SELECT item_id INTO i FROM public.purchase_items WHERE purchase_id=p;
  PERFORM public.crm_edit_purchase(p,jsonb_build_array(jsonb_build_object('item_id',i,'quantity',200,'unit_cost',10,'unit_type','percent','units_per_unit',1,'conversion_base',1)));
  SELECT quantity INTO v FROM public.inventory_items WHERE id=i;
  IF v<>200 THEN RAISE EXCEPTION 'Two old bunches must be 200 percent, got %',v; END IF;
  -- Same position, new purchase in whole packages: no manual card change or error.
  p2:=public.crm_create_purchase(current_date,'',null::uuid,null::uuid,jsonb_build_array(jsonb_build_object('category',cat,'name','__FOLLOWUP__','color','test','quantity',1,'unit_cost',1000,'unit_type','package','units_per_unit',50,'conversion_base',1)),'Test','');
  SELECT quantity*avg_cost INTO v FROM public.inventory_items WHERE id=i;
  IF abs(v-3000)>0.000001 THEN RAISE EXCEPTION 'Unit switch changed inventory value %',v; END IF;
  p2:=public.crm_create_purchase(current_date,'',null::uuid,null::uuid,jsonb_build_array(jsonb_build_object('category',cat,'name','__FOLLOWUP__','color','test','quantity',200,'unit_cost',10,'unit_type','percent','units_per_unit',1,'conversion_base',1)),'Test','');
  SELECT quantity INTO v FROM public.inventory_items WHERE id=i;
  IF v<>500 THEN RAISE EXCEPTION 'Five bunches must be 500 percent, got %',v; END IF;
  SELECT sum(quantity*unit_cost) INTO v FROM public.purchase_items WHERE item_id=i;
  IF abs(v-5000)>0.000001 THEN RAISE EXCEPTION 'Historic purchase totals changed %',v; END IF;
 END LOOP;
 -- Old stock counted as 50 pieces per whole bundle.
 p:=public.crm_create_purchase(current_date,'',null::uuid,null::uuid,jsonb_build_array(jsonb_build_object('category','dried','name','__FOLLOWUP_PIECE__','color','test','quantity',100,'unit_cost',20,'unit_type','piece','units_per_unit',1)),'Test','');
 SELECT item_id INTO i FROM public.purchase_items WHERE purchase_id=p;
 PERFORM public.crm_edit_purchase(p,jsonb_build_array(jsonb_build_object('item_id',i,'quantity',200,'unit_cost',10,'unit_type','percent','units_per_unit',1,'conversion_base',50)));
 SELECT quantity*avg_cost INTO v FROM public.inventory_items WHERE id=i;
 IF abs(v-2000)>0.000001 THEN RAISE EXCEPTION 'Piece to percent total changed %',v; END IF;
END $test$;
ROLLBACK;
