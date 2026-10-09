import { createClient } from 'npm:@supabase/supabase-js@2.95.0';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json; charset=utf-8'};
const json=(d:unknown,s=200)=>new Response(JSON.stringify(d),{status:s,headers});
async function hash(s:string){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)))).map(b=>b.toString(16).padStart(2,'0')).join('')}
async function snapshot(){const{data,error}=await db.from('comm_companies').select('id,document,revision,updated_at').order('updated_at',{ascending:false});if(error)throw error;return data}
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers});
 if(req.method!=='POST')return json({error:'Method not allowed'},405);
 try{
  const raw=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'').trim();
  if(!/^[a-f0-9]{64}$/.test(raw))return json({error:'Войдите с паролем CRM'},401);
  const{data:session,error:sessionError}=await db.from('crm_sessions').select('id').eq('token_hash',await hash(raw)).gt('expires_at',new Date().toISOString()).maybeSingle();
  if(sessionError)throw sessionError;
  if(!session)return json({error:'Сессия истекла. Войдите заново.'},401);
  const text=await req.text();if(text.length>2000000)return json({error:'Слишком большой запрос'},413);
  const b=JSON.parse(text);
  if(b.action==='load')return json({data:await snapshot()});
  if(b.action==='clients'){const{data,error}=await db.from('clients').select('id,company_name').is('archived_at',null);if(error)throw error;return json({data})}
  if(b.action==='save'){
   if(!Array.isArray(b.items)||!b.items.length||b.items.length>100)throw new Error('Некорректный пакет');
   for(const i of b.items){const d=i.document;
    if(!d||typeof d.name!=='string'||!d.name.trim()||!['first','talk','test','active','lost'].includes(d.status)||!Number.isInteger(i.revision)||i.revision<0)throw new Error('Некорректная карточка');
    if(d.status==='lost'&&!d.reason?.trim())throw new Error('Укажите причину');
    for(const k of ['contacts','events','tasks'])if(!Array.isArray(d[k]))throw new Error('Некорректная структура '+k);
    for(const c of d.contacts)for(const k of ['name','role','phone','email','telegram'])if(c[k]!=null&&typeof c[k]!=='string')throw new Error('Некорректный контакт');
    for(const k of ['events','tasks'])for(const c of d[k])if(typeof c.id!=='string'||typeof c.text!=='string'||typeof c.date!=='string'||c.date&&!/^\d{4}-\d{2}-\d{2}$/.test(c.date))throw new Error('Некорректное событие или действие');
    if(d.client_id){const{data,error}=await db.from('clients').select('id').eq('id',d.client_id).maybeSingle();if(error)throw error;if(!data)throw new Error('Клиент учёта не найден')}
   }
   const{error}=await db.rpc('comm_save_batch',{p_items:b.items});if(error)throw error;
   return json({data:await snapshot()});
  }
  if(b.action==='delete'){
   const{data,error}=await db.from('comm_companies').delete().eq('id',b.id).eq('revision',b.revision).select('id');if(error)throw error;
   if(!data?.length)return json({error:'Карточка уже изменена или удалена. Обновите данные.'},409);
   return json({data:await snapshot()});
  }
  return json({error:'Unknown action'},400);
 }catch(e){const msg=e instanceof Error?e.message:(e as {message?:string})?.message||String(e);return json({error:msg},msg.includes('CONFLICT')?409:400)}
});
