-- New isolated module; existing CRM tables and functions are unchanged.
begin;
create table public.comm_companies (
 id uuid primary key,
 document jsonb not null,
 revision integer not null default 1,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 identity_key text generated always as (lower(regexp_replace(btrim(document->>'name'),'\s+',' ','g')) || '|' || lower(regexp_replace(btrim(coalesce(document->>'location','')),'\s+',' ','g'))) stored,
 constraint comm_required check (document ?& array['id','name','status','contacts','events','tasks'] and jsonb_typeof(document->'name')='string' and jsonb_typeof(document->'status')='string'),
 constraint comm_name check (length(btrim(document->>'name')) between 1 and 200),
 constraint comm_status check (document->>'status' in ('first','talk','test','active','lost')),
 constraint comm_reason check (document->>'status' <> 'lost' or length(btrim(coalesce(document->>'reason',''))) > 0),
 constraint comm_arrays check (jsonb_typeof(document->'contacts')='array' and jsonb_typeof(document->'events')='array' and jsonb_typeof(document->'tasks')='array'),
 constraint comm_document_id check (document->>'id'=id::text),
 constraint comm_size check (octet_length(document::text) < 1000000),
 unique(identity_key)
);
alter table public.comm_companies enable row level security;
revoke all on public.comm_companies from public,anon,authenticated;
grant select,insert,update,delete on public.comm_companies to service_role;
-- Atomic batch: failed validation, collision or stale revision rolls back everything.
create function public.comm_save_batch(p_items jsonb) returns void language plpgsql security invoker set search_path=public as $$
declare item jsonb; doc jsonb; affected integer;
begin
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>100 then raise exception 'Invalid batch'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  doc := item->'document';
  if (item->>'revision')::integer=0 then
   insert into comm_companies(id,document) values((doc->>'id')::uuid,doc);
  else
   update comm_companies set document=doc,revision=revision+1,updated_at=now()
    where id=(doc->>'id')::uuid and revision=(item->>'revision')::integer;
   get diagnostics affected=row_count;
   if affected<>1 then raise exception 'CONFLICT: карточка изменена или удалена. Обновите данные.'; end if;
  end if;
 end loop;
end $$;
revoke all on function public.comm_save_batch(jsonb) from public,anon,authenticated;
grant execute on function public.comm_save_batch(jsonb) to service_role;
commit;
