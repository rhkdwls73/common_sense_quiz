-- 알쓸신잡 응시 통계용 설정
-- Supabase 대시보드 → SQL Editor → New query 에 전체를 붙여 넣고 Run 하면 됩니다.
-- 여러 번 실행해도 안전합니다.

-- 1) 응시 기록 테이블 (점수, 걸린 시간만 저장. 이름·이메일 등 개인정보는 저장하지 않음)
create table if not exists public.attempts (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  score       smallint    not null check (score between 0 and 20),
  seconds     integer     not null check (seconds between 0 and 86400),
  client_hash text        -- 같은 접속 주소의 연속 제출을 막기 위한 해시값 (원래 주소는 저장하지 않음)
);
create index if not exists attempts_client_recent on public.attempts (client_hash, created_at desc);
-- 그만두거나 중간에 나간 판이면 true (같은 점수면 끝까지 푼 판보다 뒤 순위)
alter table public.attempts add column if not exists abandoned boolean not null default false;

-- 테이블은 외부에서 직접 읽거나 쓸 수 없게 잠그고, 아래 두 함수로만 접근하게 합니다.
alter table public.attempts enable row level security;
revoke all on table public.attempts from anon, authenticated;

-- 2) 전체 통계: 총 응시 수, 평균, 오늘(한국 시간) 응시 수, 점수(0~20)별 인원 분포
create or replace function public.score_stats()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'total', (select count(*) from attempts),
    'avg',   (select round(avg(score)::numeric, 2) from attempts),
    'today', (select count(*) from attempts
              where created_at >= (date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul')),
    'dist',  (select json_agg(n order by k)
              from (select g.k, count(a.id)::int as n
                    from generate_series(0, 20) as g(k)
                    left join attempts a on a.score = g.k
                    group by g.k) d)
  );
$$;

-- 순위 기준: 점수가 높을수록 → 끝까지 푼 판이 그만둔 판보다 → 빨리 푼 판일수록 앞
--   higher = 나보다 점수가 높은 수, same = 같은 점수 수, faster = 같은 점수인데 나보다 앞인 수
drop function if exists public.score_rank(integer, integer);
create or replace function public.score_rank(p_score integer, p_seconds integer, p_abandoned boolean default false)
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'total',  count(*),
    'higher', count(*) filter (where score > p_score),
    'same',   count(*) filter (where score = p_score),
    'faster', count(*) filter (where score = p_score
                and (abandoned < p_abandoned or (abandoned = p_abandoned and seconds < p_seconds)))
  ) from attempts;
$$;

-- =====================================================================
-- 3) 판(라운드) 단위 기록
--    판을 시작할 때 서버가 판 번호를 주고, 답할 때마다 그 판에 저장합니다.
--    점수는 브라우저가 보낸 숫자가 아니라 서버에 쌓인 답으로 계산합니다.
--    중간에 나가도 그 판은 사라지지 않습니다:
--      · '그만두기'를 누르면 바로, 창을 닫으면 마지막 답 뒤 30분이 지나면
--        그때까지 맞힌 개수(남은 문항은 오답)로 기록합니다.
--      · 한 문제도 풀지 않은 판은 기록하지 않습니다.
-- =====================================================================

-- 예전 방식(브라우저가 점수를 보내는 함수)은 없앱니다.
drop function if exists public.submit_attempt(integer, integer);

create table if not exists public.rounds (
  id          uuid primary key default gen_random_uuid(),
  client_hash text,
  keys        text[]      not null,                       -- 20문항의 문항 키 (출제 순서)
  answers     smallint[]  not null default array_fill(null::smallint, array[20]),  -- 고른 보기 (0 = 정답)
  answered    smallint    not null default 0,
  started_at  timestamptz not null default now(),
  last_at     timestamptz not null default now(),         -- 마지막으로 답한 시각
  ended_at    timestamptz,                                -- 끝까지 풀었거나 그만둔 시각
  settled_at  timestamptz,                                -- 점수를 기록한 시각
  attempt_id  bigint                                      -- attempts에 기록된 행
);
create index if not exists rounds_client_recent on public.rounds (client_hash, started_at desc);
create index if not exists rounds_open on public.rounds (last_at) where ended_at is null;
alter table public.rounds enable row level security;
revoke all on table public.rounds from anon, authenticated;

-- (내부용) 판 하나를 지금까지의 답으로 기록하거나, 이미 기록돼 있으면 고쳐 씀
create or replace function public.settle_round(p_id uuid, p_abandoned boolean)
returns public.attempts
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  rd     public.rounds%rowtype;
  a      public.attempts%rowtype;
  v_sc   integer;
  v_secs integer;
begin
  select * into rd from rounds where id = p_id for update;
  if not found then return null; end if;
  select count(*) filter (where x = 0) into v_sc from unnest(rd.answers) as x;
  v_secs := least(86400, greatest(0, round(extract(epoch from
              (case when p_abandoned then rd.last_at else now() end) - rd.started_at))::integer));
  if rd.attempt_id is not null then
    update attempts set score = v_sc, seconds = v_secs, abandoned = p_abandoned
     where id = rd.attempt_id returning * into a;
  end if;
  if a.id is null then
    insert into attempts (created_at, score, seconds, client_hash, abandoned)
    values (rd.started_at, v_sc, v_secs, rd.client_hash, p_abandoned) returning * into a;
  end if;
  update rounds set attempt_id = a.id, settled_at = now() where id = p_id;
  return a;
