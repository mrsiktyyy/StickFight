-- SticksFight Supabase setup
-- Run the whole script in Supabase -> SQL Editor -> New query.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null unique,
  avatar_url text,
  games integer not null default 0,
  wins integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  title text not null default 'Новая игра',
  host_id uuid not null references auth.users(id) on delete cascade,
  host_name text not null,
  guest_id uuid references auth.users(id) on delete set null,
  guest_name text,
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;

drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select to authenticated using (true);
drop policy if exists "profile owner insert" on public.profiles;
create policy "profile owner insert" on public.profiles for insert to authenticated with check (auth.uid()=id and coalesce((auth.jwt()->>'is_anonymous')::boolean,false)=false);
drop policy if exists "profile owner update" on public.profiles;
create policy "profile owner update" on public.profiles for update to authenticated using (auth.uid()=id and coalesce((auth.jwt()->>'is_anonymous')::boolean,false)=false) with check (auth.uid()=id and coalesce((auth.jwt()->>'is_anonymous')::boolean,false)=false);

drop policy if exists "rooms visible to signed in users" on public.rooms;
create policy "rooms visible to signed in users" on public.rooms for select to authenticated using (true);
drop policy if exists "authenticated users create rooms" on public.rooms;
create policy "authenticated users create rooms" on public.rooms for insert to authenticated with check (auth.uid()=host_id);
drop policy if exists "players update own room" on public.rooms;
create policy "players update own room" on public.rooms for update to authenticated
using (auth.uid()=host_id or auth.uid()=guest_id or (guest_id is null and status='waiting'))
with check (auth.uid()=host_id or auth.uid()=guest_id);

-- Create profile rows automatically for permanent (non-anonymous) accounts.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if coalesce((new.raw_app_meta_data->>'provider'),'') <> 'anonymous'
     and coalesce((new.raw_user_meta_data->>'is_anonymous')::boolean,false)=false then
    insert into public.profiles(id,nickname)
    values(new.id,coalesce(new.raw_user_meta_data->>'nickname',split_part(new.email,'@',1)))
    on conflict (id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_sticksfight on auth.users;
create trigger on_auth_user_created_sticksfight
after insert on auth.users for each row execute procedure public.handle_new_user();

-- Realtime room updates
do $$ begin
  alter publication supabase_realtime add table public.rooms;
exception when duplicate_object then null;
when undefined_object then null;
end $$;

-- Public avatar bucket; upload/update is restricted to the owner's folder.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('avatars','avatars',true,2097152,array['image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

drop policy if exists "avatar images are public" on storage.objects;
create policy "avatar images are public" on storage.objects for select using (bucket_id='avatars');
drop policy if exists "users upload own avatar" on storage.objects;
create policy "users upload own avatar" on storage.objects for insert to authenticated
with check (bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text and coalesce((auth.jwt()->>'is_anonymous')::boolean,false)=false);
drop policy if exists "users update own avatar" on storage.objects;
create policy "users update own avatar" on storage.objects for update to authenticated
using (bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text and coalesce((auth.jwt()->>'is_anonymous')::boolean,false)=false)
with check (bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text and coalesce((auth.jwt()->>'is_anonymous')::boolean,false)=false);


-- Resolve a nickname to its internal synthetic email for nickname-based login.
-- The generated address contains no private mailbox and cannot receive mail.
create or replace function public.get_login_email(p_nickname text)
returns text
language sql
security definer
set search_path = public, auth
stable
as $$
  select u.email
  from public.profiles p
  join auth.users u on u.id=p.id
  where lower(p.nickname)=lower(trim(p_nickname))
    and coalesce((u.raw_app_meta_data->>'provider'),'') <> 'anonymous'
  limit 1;
$$;
grant execute on function public.get_login_email(text) to anon, authenticated;
