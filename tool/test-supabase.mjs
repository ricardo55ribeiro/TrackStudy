// Isolated PostgreSQL/WASM checks. Never connects to a user's Supabase project.
// npm install --prefix .tools/sql-test --no-audit --no-fund @electric-sql/pglite@0.5.8
// node tool/test-supabase.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
const { PGlite } = await import('../.tools/sql-test/node_modules/@electric-sql/pglite/dist/index.js');
const db = new PGlite();
const a = randomUUID(), b = randomUUID();
let checks = 0;
const check = (value, message) => { assert.ok(value, message); checks++; };
const rejects = async (callback, message) => { await assert.rejects(callback, message); checks++; };
try {
  await db.exec(`
    create role authenticated noinherit;
    create role anon noinherit;
    create schema auth;
    create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    grant usage on schema auth, public to authenticated, anon;
    grant execute on function auth.uid() to authenticated, anon;
  `);
  await db.query('insert into auth.users values ($1),($2)',[a,b]);
  for (const file of ['001_initial.sql','002_sync.sql','003_causal_sync.sql','004_schedule_and_events.sql','005_journal_answers_schedule_description.sql']) {
    const legacyJournal=randomUUID(), legacyBlock=randomUUID();
    if(file.startsWith('005')) {
      await db.query("insert into public.journal(id,user_id,learned,question,next,experiment) values ($1,$2,'Existing','Why?','Next','{}')",[legacyJournal,a]);
      await db.query("insert into public.schedule_blocks(id,user_id,title,weekday,start_minute,end_minute) values ($1,$2,'Existing class',1,510,600)",[legacyBlock,a]);
    }
    await db.exec(await readFile(new URL(`../supabase/migrations/${file}`,import.meta.url),'utf8'));
    if(file.startsWith('005')) {
      const j=(await db.query('select * from public.journal where id=$1',[legacyJournal])).rows[0];
      const b=(await db.query('select * from public.schedule_blocks where id=$1',[legacyBlock])).rows[0];
      check(j.id===legacyJournal && j.learned==='Existing' && j.question==='Why?','005 preserves journal UUID and content');
      check(j.answer===null && j.answered_at===null,'005 defaults existing answers to null');
      check(b.id===legacyBlock && b.start_minute===510 && b.description===null,'005 preserves existing blocks with null description');
      await db.query('delete from public.journal where id=$1',[legacyJournal]);
      await db.query('delete from public.schedule_blocks where id=$1',[legacyBlock]);
    }
  }
  await db.exec('set role authenticated');
  async function asUser(id) { await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]); }
  await asUser(a);
  async function merge(table,row) {
    return (await db.query('select public.trackstudy_merge($1,$2::jsonb) result',[table,JSON.stringify(row)])).rows[0].result;
  }
  const stamp = {created_at:'2026-09-21T10:00:00Z',updated_at:'2026-09-21T10:00:00Z',sync_version:1,sync_writer:'device-a'};
  const category = {...stamp,id:randomUUID(),user_id:b,name:'Research',measurement:'continuous',unit:'h',floor:600,target:800,
    increment:100,step:25,position:0,active:true,archived_at:null};
  const savedCategory = await merge('categories',category);
  check(savedCategory.user_id === a,'Server must supply authenticated ownership, never trust JSON user_id');
  const retry = await merge('categories',category);
  check(retry.revision === savedCategory.revision,'Idempotent retry must not increment revision');
  const goal = {...stamp,id:randomUUID(),category_id:category.id,week_start:'2026-09-21',name:'Research',measurement:'continuous',unit:'h',floor:600,
    target:800,increment:100,step:25,position:0};
  await merge('weekly_goals',goal);
  const concurrentGoal = await merge('weekly_goals',{...goal,id:randomUUID(),sync_version:2,sync_writer:'device-b'});
  check(concurrentGoal.id === goal.id,'Concurrent snapshot creation must reconcile to one canonical UUID');
  const entry = {...stamp,id:randomUUID(),goal_id:goal.id,amount:150,source:'manual',undone_at:null};
  await merge('entries',entry);
  await merge('entries',entry);
  check((await db.query('select count(*)::int n from public.entries')).rows[0].n === 1,'Ledger retries must not duplicate entries');
  await merge('entries',{...entry,sync_version:3,undone_at:'2026-09-21T11:00:00Z'});
  const staleEntry = await merge('entries',{...entry,sync_version:2});
  check(staleEntry.undone_at !== null,'Stale upload must not resurrect an undone entry');
  check((await db.query("select count(*)::int n from public.sync_conflicts where table_name='entries'")).rows[0].n === 0,'Single-device +1.5, undo and stale retries must never produce entry conflicts');
  await rejects(() => merge('entries',{...entry,sync_version:4,amount:250}),'Ledger amount must be immutable');
  await rejects(() => merge('weekly_goals',{...goal,sync_version:4,measurement:'discrete',unit:''}),'Used goal units must not be reinterpreted');
  const journal = {...stamp,id:randomUUID(),learned:'A',question:'B',next:'C',experiment:{Hypothesis:'Test'},deleted_at:null};
  await merge('journal',journal);
  await merge('journal',{...journal,sync_version:10,sync_writer:'z',next:'Winner'});
  check((await merge('journal',{...journal,sync_version:10,sync_writer:'a',next:'Loser'})).next === 'Winner','Equal-version conflicts use deterministic writer ordering');
  check((await db.query("select count(*)::int n from public.sync_conflicts where payload->>'next'='Loser'")).rows[0].n === 1,'Losing journal text must be retained');
  const review = {...stamp,id:randomUUID(),week_start:'2026-09-21',content:{wentWrong:'Late',change:'Earlier',upcoming:'Meeting',wins:['A','B','C'],done:[false,false,false],danger:'Late',countermeasure:'Close laptop'},deleted_at:null};
  await merge('reviews',review);
  check((await merge('reviews',{...review,id:randomUUID(),sync_version:2})).id === review.id,'Concurrent weekly reviews must reconcile');
  const archived = await merge('categories',{...category,sync_version:20,active:false,archived_at:'2026-09-22T00:00:00Z'});
  check(archived.active === false && archived.archived_at !== null,'Archive tombstone must survive merge');
  // Every table: server-normalized own update -> pull -> next writer's observed
  // update. Neither case is concurrent, even though revision/updated_at change.
  for (const table of ['categories','weekly_goals','entries','journal','reviews']) {
    const current = (await db.query(`select to_jsonb(t) r from public.${table} t limit 1`)).rows[0].r;
    const beforeCount = (await db.query('select count(*)::int n from public.sync_conflicts')).rows[0].n;
    const updated = {...current,sync_version:100,sync_writer:current.sync_writer};
    if (table==='categories' || table==='weekly_goals') updated.target=1200;
    if (table==='entries') updated.undone_at=null;
    if (table==='journal') updated.next='Sequential own edit';
    if (table==='reviews') updated.content={...updated.content,change:'Sequential own edit'};
    const saved = await merge(table,updated);
    check(saved.sync_version===100 && saved.revision>current.revision,`${table}: authoritative version/revision returned`);
    const repeated = await merge(table,updated);
    check(repeated.revision===saved.revision,`${table}: retry does not rewrite`);
    const fromNextDevice = {...saved,sync_version:101,sync_writer:'next-device'};
    if (table==='categories' || table==='weekly_goals') fromNextDevice.target=1400;
    if (table==='entries') fromNextDevice.undone_at='2026-09-23T00:00:00Z';
    if (table==='journal') fromNextDevice.next='Observed other device edit';
    if (table==='reviews') fromNextDevice.content={...fromNextDevice.content,change:'Observed other device edit'};
    const successor = await merge(table,fromNextDevice);
    await merge(table,updated); // delayed earlier request cannot restore old data
    const pulled = (await db.query(`select to_jsonb(t) r from public.${table} t where id=$1`,[saved.id])).rows[0].r;
    check(pulled.sync_version===successor.sync_version,`${table}: stale response cannot overwrite descendant`);
    check((await db.query('select count(*)::int n from public.sync_conflicts')).rows[0].n===beforeCount,`${table}: own/observed edits are not conflicts`);
  }
  // A real race between devices with the same acknowledged base must still be
  // preserved, and retrying that losing request must not create more copies.
  const base = (await db.query('select to_jsonb(t) r from public.journal t where id=$1',[journal.id])).rows[0].r;
  await merge('journal',{...base,sync_version:200,sync_writer:'writer-a',next:'Concurrent A'});
  const raceWinner = await merge('journal',{...base,sync_version:200,sync_writer:'writer-z',next:'Concurrent Z'});
  check(raceWinner.next==='Concurrent Z','Real divergent concurrent edit still resolves deterministically');
  const raceCopies = (await db.query("select count(*)::int n from public.sync_conflicts where payload->>'next'='Concurrent A'")).rows[0].n;
  check(raceCopies===1,'Real conflict retains the losing payload');
  await merge('journal',{...base,sync_version:200,sync_writer:'writer-a',next:'Concurrent A'});
  check((await db.query("select count(*)::int n from public.sync_conflicts where payload->>'next'='Concurrent A'")).rows[0].n===1,'Resolved history makes losing retries idempotent');
  const equalBase = raceWinner;
  await merge('journal',{...equalBase,sync_version:300,sync_writer:'equal-a',next:'Identical concurrent content'});
  const beforeEqual=(await db.query('select count(*)::int n from public.sync_conflicts')).rows[0].n;
  await merge('journal',{...equalBase,sync_version:300,sync_writer:'equal-z',next:'Identical concurrent content'});
  check((await db.query('select count(*)::int n from public.sync_conflicts')).rows[0].n===beforeEqual,'Identical user content is not a conflict');

  // Simulate an obsolete v002 same-installation copy; archival retains evidence.
  const currentEntry=(await db.query('select to_jsonb(t) r from public.entries t where id=$1',[entry.id])).rows[0].r;
  const copy={...currentEntry,sync_version:100,undone_at:null};
  await db.query("insert into public.sync_conflicts(user_id,table_name,record_id,version,writer,payload) values($1,'entries',$2,100,$3,$4)",[a,entry.id,currentEntry.sync_writer,JSON.stringify(copy)]);
  async function archiveCopy(row,version,writer) {
    return (await db.query('select public.trackstudy_archive_entry_copy($1,$2,$3) ok',[JSON.stringify(row),version,writer])).rows[0].ok;
  }
  check(await archiveCopy({...currentEntry,undone_at:null},100,currentEntry.sync_writer)===false,'Archive refuses local/remote disagreement');
  check(await archiveCopy(currentEntry,100,'wrong-device')===false,'Archive refuses another writer');
  check(await archiveCopy(currentEntry,100,currentEntry.sync_writer)===true,'Verified same-installation obsolete copy can be archived explicitly');
  check((await db.query("select archived_at,payload from public.sync_conflicts where table_name='entries' and writer=$1 and version=100",[currentEntry.sync_writer])).rows[0].archived_at!==null,'Archival keeps original payload and records an archive timestamp');
  check((await db.query('select to_jsonb(t) r from public.entries t where id=$1',[entry.id])).rows[0].r.sync_version===currentEntry.sync_version,'Archival never mutates the ledger');
  await rejects(() => db.exec("update public.sync_conflicts set payload='{}'::jsonb"),'Archive permission cannot rewrite conflict evidence');
  await rejects(() => merge('journal',{...journal,id:randomUUID(),sync_history:{bad:'not-a-counter'}}),'Malformed causal counters must be rejected');
  const planning = {
    schedule_blocks: {...stamp,id:randomUUID(),title:'Gym',weekday:1,start_minute:510,end_minute:600,deleted_at:null},
    academic_events: {...stamp,id:randomUUID(),title:'NLP Test',event_date:'2026-10-07',event_type:'test',note:'Prepare',deleted_at:null}
  };
  for (const [table,row] of Object.entries(planning)) {
    const saved = await merge(table,{...row,user_id:b});
    check(saved.user_id===a,`${table}: ownership supplied by authenticated user`);
    check((await merge(table,row)).revision===saved.revision,`${table}: own echo idempotent`);
    const next = await merge(table,{...saved,sync_version:5,sync_writer:'phone',title:'Phone edit'});
    check(next.title==='Phone edit',`${table}: observed edit from second device`);
    check((await db.query('select count(*)::int n from public.sync_conflicts where table_name=$1',[table])).rows[0].n===0,`${table}: no false conflicts`);
    await db.exec("set timezone='Pacific/Honolulu'");
    const pulled = (await db.query(`select to_jsonb(t) r from public.${table} t where id=$1`,[row.id])).rows[0].r;
    check(table==='academic_events'?pulled.event_date==='2026-10-07':pulled.start_minute===510,`${table}: calendar/wall time never shifts with timezone`);
    await db.exec("set timezone='UTC'");
    await merge(table,{...next,sync_version:6,sync_writer:'race-a',title:'Race A'});
    const winner=await merge(table,{...next,sync_version:6,sync_writer:'race-z',title:'Race Z'});
    check(winner.title==='Race Z',`${table}: real concurrent edit resolves deterministically`);
    check((await db.query('select count(*)::int n from public.sync_conflicts where table_name=$1',[table])).rows[0].n===1,`${table}: concurrent losing text retained`);
    await merge(table,{...next,sync_version:6,sync_writer:'race-a',title:'Race A'});
    check((await db.query('select count(*)::int n from public.sync_conflicts where table_name=$1',[table])).rows[0].n===1,`${table}: losing retry adds no duplicate conflicts`);
    const tombstone=await merge(table,{...winner,sync_version:7,deleted_at:'2026-09-27T00:00:00Z'});
    await merge(table,next);
    check((await db.query(`select deleted_at from public.${table} where id=$1`,[row.id])).rows[0].deleted_at!==null,`${table}: deletion cannot be resurrected by stale upload`);
    check((await merge(table,tombstone)).revision===tombstone.revision,`${table}: tombstone retry idempotent`);
    await rejects(()=>db.exec(`delete from public.${table}`),`${table}: physical deletion denied`);
    await rejects(()=>merge(table,{...row,id:randomUUID(),title:' '}),`${table}: empty title rejected`);
  }
  await rejects(()=>merge('schedule_blocks',{...planning.schedule_blocks,id:randomUUID(),end_minute:510}),'Invalid time interval rejected');
  await rejects(()=>merge('schedule_blocks',{...planning.schedule_blocks,id:randomUUID(),weekday:8}),'Invalid weekday rejected');
  await rejects(()=>merge('academic_events',{...planning.academic_events,id:randomUUID(),event_date:'2026-02-30'}),'Invalid date rejected');
  await rejects(()=>merge('academic_events',{...planning.academic_events,id:randomUUID(),event_type:'unknown'}),'Invalid event type rejected');
  const unanswered=await merge('journal',{...journal,id:randomUUID()});
  const answered=await merge('journal',{...unanswered,sync_version:2,sync_writer:'phone',answer:'Objective explanation',answered_at:'2026-09-29T10:00:00Z'});
  check(answered.answer==='Objective explanation' && answered.question===unanswered.question,'Answer is stored without replacing question');
  check((await merge('journal',answered)).revision===answered.revision,'Answer echo does not create a new revision');
  const legacyAnswer={...answered,sync_version:3,sync_writer:'older-client',learned:'Legacy edit'};delete legacyAnswer.answer;delete legacyAnswer.answered_at;
  const preserved=await merge('journal',legacyAnswer);
  check(preserved.answer===answered.answer && preserved.answered_at===answered.answered_at,'Older client omissions cannot erase an answer');
  const cleared=await merge('journal',{...preserved,sync_version:4,answer:null,answered_at:null});
  check(cleared.answer===null && cleared.answered_at===null && cleared.question===unanswered.question,'Explicit answer clear retains question');
  await rejects(()=>merge('journal',{...cleared,sync_version:5,question:' ',answer:'Meaningless'}),'Answer with empty question is rejected');
  const answerA=await merge('journal',{...cleared,sync_version:10,sync_writer:'answer-a',answer:'Answer A',answered_at:'2026-09-29T11:00:00Z'});
  const answerZ=await merge('journal',{...cleared,sync_version:10,sync_writer:'answer-z',answer:'Answer Z',answered_at:'2026-09-29T11:00:00Z'});
  check(answerZ.answer==='Answer Z','Concurrent answers converge using existing causal ordering');
  check((await db.query("select count(*)::int n from public.sync_conflicts where record_id=$1 and payload->>'answer'='Answer A'",[answerA.id])).rows[0].n===1,'Concurrent losing answer is retained as evidence');
  await merge('journal',answerZ);
  check((await db.query("select count(*)::int n from public.sync_conflicts where record_id=$1",[answerA.id])).rows[0].n===1,'Answer echo does not duplicate conflict evidence');
  const described=await merge('schedule_blocks',{...planning.schedule_blocks,id:randomUUID(),description:'V0.04'});
  check(described.description==='V0.04','Description stored on existing block model');
  const editedDescription=await merge('schedule_blocks',{...described,sync_version:2,description:'V0.05'});
  check(editedDescription.description==='V0.05','Description edit is synchronized');
  const legacyDescription={...editedDescription,sync_version:3,title:'Older client title'};delete legacyDescription.description;
  const preservedDescription=await merge('schedule_blocks',legacyDescription);
  check(preservedDescription.description==='V0.05','Older client omissions cannot erase description');
  const clearedDescription=await merge('schedule_blocks',{...preservedDescription,sync_version:4,description:null});
  check(clearedDescription.description===null,'Description clears explicitly');
  check((await merge('schedule_blocks',clearedDescription)).revision===clearedDescription.revision,'Description clearing is idempotent');
  await rejects(()=>merge('schedule_blocks',{...described,id:randomUUID(),description:'x'.repeat(2001)}),'Overlong description rejected');
  // Public-readiness audit: exercise every private table, not just categories.
  const privateTables=['categories','weekly_goals','entries','journal','reviews','sync_conflicts','schedule_blocks','academic_events'];
  const privateRows={};
  for(const table of privateTables) {
    privateRows[table]=(await db.query(`select to_jsonb(t) r from public.${table} t limit 1`)).rows[0].r;
    check((await db.query('select relrowsecurity from pg_class where oid=$1::regclass',[`public.${table}`])).rows[0].relrowsecurity,`${table}: RLS enabled`);
    await rejects(()=>db.query(`update public.${table} set user_id=$1 where user_id=$2`,[b,a]),`${table}: current owner cannot transfer ownership`);
  }
  const functions=(await db.query("select proname,prosecdef,proconfig from pg_proc join pg_namespace n on n.oid=pronamespace where n.nspname='public' and proname like 'trackstudy_%'")).rows;
  check(functions.every(f=>!f.prosecdef),'All TrackStudy functions execute with invoker permissions');
  check(functions.every(f=>f.proconfig?.includes('search_path=""')),'All TrackStudy functions use an empty search path');
  await asUser(b);
  check(await archiveCopy(currentEntry,100,currentEntry.sync_writer)===false,'Another account cannot archive this entry copy');
  for (const table of ['categories','weekly_goals','entries','journal','reviews','sync_conflicts','schedule_blocks','academic_events']) {
    check((await db.query(`select count(*)::int n from public.${table}`)).rows[0].n === 0,`RLS hides another account's ${table}`);
  }
  for(const [table,row] of Object.entries(planning)) {
    await rejects(()=>merge(table,{...row,sync_version:1000}),`${table}: another user cannot take ownership`);
    check((await db.query(`update public.${table} set title='Intrusion' where id=$1 returning id`,[row.id])).rows.length===0,`${table}: cross-user update hidden`);
  }
  check((await db.query('update public.categories set name=$1 where id=$2 returning id',['Intrusion',category.id])).rows.length === 0,'Cross-user updates are hidden by RLS');
  await rejects(() => merge('entries',{...entry,id:randomUUID()}),'Composite FK/entry validation must reject cross-user goal references');
  await rejects(() => merge('weekly_goals',{...goal,id:randomUUID(),week_start:'2026-10-12'}),'Composite FK rejects cross-user category references');
  for (const table of privateTables) {
    const forged={...privateRows[table],id:randomUUID(),record_id:randomUUID(),user_id:a};
    await rejects(()=>db.query(`insert into public.${table} select * from jsonb_populate_record(null::public.${table},$1::jsonb)`,[JSON.stringify(forged)]),`${table}: direct insert cannot impersonate another owner`);
    if(table!=='sync_conflicts') {
      check((await db.query(`update public.${table} set updated_at=now() where user_id=$1 returning id`,[a])).rows.length===0,`${table}: direct cross-user updates see no rows`);
      await rejects(()=>merge(table,{...privateRows[table],sync_version:99999,sync_writer:'intruder'}),`${table}: merge cannot claim another owner's UUID`);
    } else {
      check((await db.query('update public.sync_conflicts set archived_at=now() where user_id=$1 returning record_id',[a])).rows.length===0,'Conflict archival cannot touch another account');
    }
  }
  await rejects(() => merge('categories',{...category,sync_version:100}),'Cannot take ownership of another user UUID');
  await asUser(a);
  check((await db.query('select name from public.categories where id=$1',[category.id])).rows[0].name === 'Research','Cross-user attempts leave data unchanged');
  await rejects(() => db.exec('delete from public.entries'),'Physical deletion must not be granted');
  await rejects(() => merge('preferences',{}),'RPC table whitelist must reject arbitrary tables');
  await db.exec('reset role; set role anon');
  await rejects(() => db.exec('select * from public.categories'),'Anonymous table reads must be denied');
  await rejects(() => merge('categories',category),'Anonymous merge must be denied');
  await rejects(() => archiveCopy(currentEntry,100,currentEntry.sync_writer),'Anonymous archive must be denied');
  for(const table of Object.keys(planning)) await rejects(()=>db.exec(`select * from public.${table}`),`${table}: anonymous reads denied`);
  for(const table of privateTables) {
    await rejects(()=>db.exec(`select * from public.${table}`),`${table}: anonymous read denied`);
    await rejects(()=>db.query(`insert into public.${table} select * from jsonb_populate_record(null::public.${table},$1::jsonb)`,[JSON.stringify(privateRows[table])]),`${table}: anonymous insert denied`);
    await rejects(()=>db.query(`update public.${table} set user_id=$1`,[b]),`${table}: anonymous update denied`);
    await rejects(()=>db.exec(`delete from public.${table}`),`${table}: anonymous delete denied`);
  }
  console.log(`PASS: all five migrations executed; ${checks} PostgreSQL merge, idempotency, ownership, RLS, tombstone and conflict checks passed.`);
} finally { await db.close(); }