end;
$$;

-- (내부용) 마지막 답 뒤 30분 넘게 손대지 않은 판을 기록하고, 오래된 판 정보는 지움
create or replace function public.settle_stale_rounds()
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r record;
begin
  delete from rounds
   where ended_at is null and answered = 0 and last_at < now() - interval '30 minutes';
  for r in select id from rounds
            where ended_at is null and answered > 0 and last_at < now() - interval '30 minutes'
              and (settled_at is null or settled_at < last_at)
            order by last_at limit 200 loop
    perform settle_round(r.id, true);
  end loop;
  if random() < 0.05 then
    delete from rounds where started_at < now() - interval '3 days';
  end if;
end;
$$;

-- 판 시작: 20문항의 문항 키를 받아 판 번호를 돌려줌
create or replace function public.start_round(p_keys text[])
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_ip      text := trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1));
  v_hash    text := case when v_ip = '' then null else md5(v_ip || ':sangsik1000') end;
  v_id      uuid;
begin
  if p_keys is null or coalesce(array_length(p_keys, 1), 0) <> 20
     or (select count(distinct k) from unnest(p_keys) k where k ~ '^[0-9a-f]{8}$') <> 20 then
    raise exception '문항 정보가 올바르지 않습니다';
  end if;
  -- 같은 주소에서 10분에 15판 넘게 시작하면 거절 (주소를 알 수 없으면 건너뜀)
  if v_hash is not null and (select count(*) from rounds
      where client_hash = v_hash and started_at > now() - interval '10 minutes') >= 15 then
    raise exception '잠시 후 다시 시도해 주세요';
  end if;
  perform settle_stale_rounds();
  insert into rounds (client_hash, keys) values (v_hash, p_keys) returning id into v_id;
  return json_build_object('id', v_id);
end;
$$;

-- 판 끝내기: p_quit = false면 20문항을 다 푼 뒤 호출, true면 '그만두기'
-- 이미 끝난 판이면 기록된 결과를 그대로 돌려줌
create or replace function public.end_round(p_round uuid, p_quit boolean default false)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  rd public.rounds%rowtype;
  a  public.attempts%rowtype;
begin
  select * into rd from rounds where id = p_round for update;
  if not found then raise exception '판 정보를 찾을 수 없습니다'; end if;

  if rd.ended_at is null then
    if not p_quit and rd.answered < 20 then
      raise exception '아직 다 풀지 않았습니다';
    end if;
    if rd.answered = 0 then                       -- 한 문제도 안 풀고 그만두면 기록하지 않음
      delete from rounds where id = p_round;
      return json_build_object('discarded', true);
    end if;
    a := settle_round(p_round, p_quit);
    update rounds set ended_at = now() where id = p_round;
  else
    select * into a from attempts where id = rd.attempt_id;
    if a.id is null then raise exception '판 정보를 찾을 수 없습니다'; end if;
  end if;

  perform settle_stale_rounds();
  return (score_stats()::jsonb || jsonb_build_object(
    'score', a.score, 'seconds', a.seconds, 'abandoned', a.abandoned,
    'rank', score_rank(a.score, a.seconds, a.abandoned)::jsonb))::json;
end;
$$;

-- 4) 웹페이지(공개 키)에서는 아래 함수들만 실행 가능. 내부용 함수는 막아 둠
revoke all on function public.score_stats() from public;
revoke all on function public.score_rank(integer, integer, boolean) from public;
revoke all on function public.start_round(text[]) from public;
revoke all on function public.end_round(uuid, boolean) from public;
revoke all on function public.settle_round(uuid, boolean) from public, anon, authenticated;
revoke all on function public.settle_stale_rounds() from public, anon, authenticated;
grant execute on function public.score_stats() to anon, authenticated;
grant execute on function public.score_rank(integer, integer, boolean) to anon, authenticated;
grant execute on function public.start_round(text[]) to anon, authenticated;
grant execute on function public.end_round(uuid, boolean) to anon, authenticated;

-- =====================================================================
-- 5) 문항별 정답률 (보기마다 몇 명이 골랐는지)
--    문항은 문제·보기 내용으로 만든 8자리 키(qkey)로 구분합니다.
--    n0 = 정답을 고른 수, n1~n3 = 오답1~3을 고른 수 (문제 은행 순서 기준)
-- =====================================================================
create table if not exists public.question_stats (
  qkey       text primary key check (qkey ~ '^[0-9a-f]{8}$'),
  n0         integer not null default 0,
  n1         integer not null default 0,
  n2         integer not null default 0,
  n3         integer not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.question_stats enable row level security;
revoke all on table public.question_stats from anon, authenticated;

-- 같은 접속 주소에서 짧은 시간에 지나치게 많이 보내는 것을 막기 위한 기록 (주소 해시만 저장)
create table if not exists public.answer_hits (
  client_hash text        not null,
  created_at  timestamptz not null default now()
);
create index if not exists answer_hits_recent on public.answer_hits (client_hash, created_at desc);
alter table public.answer_hits enable row level security;
revoke all on table public.answer_hits from anon, authenticated;

-- 보기 하나를 고를 때마다 호출: 판에 답을 저장하고 집계에 더한 뒤, 갱신된 [n0, n1, n2, n3]를 돌려줌
-- p_round·p_pos(0~19)를 주면 그 판의 해당 문항에 답을 저장합니다. 이미 답한 문항이면 바꾸지 않고 집계도 다시 더하지 않습니다.
drop function if exists public.record_answer(text, integer);
create or replace function public.record_answer(p_key text, p_choice integer, p_round uuid default null, p_pos integer default null)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_ip      text := trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1));
  v_hash    text := case when v_ip = '' then null else md5(v_ip || ':sangsik1000') end;
  r         public.question_stats%rowtype;
  rd        public.rounds%rowtype;
