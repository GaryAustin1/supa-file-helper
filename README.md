Supabase has released the new version of storage and the parts of code here dealing with owner column have to be adjusted to also deal with owner_id for non-uuid sub claims.


# supa-file-helper
SQL code for managing deletion of storage objects in Supabase

Note: 8/23/23 -- Supabase is removing the foreign key on owner in v3 of storage (resumable).  When that happens the cron task should be able to look for owner ids that are not in auth.users.  This might be a better approach when that version is completely rolled out.

This SQL sets up a basic process for marking files to be deleted by a cron task and will delete on a regular schedule.  
   It has:  
   A cron task and function to delete a set files with whatever time period makes sense to manage staying ahead of the deletions.  
   A trigger on auth.users delete to call a function to mark the deleted files and remove the foreign key reference.  
   A function that shows how you can efficiently mark for delete specific user files and not deal with the actual storage delete.  

   It requires your instance URL and your service_role_key.  
   Also shown is an extra schema and table for storing your url and service_role key.  

WARNING this code uses 3 columns in the storage.objects table.  Although the likelihood of these columns being changed by Supabase seems slim, it is not 0.  
  `owner` The fk reference to auth.users,   
  `created_at` Set to 0 time to indicated file to be deleted,  
  `metadata` Set to null so file is reported invalid by the API.  This is optional.  

There is a table in sb_custom_stuff schema that needs to be set up.  
  !!Please only enter your service_role key by hand in the table UI.  Do not put in code that might "escape" to the net.

![sb_custom_schema](https://user-images.githubusercontent.com/54564956/228620077-1caee708-717f-4bdc-b3fd-872b679baed1.JPG)

You will need the pg_cron extension and either or both http and pg_net extensions installed.  The code installs all three.


The general idea behind the code is to mark files for delete in the storage.objects table by setting created_at to 0.  Then a cron task will run every 10 minutes (by default but this can be changed in the code).  The chron tasks groups files by buckets and uses bulk API call using the http extension if installed. It will also use pg_net if installed for smaller groups of files as it is much faster as an async call.  Currently pg_net does not support a delete body so only one file can be deleted per pg_net call.   
