-- 상식 1000제 응시 통계용 설정
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

-- 같은 점수면 더 빨리 푼 사람이 앞 순위: 나보다 점수가 높은 수(higher), 같은 점수인데 더 빠른 수(faster)
create or replace function public.score_rank(p_score integer, p_seconds integer)
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
    'faster', count(*) filter (where score = p_score and seconds < p_seconds)
  ) from attempts;
$$;

-- 3) 응시 결과 제출 후 갱신된 통계와 내 순위를 돌려줌
create or replace function public.submit_attempt(p_score integer, p_seconds integer)
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
begin
  if p_score is null or p_score < 0 or p_score > 20 then
    raise exception '점수가 올바르지 않습니다';
  end if;
  -- 20문항을 20초 안에 끝낸 기록은 비정상으로 보고 받지 않음
  if p_seconds is null or p_seconds < 20 or p_seconds > 86400 then
    raise exception '소요 시간이 올바르지 않습니다';
  end if;
  -- 같은 주소에서 10분에 10회 넘게 제출하면 거절 (주소를 알 수 없으면 건너뜀)
  if v_hash is not null and (select count(*) from attempts
      where client_hash = v_hash and created_at > now() - interval '10 minutes') >= 10 then
    raise exception '잠시 후 다시 시도해 주세요';
  end if;

  insert into attempts (score, seconds, client_hash) values (p_score, p_seconds, v_hash);
  return (score_stats()::jsonb || jsonb_build_object('rank', score_rank(p_score, p_seconds)::jsonb))::json;
end;
$$;

-- 4) 웹페이지(공개 키)에서는 이 함수들만 실행 가능
revoke all on function public.score_stats() from public;
revoke all on function public.submit_attempt(integer, integer) from public;
revoke all on function public.score_rank(integer, integer) from public;
grant execute on function public.score_stats() to anon, authenticated;
grant execute on function public.submit_attempt(integer, integer) to anon, authenticated;
grant execute on function public.score_rank(integer, integer) to anon, authenticated;

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

-- 보기 하나를 고를 때마다 호출: 집계에 더하고, 갱신된 [n0, n1, n2, n3]를 돌려줌
create or replace function public.record_answer(p_key text, p_choice integer)
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
begin
  if p_key is null or p_key !~ '^[0-9a-f]{8}$' then
    raise exception '문항 키가 올바르지 않습니다';
  end if;
  if p_choice is null or p_choice < 0 or p_choice > 3 then
    raise exception '보기 번호가 올바르지 않습니다';
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

revoke all on function public.record_answer(text, integer) from public;
revoke all on function public.question_stats_all() from public;
grant execute on function public.record_answer(text, integer) to anon, authenticated;
grant execute on function public.question_stats_all() to anon, authenticated;