begin
  if p_key is null or p_key !~ '^[0-9a-f]{8}$' then
    raise exception '문항 키가 올바르지 않습니다';
  end if;
  if p_choice is null or p_choice < 0 or p_choice > 3 then
    raise exception '보기 번호가 올바르지 않습니다';
  end if;

  if p_round is not null then
    select * into rd from rounds where id = p_round for update;
    if not found then raise exception '판 정보를 찾을 수 없습니다'; end if;
    if rd.ended_at is not null then raise exception '이미 끝난 판입니다'; end if;
    if p_pos is null or p_pos < 0 or p_pos > 19 or rd.keys[p_pos + 1] <> p_key then
      raise exception '문항 정보가 올바르지 않습니다';
    end if;
    if rd.answers[p_pos + 1] is not null then
      -- 이미 답한 문항: 처음 고른 답을 유지하고 현재 집계만 돌려줌
      select * into r from question_stats where qkey = p_key;
      return json_build_object('saved', false, 'choice', rd.answers[p_pos + 1],
        'n', json_build_array(coalesce(r.n0, 0), coalesce(r.n1, 0), coalesce(r.n2, 0), coalesce(r.n3, 0)));
    end if;
    update rounds set answers[p_pos + 1] = p_choice, answered = answered + 1, last_at = now()
     where id = p_round;
  end if;

  if v_hash is not null then
    -- 같은 주소에서 1분에 40번 넘게 보내면 집계하지 않고 현재 값만 돌려줌
    if (select count(*) from answer_hits
        where client_hash = v_hash and created_at > now() - interval '1 minute') >= 40 then
      select * into r from question_stats where qkey = p_key;
      return json_build_object('saved', false,
        'n', json_build_array(coalesce(r.n0, 0), coalesce(r.n1, 0), coalesce(r.n2, 0), coalesce(r.n3, 0)));
    end if;
    insert into answer_hits (client_hash) values (v_hash);
    if random() < 0.02 then
      delete from answer_hits where created_at < now() - interval '1 hour';
    end if;
  end if;

  insert into question_stats as s (qkey, n0, n1, n2, n3)
  values (p_key, (p_choice = 0)::int, (p_choice = 1)::int, (p_choice = 2)::int, (p_choice = 3)::int)
  on conflict (qkey) do update
    set n0 = s.n0 + excluded.n0,
        n1 = s.n1 + excluded.n1,
        n2 = s.n2 + excluded.n2,
        n3 = s.n3 + excluded.n3,
        updated_at = now()
  returning * into r;

  return json_build_object('saved', true, 'n', json_build_array(r.n0, r.n1, r.n2, r.n3));
end;
$$;

-- 전체 문항 집계: { "qkey": [n0, n1, n2, n3], ... }
create or replace function public.question_stats_all()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(json_object_agg(qkey, json_build_array(n0, n1, n2, n3)), '{}'::json)
  from question_stats;
$$;

revoke all on function public.record_answer(text, integer, uuid, integer) from public;
revoke all on function public.question_stats_all() from public;
grant execute on function public.record_answer(text, integer, uuid, integer) to anon, authenticated;
grant execute on function public.question_stats_all() to anon, authenticated;

-- =====================================================================
-- 6) 랭킹전
--    닉네임을 걸고 10·20·30·40문항 중 하나를 골라, 문항당 5초(20문항 100초) 안에 몇 개 맞히는지 겨룹니다.
--    · 문항 수마다 하루(한국 시간) 한 번. 같은 기기 1회, 같은 접속 주소는 하루 3회까지.
--    · 문제는 도전마다 무작위로 뽑습니다 (남의 문제를 보고 미리 답을 알 수 없도록).
--    · 제한 시간은 서버 시각으로 잽니다. 시간이 지나거나 그만두면 그때까지 맞힌 개수로 기록됩니다.
--    · 순위: 맞힌 개수 → 걸린 시간 순. 역대 1~3위는 명예의 전당으로 남습니다.
-- =====================================================================
create table if not exists public.ranked_sets (
  day  date     not null,
  size smallint not null,
  keys text[]   not null,
  primary key (day, size)
);
alter table public.ranked_sets enable row level security;
revoke all on table public.ranked_sets from anon, authenticated;

