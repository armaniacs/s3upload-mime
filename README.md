s3upload-mime
=============

A ruby program for uploading to S3 with Mime-Type care. s3upload-mime automatically detects Mime-Type of file at uploading to S3.
*** This codes are released under the Apache licence verion 2.0. ***

For Large File
-------------------
This program upload files in local directory and subdirectory to s3.
For over 10MB file, it automatically uploads in multipart mode.

Notes:
  Local file modification is detected by MD5 calculation.
  *.db files are created for management of files.

For Web hosting on S3
-------------------------
Mime-Types are automatically attached by suffix of filename at almost filenames.
You can modify custom_mime_type hash in this file.

Before use
------------------
Please set 'AWS_ACCESS_KEY_ID' and 'AWS_SECRET_ACCESS_KEY' in ENV. 

Usage example
------------------
ruby s3upload-mime.rb local_directory_path s3://bucketname/folder/ 
