/* This SQL sets up a basic process for marking files to be deleted by a cron task and will delete them on a regular schedule.
   It has:
   A cron task and function to delete a set of files with whatever time period makes sense to manage staying ahead of the deletions.
   A trigger on auth.users delete to call a function to mark the deleted files and remove the foreign key to auth.users.
   A function that shows how you can efficiently mark for delete specific user files and not deal with the actual storage delete.

   It requires your instance URL and your service_role_key.  These can be stored in Vault as SUPABASE_URL and SUPABASE_SERVICE_KEY.

 */


/* You can use both http and pg_net extension or comment out one or the other. */
/* pg_net is much faster for single deletes in a bucket.  http allows bulk deletes so fewer api calls if there are alot of files in a bucket. */
/* set flags in clean_files function for which ones to use */

create extension if not exists http
    with schema extensions;

create extension if not exists pg_net
    with schema extensions;

create extension if not exists pg_cron
    with schema extensions;


/* This function is called from cron at a rate and with a limit count that insures you keep up with deleted files */
/* The function could also be modified to only delete files more than 1 day or week old using the updated_at time in the where */
create or replace function public.clean_files ()
    returns void as $$
declare
    /* it is highly recommended to move the service_role key and url to Vault
       or to a separate table not accessible to the API to allow easy setup for different instances.
       In this example you store your keys in Vault.
     */

    service_role_key text;
    instance_url text;
    files_per_cron int := 10;
    http_enabled boolean := true;
    pg_net_enabled boolean := true;
    delete_status text;
    bucket text;
    paths text[];
    file_body text;
    path text;
begin
    select decrypted_secret into instance_url from vault.decrypted_secrets where name = 'SUPABASE_URL';
    select decrypted_secret into service_role_key from vault.decrypted_secrets where name = 'SUPABASE_SERVICE_KEY';

    raise log 'Clean_files';

    for bucket, paths in
        select bucket_id, array_agg(name) from (
               select bucket_id, name from storage.objects
               where owner_id = 'Delete_this'
               order by bucket_id
               limit files_per_cron) as names
        group by bucket_id
        loop
            path = paths[1];
            file_body = '{"prefixes":' || array_to_json(paths) || '}';
            raise log 'key= %, bucket = %, file_body = %, path = %, length = %', service_role_key, bucket, file_body, path, array_length(paths,1);

            /*  http extension only case */
            if (http_enabled AND NOT pg_net_enabled) then
            select status from
                http((
                      'DELETE',
                      instance_url || '/storage/v1/object/' || bucket,
                      ARRAY[http_header('authorization','Bearer ' || service_role_key)],
                      'application/json',
                      file_body
                    )::http_request) into delete_status;  --not sure delete status is useful from storage-API in this case
            end if;

            /*   pg_net extension only case (without delete body) */
            if (pg_net_enabled AND NOT http_enabled) then
            foreach path in array paths
                loop
                    perform net.http_delete(
                           url:=instance_url || '/storage/v1/object/' || bucket || '/' || path,
                           headers:= ('{"authorization": "Bearer ' || service_role_key || '"}')::jsonb
                       );
                    raise log 'pg_net loop path = %', path;
                end loop;
            end if;

            /* http and pg_net together */
            /* note >2 can be tweaked for using pg_net in a loop for more files.  The tradeoff is number API calls versus time for synch response from http */
            if (http_enabled AND pg_net_enabled) then
                if (array_length(paths,1) > 2) then
                    select status FROM
                        http((
                              'DELETE',
                              instance_url || '/storage/v1/object/' || bucket,
                              ARRAY[http_header('authorization','Bearer ' || service_role_key)],
                              'application/json',
                              file_body
                            )::http_request) into delete_status;  --not sure delete status is useful from storage-API in this case
                    raise log 'both extensions-- http  paths = %', paths;
                else
                    perform net.http_delete(
                            url:=instance_url || '/storage/v1/object/' || bucket || '/' || path,
                            headers:= ('{"authorization": "Bearer ' || service_role_key || '"}')::jsonb
                        );
                    raise log 'both extensions-- pg_net path = %', path;
                end if;
            end if;

            /* if pg_net adds a body to delete all you need is this (not tested)*/
            /*
            perform net.pg_net_http_delete_body(
                    url := instance_url || '/storage/v1/object/' || bucket,
                    headers:= ('{"authorization": "Bearer ' || service_role_key || '", "content-type":"application/json"}')::jsonb,
                    body := file_body::jsonb
            );
            */
        end loop;
    raise log 'finished';
end
$$  language plpgsql security definer
     set search_path = extensions, storage, pg_temp;


/* run this code to setup the cron task */
select
    cron.schedule(
      'invoke-file_clean',
      '*/10 * * * *', -- every 10 minutes
      $$
        select clean_files();
      $$
        );


/* This function should be called from an trigger on auth.users delete.  */
/* It marks all the user's files to be deleted by setting created_at to a fake time and marks owner as null */
/* If you want to preserve some files from being deleted then you need to only mark the owner to null */
/* Optionally metadata is set to null to prevent reading the file as it will be flagged as corrupted.*/

create or replace function public.mark_all_users_files_for_delete()
    returns trigger as $$
begin
    /*  To keep some files in certain bucket
     update storage.objects set
        owner = null
        where owner = old.id and bucket_id = 'anon-file-bucket'; */

    /* Mark all other files for this user as deletable */
    update storage.objects set
        owner = null,
        owner_id = 'Delete_this',
        metadata = null   -- optional
    where owner = old.id;
    return old;
end;
$$ language plpgsql security definer
     set search_path = storage, pg_temp;

create trigger before_delete_user
    before delete on auth.users
    for each row execute function public.mark_all_users_files_for_delete();


/* This function can be called by an authenticated user to delete only from approved buckets */
create or replace function public.mark_file_for_delete(bucket text, filepath text)
    returns void as $$
declare bucket_list text[] := '{"test","testp","test4"}';  -- approved  buckets
begin
    update storage.objects set
       owner = null,
       owner_id = 'Delete_this',
       metadata = null                     -- optional
    where bucket_id = any(bucket_list) and bucket_id = bucket
      and owner = auth.uid() and auth.uid() is not null and name = filepath;

end;
$$ language plpgsql security definer
     set search_path = storage, pg_temp;