create table if not exists public.ranked_runs (
  id          uuid primary key default gen_random_uuid(),
  day         date        not null,
  size        smallint    not null check (size in (10, 20, 30, 40)),
  nickname    text        not null,
  device      text        not null,
  client_hash text,
  answers     smallint[]  not null,
  answered    smallint    not null default 0,
  started_at  timestamptz not null default now(),
  deadline    timestamptz not null,
  ended_at    timestamptz,
  score       smallint,
  seconds     numeric(6,1),
  unique (day, size, device)
);
-- 도전마다 뽑힌 문항 키 (예전 방식의 '그날 공통 세트'는 ranked_sets에 남아 있음)
alter table public.ranked_runs add column if not exists keys text[];
create index if not exists ranked_runs_board on public.ranked_runs (size, day, score desc, seconds);
create index if not exists ranked_runs_open on public.ranked_runs (deadline) where ended_at is null;
alter table public.ranked_runs enable row level security;
revoke all on table public.ranked_runs from anon, authenticated;

-- (내부용) 오늘 날짜(한국 시간), 제한 시간(초)
create or replace function public.ranked_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Seoul')::date $$;
create or replace function public.ranked_limit(p_size integer) returns numeric
language sql immutable as $$ select p_size * 7.0 $$;

-- (내부용) 제한 시간이 지난 도전을 그때까지 맞힌 개수로 마감
create or replace function public.ranked_settle()
returns void
language sql
volatile
security definer
set search_path = public
as $$
  update ranked_runs r
     set ended_at = r.deadline,
         score    = (select count(*) filter (where x = 0) from unnest(r.answers) as x),
         seconds  = ranked_limit(r.size)
   where r.ended_at is null and r.deadline < now() - interval '3 seconds';
$$;

-- (내부용) 한 도전의 현재 상태
create or replace function public.ranked_state(p_id uuid)
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'id', r.id, 'day', r.day, 'size', r.size, 'nickname', r.nickname,
    'keys', coalesce(r.keys, s.keys), 'answers', r.answers, 'ended', r.ended_at is not null,
    'score', r.score, 'seconds', r.seconds, 'limit', ranked_limit(r.size),
    'remaining_ms', greatest(0, floor(extract(epoch from (r.deadline - now())) * 1000))::bigint)
  from ranked_runs r left join ranked_sets s on s.day = r.day and s.size = r.size
  where r.id = p_id;
$$;

-- 도전 시작 (이미 시작한 도전이 진행 중이면 그 도전을 이어서 돌려줌)
create or replace function public.ranked_start(p_size integer, p_nickname text, p_device text, p_keys text[])
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_ip      text := trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1));
  v_hash    text := case when v_ip = '' then null else md5(v_ip || ':sangsik1000') end;
  v_day     date := ranked_today();
  v_nick    text := btrim(coalesce(p_nickname, ''));
  r         public.ranked_runs%rowtype;
  v_id      uuid;
begin
  if p_size is null or p_size not in (10, 20, 30, 40) then
    raise exception '문항 수가 올바르지 않습니다';
  end if;
  if char_length(v_nick) < 1 or char_length(v_nick) > 12 or v_nick ~ '[[:cntrl:]]' then
    raise exception '닉네임은 1~12자로 입력해 주세요';
  end if;
  if p_device is null or p_device !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception '기기 정보가 올바르지 않습니다';
  end if;
  if p_keys is null or coalesce(array_length(p_keys, 1), 0) <> p_size
     or (select count(distinct k) from unnest(p_keys) k where k ~ '^[0-9a-f]{8}$') <> p_size then
    raise exception '문항 정보가 올바르지 않습니다';
  end if;

  perform ranked_settle();

  select * into r from ranked_runs where day = v_day and size = p_size and device = p_device;
  if found then
    if r.ended_at is not null then
      raise exception '오늘 %문항 랭킹전은 이미 도전했습니다', p_size;
    end if;
    return ranked_state(r.id);                      -- 진행 중인 도전 이어 풀기
  end if;

  if v_hash is not null and (select count(*) from ranked_runs
      where day = v_day and size = p_size and client_hash = v_hash) >= 3 then
    raise exception '같은 네트워크에서 오늘 %문항 랭킹전 도전 횟수를 넘었습니다', p_size;
  end if;

  insert into ranked_runs (day, size, nickname, device, client_hash, keys, answers, deadline)
  values (v_day, p_size, v_nick, p_device, v_hash, p_keys, array_fill(null::smallint, array[p_size]),
          now() + make_interval(secs => ranked_limit(p_size)))
  returning id into v_id;
  return ranked_state(v_id);
end;
$$;

-- 답 하나 저장 (이미 답한 문항이면 처음 답 유지). 문항별 정답률 집계에도 더함
create or replace function public.ranked_answer(p_round uuid, p_pos integer, p_choice integer)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r     public.ranked_runs%rowtype;
  v_key text;
  q     public.question_stats%rowtype;
