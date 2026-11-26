-- Retainer's cloud copy: everything a signed-in person has saved, for cloud
-- mode to keep the same on each of their Macs.
--
-- Run once in the Supabase project's SQL editor. It can be run again safely.
--
-- One table holds every note, project, canvas and group as the JSON the app
-- keeps for it; one bucket holds the notes' pictures, each in a folder named
-- for its owner. Row-level security closes both to everyone but that owner:
-- the key shipped in the app and on the website opens nothing by itself.

create sequence if not exists public.records_seq;

create table if not exists public.records (
    user_id    uuid        not null default auth.uid() references auth.users (id) on delete cascade,
    kind       text        not null check (kind in ('note', 'project', 'canvas', 'group')),
    id         uuid        not null,
    -- The thing itself. Empty once deleted.
    data       jsonb       not null default '{}'::jsonb,
    -- A deleted record stays, marked, so that every Mac hears of it.
    deleted    boolean     not null default false,
    -- Which version of a note's picture goes with it: <user>/<id>-<blob>.png in the bucket.
    blob       text,
    updated_at timestamptz not null default now(),
    -- Every change takes the next number. A Mac asks for "everything after N".
    seq        bigint      not null default 0,
    primary key (user_id, kind, id)
);

create index if not exists records_by_change on public.records (user_id, seq);

-- The server, not the Mac, says when a change was made and which number it is.
create or replace function public.records_stamp() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    new.seq := nextval('public.records_seq');
    new.updated_at := now();
    return new;
end
$$;

drop trigger if exists records_stamp on public.records;
create trigger records_stamp before insert or update on public.records
    for each row execute function public.records_stamp();

alter table public.records enable row level security;

drop policy if exists "A person's records are theirs alone" on public.records;
create policy "A person's records are theirs alone" on public.records
    for all to authenticated
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

revoke all on public.records from anon;
grant select, insert, update on public.records to authenticated;

-- The pictures. Private; PNG only; 25 MB at most each.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('images', 'images', false, 26214400, array['image/png'])
on conflict (id) do update
    set public = excluded.public,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "A person's pictures are theirs alone" on storage.objects;
create policy "A person's pictures are theirs alone" on storage.objects
    for all to authenticated
    using (bucket_id = 'images' and (storage.foldername(name))[1] = (select auth.uid())::text)
    with check (bucket_id = 'images' and (storage.foldername(name))[1] = (select auth.uid())::text);
