# supa-file-helper
SQL code for managing deletion of storage objects in Supabase

5/27/2024 -- updated to use the new owner_id and fact that owner is no longer linked to auth.users.

This SQL sets up a basic process for marking files to be deleted by a cron task and will delete on a regular schedule.  
   It has:  
   A cron task and function to delete a set files with whatever time period makes sense to manage staying ahead of the deletions.  
   A trigger on auth.users delete to call a function to mark the deleted files and remove the foreign key reference.  
   A function that shows how you can efficiently mark for delete specific user files and not deal with the actual storage delete.  

   It requires your instance URL and your service_role_key in Vault.  

WARNING this code uses 3 columns in the storage.objects table.  
  `owner` Set to null
  `owner_id` Set to 'Delete_this'
  `metadata` Set to null so file is reported invalid by the API.  This is optional.  


You will need the pg_cron extension and either or both http and pg_net extensions installed.  The code installs all three.


The general idea behind the code is to mark files for delete in the storage.objects table by setting owner_id to 'Delete_this'.  Then a cron task will run every 10 minutes (by default but this can be changed in the code).  The chron tasks groups files by buckets and uses bulk API call using the http extension if installed. It will also use pg_net if installed for smaller groups of files as it is much faster as an async call.  Currently pg_net does not support a delete body so only one file can be deleted per pg_net call.   