begin
  if p_choice is null or p_choice < 0 or p_choice > 3 then
    raise exception '보기 번호가 올바르지 않습니다';
  end if;
  select * into r from ranked_runs where id = p_round for update;
  if not found then raise exception '도전 정보를 찾을 수 없습니다'; end if;
  if r.ended_at is not null then raise exception '이미 끝난 도전입니다'; end if;
  if now() > r.deadline + interval '2 seconds' then raise exception '제한 시간이 끝났습니다'; end if;
  if p_pos is null or p_pos < 0 or p_pos >= r.size then raise exception '문항 정보가 올바르지 않습니다'; end if;
  v_key := r.keys[p_pos + 1];
  if v_key is null then
    select keys[p_pos + 1] into v_key from ranked_sets where day = r.day and size = r.size;
  end if;

  if r.answers[p_pos + 1] is not null then
    select * into q from question_stats where qkey = v_key;
    return json_build_object('saved', false, 'choice', r.answers[p_pos + 1],
      'n', json_build_array(coalesce(q.n0, 0), coalesce(q.n1, 0), coalesce(q.n2, 0), coalesce(q.n3, 0)));
  end if;
  update ranked_runs set answers[p_pos + 1] = p_choice, answered = answered + 1 where id = p_round;

  insert into question_stats as s (qkey, n0, n1, n2, n3)
  values (v_key, (p_choice = 0)::int, (p_choice = 1)::int, (p_choice = 2)::int, (p_choice = 3)::int)
  on conflict (qkey) do update
    set n0 = s.n0 + excluded.n0, n1 = s.n1 + excluded.n1,
        n2 = s.n2 + excluded.n2, n3 = s.n3 + excluded.n3, updated_at = now()
  returning * into q;
  return json_build_object('saved', true, 'n', json_build_array(q.n0, q.n1, q.n2, q.n3));
end;
$$;

-- 순위표: 오늘(또는 p_day) 순위 상위 p_limit명 + 역대 1~3위(명예의 전당)
create or replace function public.ranked_board(p_size integer, p_day date default null, p_limit integer default 50)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_day date := coalesce(p_day, ranked_today());
begin
  if p_size is null or p_size not in (10, 20, 30, 40) then
    raise exception '문항 수가 올바르지 않습니다';
  end if;
  perform ranked_settle();
  return json_build_object(
    'day', v_day, 'size', p_size, 'limit', ranked_limit(p_size),
    'total', (select count(*) from ranked_runs where size = p_size and day = v_day and ended_at is not null and answered > 0),
    'board', (select coalesce(json_agg(b order by b.rank, b.ended_at), '[]'::json) from (
                select rank() over (order by score desc, seconds) as rank, nickname, score, seconds, ended_at
                from ranked_runs
                where size = p_size and day = v_day and ended_at is not null and answered > 0
                order by score desc, seconds, ended_at
                limit least(greatest(coalesce(p_limit, 50), 1), 200)) b),
    'hall',  (select coalesce(json_agg(h order by h.rank, h.ended_at), '[]'::json) from (
                select rank() over (order by score desc, seconds) as rank, nickname, score, seconds, day, ended_at
                from ranked_runs
                where size = p_size and ended_at is not null and answered > 0
                order by score desc, seconds, ended_at
                limit 3) h));
end;
$$;

-- 도전 끝내기 (끝까지 풀었거나 그만둘 때). 결과와 오늘 순위를 돌려줌
create or replace function public.ranked_end(p_round uuid)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.ranked_runs%rowtype;
begin
  perform ranked_settle();
  select * into r from ranked_runs where id = p_round for update;
  if not found then raise exception '도전 정보를 찾을 수 없습니다'; end if;
  if r.ended_at is null then
    update ranked_runs
       set ended_at = least(now(), deadline),
           score    = (select count(*) filter (where x = 0) from unnest(r.answers) as x),
           -- 다 풀지 않고 그만두면 제한 시간을 다 쓴 것으로 침 (빨리 그만둬서 순위를 올리는 것 방지)
           seconds  = case when r.answered < r.size then ranked_limit(r.size)
                      else least(ranked_limit(r.size),
                        round(extract(epoch from (least(now(), r.deadline) - r.started_at))::numeric, 1)) end
     where id = p_round
     returning * into r;
  end if;
  return json_build_object(
    'size', r.size, 'score', r.score, 'seconds', r.seconds, 'limit', ranked_limit(r.size),
    'answered', r.answered, 'nickname', r.nickname,
    'rank', (select count(*) + 1 from ranked_runs o
              where o.size = r.size and o.day = r.day and o.ended_at is not null and o.answered > 0
                and (o.score > r.score or (o.score = r.score and o.seconds < r.seconds))),
    'board', ranked_board(r.size, r.day, 10));
end;
$$;

-- 이 기기의 오늘 도전 현황 (문항 수별로 했는지, 점수)
create or replace function public.ranked_status(p_device text)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  perform ranked_settle();
  return (select coalesce(json_agg(json_build_object(
            'size', size, 'ended', ended_at is not null, 'score', score, 'seconds', seconds, 'nickname', nickname)
            order by size), '[]'::json)
          from ranked_runs where device = p_device and day = ranked_today());
end;
$$;

revoke all on function public.ranked_today() from public, anon, authenticated;
revoke all on function public.ranked_limit(integer) from public, anon, authenticated;
revoke all on function public.ranked_settle() from public, anon, authenticated;
revoke all on function public.ranked_state(uuid) from public, anon, authenticated;
revoke all on function public.ranked_start(integer, text, text, text[]) from public;
revoke all on function public.ranked_answer(uuid, integer, integer) from public;
revoke all on function public.ranked_board(integer, date, integer) from public;
revoke all on function public.ranked_end(uuid) from public;
revoke all on function public.ranked_status(text) from public;
grant execute on function public.ranked_start(integer, text, text, text[]) to anon, authenticated;
grant execute on function public.ranked_answer(uuid, integer, integer) to anon, authenticated;
grant execute on function public.ranked_board(integer, date, integer) to anon, authenticated;
grant execute on function public.ranked_end(uuid) to anon, authenticated;
grant execute on function public.ranked_status(text) to anon, authenticated;

-- =====================================================================
-- 7) 정답은 서버에만 (2026-11 개편)
--    · 공개 문제 은행(questions.js)에는 정답·해설이 없고, 문항마다 무작위 번호(qid)만 있습니다.
--    · 정답 위치와 해설은 quiz_items에만 있고, 답을 고른 뒤에야 서버가 알려 줍니다.
--    · 랭킹전 문제는 서버가 뽑습니다. 제한 시간은 문항당 7초입니다.
--    · 예전 함수(정답 = 0번 보기로 채점, 문제를 브라우저가 고름)는 웹페이지에서 못 쓰게 막습니다.
--    · 집계(question_stats)와 판·랭킹 기록은 예전처럼 '문제 은행 원래 순서'(0 = 정답)로 저장합니다.
-- =====================================================================
create table if not exists public.quiz_items (
  qid    text primary key check (qid ~ '^[0-9a-f]{12}$'),
  qkey   text not null unique check (qkey ~ '^[0-9a-f]{8}$'),   -- question_stats의 문항 키
  cat    smallint not null,
  perm   smallint[] not null check (array_length(perm, 1) = 4), -- perm[공개 보기 번호 + 1] = 원래 보기 번호 (0 = 정답)
  exp    text not null default '',
  active boolean not null default true
);
alter table public.quiz_items enable row level security;
revoke all on table public.quiz_items from anon, authenticated;

-- 랭킹전 참가를 막을 접속 주소 (주소 자체가 아니라 해시만 저장)
create table if not exists public.ranked_bans (
  client_hash text primary key,
  note        text,
  created_at  timestamptz not null default now()
);
alter table public.ranked_bans enable row level security;
revoke all on table public.ranked_bans from anon, authenticated;

create or replace function public.ranked_limit(p_size integer) returns numeric
language sql immutable as $$ select p_size * 7.0 $$;

-- (내부용) 원래 보기 번호 → 공개 보기 번호
create or replace function public.qi_pub(p_perm smallint[], p_orig integer) returns integer
language sql immutable as $$ select array_position(p_perm, p_orig::smallint) - 1 $$;

-- (내부용) 답을 고른 뒤 돌려줄 내용: 정답(공개 보기 번호), 해설, 보기별 선택 수(공개 보기 순서)
create or replace function public.qi_reply(p_qkey text, p_saved boolean, p_choice integer default null)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  i public.quiz_items%rowtype;
  s public.question_stats%rowtype;
  a integer[] := array[0, 0, 0, 0];
begin
  select * into i from quiz_items where qkey = p_qkey;
  select * into s from question_stats where qkey = p_qkey;
  if found then a := array[s.n0, s.n1, s.n2, s.n3]; end if;
  return json_build_object('saved', p_saved, 'correct', qi_pub(i.perm, 0), 'exp', i.exp,
    'choice', case when p_choice is null then null else qi_pub(i.perm, p_choice) end,
    'n', json_build_array(a[i.perm[1] + 1], a[i.perm[2] + 1], a[i.perm[3] + 1], a[i.perm[4] + 1]));
end;
$$;

-- 일반 모드 판 시작: 공개 번호(qid) 20개
create or replace function public.quiz_start(p_qids text[])
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_ip      text := trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1));
  v_hash    text := case when v_ip = '' then null else md5(v_ip || ':sangsik1000') end;
  v_keys    text[];
  v_id      uuid;
begin
  if p_qids is null or coalesce(array_length(p_qids, 1), 0) <> 20 then
    raise exception '문항 정보가 올바르지 않습니다';
  end if;
  select array_agg(i.qkey order by t.ord) into v_keys
    from unnest(p_qids) with ordinality as t(qid, ord)
    join quiz_items i on i.qid = t.qid and i.active;
  if coalesce(array_length(v_keys, 1), 0) <> 20 or (select count(distinct k) from unnest(v_keys) k) <> 20 then
    raise exception '문제 은행이 바뀌었습니다. 페이지를 새로고침해 주세요';
  end if;
  if v_hash is not null and (select count(*) from rounds
      where client_hash = v_hash and started_at > now() - interval '10 minutes') >= 15 then
    raise exception '잠시 후 다시 시도해 주세요';
  end if;
  perform settle_stale_rounds();
  insert into rounds (client_hash, keys) values (v_hash, v_keys) returning id into v_id;
  return json_build_object('id', v_id);
end;
$$;

-- 일반 모드 답 하나: p_choice는 공개 보기 번호(0~3). 판에 저장·집계한 뒤 정답과 해설을 돌려줌
-- p_practice = true(틀린 문항 다시 풀기)면 저장·집계 없이 정답만 알려 줌
create or replace function public.quiz_answer(p_qid text, p_choice integer, p_round uuid default null,
                                              p_pos integer default null, p_practice boolean default false)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_ip      text := trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1));
  v_hash    text := case when v_ip = '' then null else md5(v_ip || ':sangsik1000') end;
  i         public.quiz_items%rowtype;
  rd        public.rounds%rowtype;
  v_orig    integer;
  v_hits    integer := 0;
begin
  if p_choice is null or p_choice < 0 or p_choice > 3 then
    raise exception '보기 번호가 올바르지 않습니다';
  end if;
  select * into i from quiz_items where qid = p_qid and active;
  if not found then raise exception '문제 은행이 바뀌었습니다. 페이지를 새로고침해 주세요'; end if;
  v_orig := i.perm[p_choice + 1];

  -- 같은 주소에서 1분에 60번 넘게 답을 보내면 거절 (정답을 긁어 가는 것 방지), 40번 넘으면 집계만 건너뜀
  if v_hash is not null then
    select count(*) into v_hits from answer_hits
     where client_hash = v_hash and created_at > now() - interval '1 minute';
    if v_hits >= 60 then raise exception '너무 빠르게 풀고 있습니다. 잠시 후 다시 시도해 주세요'; end if;
    insert into answer_hits (client_hash) values (v_hash);
    if random() < 0.02 then delete from answer_hits where created_at < now() - interval '1 hour'; end if;
  end if;

  if p_practice then return qi_reply(i.qkey, false); end if;

  if p_round is not null then
    select * into rd from rounds where id = p_round for update;
    if not found then raise exception '판 정보를 찾을 수 없습니다'; end if;
    if rd.ended_at is not null then raise exception '이미 끝난 판입니다'; end if;
    if p_pos is null or p_pos < 0 or p_pos > 19 or rd.keys[p_pos + 1] <> i.qkey then
      raise exception '문항 정보가 올바르지 않습니다';
    end if;
    if rd.answers[p_pos + 1] is not null then          -- 이미 답한 문항: 처음 답 유지
      return qi_reply(i.qkey, false, rd.answers[p_pos + 1]);
    end if;
    update rounds set answers[p_pos + 1] = v_orig, answered = answered + 1, last_at = now() where id = p_round;
  end if;

  if v_hits < 40 then
    insert into question_stats as s (qkey, n0, n1, n2, n3)
    values (i.qkey, (v_orig = 0)::int, (v_orig = 1)::int, (v_orig = 2)::int, (v_orig = 3)::int)
    on conflict (qkey) do update
      set n0 = s.n0 + excluded.n0, n1 = s.n1 + excluded.n1,
          n2 = s.n2 + excluded.n2, n3 = s.n3 + excluded.n3, updated_at = now();
  end if;
  return qi_reply(i.qkey, true);
end;
$$;

-- 문항별 정답률: { "qid": [맞힌 수, 틀린 수], ... } (보기별 수는 공개하지 않음)
create or replace function public.quiz_rates()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(json_object_agg(i.qid, json_build_array(s.n0, s.n1 + s.n2 + s.n3)), '{}'::json)
  from quiz_items i join question_stats s on s.qkey = i.qkey
  where i.active;
$$;

-- (내부용) 랭킹전 도전 하나의 현재 상태 (공개 번호와 공개 보기 번호로)
create or replace function public.ranked_view(p_id uuid)
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'id', r.id, 'day', r.day, 'size', r.size, 'nickname', r.nickname,
    'qids',    (select json_agg(i.qid order by t.ord)
                  from unnest(r.keys, r.answers) with ordinality as t(k, x, ord) left join quiz_items i on i.qkey = t.k),
    'picks',   (select json_agg(case when t.x is null then null else qi_pub(i.perm, t.x) end order by t.ord)
                  from unnest(r.keys, r.answers) with ordinality as t(k, x, ord) left join quiz_items i on i.qkey = t.k),
    'correct', (select json_agg(case when t.x is null then null else qi_pub(i.perm, 0) end order by t.ord)
                  from unnest(r.keys, r.answers) with ordinality as t(k, x, ord) left join quiz_items i on i.qkey = t.k),
    'exps',    (select json_agg(case when t.x is null then null else i.exp end order by t.ord)
                  from unnest(r.keys, r.answers) with ordinality as t(k, x, ord) left join quiz_items i on i.qkey = t.k),
    'ended', r.ended_at is not null, 'score', r.score, 'seconds', r.seconds, 'limit', ranked_limit(r.size),
    'remaining_ms', greatest(0, floor(extract(epoch from (r.deadline - now())) * 1000))::bigint)
  from ranked_runs r
  where r.id = p_id;
$$;

-- 랭킹전 시작: 문제는 서버가 무작위로 뽑음 (한 분야에서 10·20문항은 1개, 30·40문항은 2개까지)
create or replace function public.ranked_begin(p_size integer, p_nickname text, p_device text)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_ip      text := trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1));
  v_hash    text := case when v_ip = '' then null else md5(v_ip || ':sangsik1000') end;
  v_day     date := ranked_today();
  v_nick    text := btrim(coalesce(p_nickname, ''));
  v_keys    text[];
  r         public.ranked_runs%rowtype;
  v_id      uuid;
begin
  if p_size is null or p_size not in (10, 20, 30, 40) then
    raise exception '문항 수가 올바르지 않습니다';
  end if;
  if char_length(v_nick) < 1 or char_length(v_nick) > 12 or v_nick ~ '[[:cntrl:]]' then
    raise exception '닉네임은 1~12자로 입력해 주세요';
  end if;
  if p_device is null or p_device !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception '기기 정보가 올바르지 않습니다';
  end if;
  if v_hash is not null and exists (select 1 from ranked_bans where client_hash = v_hash) then
    raise exception '이 접속 환경에서는 랭킹전에 참여할 수 없습니다';
  end if;

  perform ranked_settle();

  select * into r from ranked_runs where day = v_day and size = p_size and device = p_device;
  if found then
    if r.ended_at is not null then
      raise exception '오늘 %문항 랭킹전은 이미 도전했습니다', p_size;
    end if;
    return ranked_view(r.id);                       -- 진행 중인 도전 이어 풀기
  end if;

  if v_hash is not null and (select count(*) from ranked_runs
      where day = v_day and size = p_size and client_hash = v_hash) >= 3 then
    raise exception '같은 네트워크에서 오늘 %문항 랭킹전 도전 횟수를 넘었습니다', p_size;
  end if;

  select array_agg(qkey order by random()) into v_keys from (
    select qkey from (
      select qkey, row_number() over (partition by cat order by random()) as rn
      from quiz_items where active) p
    where rn <= case when p_size <= 20 then 1 else 2 end
    order by random()
    limit p_size) t;
  if coalesce(array_length(v_keys, 1), 0) <> p_size then
    raise exception '문제를 뽑지 못했습니다. 잠시 후 다시 시도해 주세요';
  end if;

  insert into ranked_runs (day, size, nickname, device, client_hash, keys, answers, deadline)
  values (v_day, p_size, v_nick, p_device, v_hash, v_keys, array_fill(null::smallint, array[p_size]),
          now() + make_interval(secs => ranked_limit(p_size)))
  returning id into v_id;
  return ranked_view(v_id);
end;
$$;

-- 랭킹전 답 하나: p_choice는 공개 보기 번호. 저장·집계한 뒤 정답과 해설을 돌려줌
create or replace function public.ranked_pick(p_round uuid, p_pos integer, p_choice integer)
returns json
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r      public.ranked_runs%rowtype;
  i      public.quiz_items%rowtype;
  v_orig integer;
begin
  if p_choice is null or p_choice < 0 or p_choice > 3 then
    raise exception '보기 번호가 올바르지 않습니다';
  end if;
  select * into r from ranked_runs where id = p_round for update;
  if not found then raise exception '도전 정보를 찾을 수 없습니다'; end if;
  if r.ended_at is not null then raise exception '이미 끝난 도전입니다'; end if;
  if now() > r.deadline + interval '2 seconds' then raise exception '제한 시간이 끝났습니다'; end if;
  if p_pos is null or p_pos < 0 or p_pos >= r.size then raise exception '문항 정보가 올바르지 않습니다'; end if;
  select * into i from quiz_items where qkey = r.keys[p_pos + 1];
  if not found then raise exception '문제 은행이 바뀌었습니다. 페이지를 새로고침해 주세요'; end if;

  if r.answers[p_pos + 1] is not null then
    return qi_reply(i.qkey, false, r.answers[p_pos + 1]);
  end if;
  v_orig := i.perm[p_choice + 1];
  update ranked_runs set answers[p_pos + 1] = v_orig, answered = answered + 1 where id = p_round;
  insert into question_stats as s (qkey, n0, n1, n2, n3)
  values (i.qkey, (v_orig = 0)::int, (v_orig = 1)::int, (v_orig = 2)::int, (v_orig = 3)::int)
  on conflict (qkey) do update
    set n0 = s.n0 + excluded.n0, n1 = s.n1 + excluded.n1,
        n2 = s.n2 + excluded.n2, n3 = s.n3 + excluded.n3, updated_at = now();
  return qi_reply(i.qkey, true);
end;
$$;

-- 내부용 함수는 막고, 새 함수만 웹페이지에 열어 줌
revoke all on function public.qi_pub(smallint[], integer) from public, anon, authenticated;
revoke all on function public.qi_reply(text, boolean, integer) from public, anon, authenticated;
revoke all on function public.ranked_view(uuid) from public, anon, authenticated;
revoke all on function public.ranked_limit(integer) from public, anon, authenticated;
revoke all on function public.quiz_start(text[]) from public;
revoke all on function public.quiz_answer(text, integer, uuid, integer, boolean) from public;
revoke all on function public.quiz_rates() from public;
revoke all on function public.ranked_begin(integer, text, text) from public;
revoke all on function public.ranked_pick(uuid, integer, integer) from public;
grant execute on function public.quiz_start(text[]) to anon, authenticated;
grant execute on function public.quiz_answer(text, integer, uuid, integer, boolean) to anon, authenticated;
grant execute on function public.quiz_rates() to anon, authenticated;
grant execute on function public.ranked_begin(integer, text, text) to anon, authenticated;
grant execute on function public.ranked_pick(uuid, integer, integer) to anon, authenticated;

-- 예전 함수: 정답이 0번 보기로 드러나고, 문제를 브라우저가 고를 수 있어 막음
revoke all on function public.record_answer(text, integer, uuid, integer) from public, anon, authenticated;
revoke all on function public.question_stats_all() from public, anon, authenticated;
revoke all on function public.start_round(text[]) from public, anon, authenticated;
revoke all on function public.ranked_start(integer, text, text, text[]) from public, anon, authenticated;
revoke all on function public.ranked_answer(uuid, integer, integer) from public, anon, authenticated;
