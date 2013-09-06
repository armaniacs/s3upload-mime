#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
require 'rubygems'
require 'aws-sdk'
require 'time'
require 'digest/md5'
require 'find'
require 'dbm'
require 'mime/types'

def help
  puts "*** This codes are released under the Apache licence verion 2.0. ***"
  puts ""
  puts "This program upload files in local directory and subdirectory to s3."
  puts "For over 10MB file, it automatically uploads in multipart mode."
  puts ""
  puts "Notes:"
  puts "  Local file modification is detected by MD5 calculation."
  puts "  *.db files are created for management of files."
  puts ""
  puts ""
  puts "  Mime-Types are automatically attached by suffix of filename at almost filenames."
  puts "  You can modify custom_mime_type hash in this file."
  puts ""
  puts "Before use:"
  puts "  Please set 'AWS_ACCESS_KEY_ID' and 'AWS_SECRET_ACCESS_KEY' in ENV. "
  puts ""
  puts "Usage example:\n  ruby #{__FILE__} local_directory_path s3://bucketname/folder/ "
end

unless ARGV[0]
  help
  exit 1
end

# local
unless File.directory?(ARGV[0])
  puts "Error: set local directory path"
  help
  exit 1
end
local_dir = File.absolute_path(ARGV[0])

if ARGV[1] =~ /^s3:\/\/((\w|\.|-){3,63})\/((\w|\.|-|\/)+)$/
  s3_bucketname = $1
  s3_dirname = $3
elsif ARGV[1] =~ /^s3:\/\/((\w|\.|-){3,63})\/$/
  s3_bucketname = $1
  s3_dirname = ''
end

AWS.config({
  :access_key_id => ENV['AWS_ACCESS_KEY_ID'],
  :secret_access_key => ENV['AWS_SECRET_ACCESS_KEY']
})
s3 = AWS::S3.new

cs = {
  'db_local_list' => DBM.open("#{local_dir}/.s3upload-mime-local", 0600, DBM::WRCREAT),
  'db_local_new' => DBM.open("#{local_dir}/.s3upload-mime-localnew", 0600, DBM::NEWDB),

  'db_local_tbu' => DBM.open("#{local_dir}/.s3upload-mime-localtbu", 0600, DBM::NEWDB), # to be upload
  'db_local_only' => DBM.open("#{local_dir}/.s3upload-mime-localonly", 0600, DBM::NEWDB),
  'local_dir' => local_dir,

  'db_s3_list' => DBM.open("#{local_dir}/.s3upload-mime", 0600, DBM::WRCREAT),
  'db_s3_new' => DBM.open("#{local_dir}/.s3upload-mime-new", 0600, DBM::NEWDB),
  'bucket' => s3.buckets[s3_bucketname],
  's3_dir' => s3_dirname,
  'custom_mime_type' => {'.PBP' => 'application/x-psp-update'},

  'full_sync' => false
}



def local_list_update(cs)
  db_local_list = cs['db_local_list']
  db_local_new = cs['db_local_new']

  l_flist = Find.find(cs['local_dir'])
  l_flist.each do |f|
    if File.directory?(f) or File.extname(f) == '.db' or f =~/(~|\.orig|\.bak|\.\d+)$/
      next
    end
    f.gsub!(/^#{cs['local_dir']}\//,'')

    if db_local_list[f] && db_local_list[f] != File.mtime(f).to_s
      db_local_list[f] = File.mtime(f)
      db_local_new[f] = db_local_list[f]
    end
    unless db_local_list[f]
      db_local_list[f] = File.mtime(f)
      db_local_new[f] = db_local_list[f]
    end
  end
end

def s3_list_update(cs)
  bucket = cs['bucket']
  s3_dir = cs['s3_dir']
  db_s3_list = cs['db_s3_list']
  db_s3_new = cs['db_s3_new']

  tree = bucket.as_tree({:prefix => s3_dir})
  files = tree.children.select(&:leaf?).collect(&:key)
  files.each do |f|
    ftmp = f.gsub(/^#{s3_dir}/,'')
    next if ftmp == ''

    if db_s3_list[ftmp] && db_s3_list[ftmp] != bucket.objects[f].last_modified.to_s
      db_s3_list[ftmp] = bucket.objects[f].last_modified
      db_s3_new[ftmp] = db_s3_list[f]
    end
    unless db_s3_list[ftmp]
      db_s3_list[ftmp] = bucket.objects[f].last_modified
      db_s3_new[ftmp] = db_s3_list[ftmp]
    end
  end
end

def make_local_tbu(cs)
  if cs['full_sync']
    cs['db_local_tbu'] = cs['db_local_list']
  else
    cs['db_local_tbu'] = cs['db_local_new']
  end

  cs['db_local_tbu'].each do |k,v|
    if s3obj = cs['db_s3_list'][k]
      d_local = DateTime.parse(v)
      d_s3 = DateTime.parse(s3obj)

      if d_local > d_s3
#        puts "local is newer! To be update."
      else
        cs['db_local_tbu'].delete(k)
      end
    else # localだけにあってs3には存在しない
      cs['db_local_only'][k] = v
    end
  end
end

def make_upload(cs)
  bucket = cs['bucket']
  s3dir = cs['s3_dir']
  local_dir = cs['local_dir']

  cs['db_local_tbu'].each do |k,v|
    obj = bucket.objects["#{s3dir}#{k}"]
    s_file = "#{local_dir}/#{k}"
    filesum = Digest::MD5.file(s_file).to_s

    if cs['db_local_only'][k]
      puts "#{k} is new file. To be upload."
      upload_s3(cs, obj, s_file, filesum)
      next
    end

    # check time 
    d_s3 = DateTime.parse(obj.last_modified.to_s)
    d_local = DateTime.parse(v)
    if d_local <= d_s3
      puts "local is older. No update. #{__LINE__}"
      next
    end
    
    # check md5
    # puts "#{s_file} in local MD5" 

    md5_s3 = obj.metadata['md5']
    unless md5_s3
      md5_s3 = obj.etag.tr!('"','')
    end

    if md5_s3 == filesum
      puts "same md5. No upload. #{__LINE__}"
      next
    end

    puts "local #{s_file} is newer! To be update. #{__LINE__}"
    upload_s3(cs, obj, s_file, filesum)

  end
end

def upload_s3(cs, obj, file, filesum)
  f_ext = File.extname(file)
  if cs['custom_mime_type'][f_ext]
    mime_type = cs['custom_mime_type'][f_ext]
  else
    mime_type = MIME::Types.type_for(file)[0].to_s
  end
  obj.write(:file => file, :multipart_threshold => 10 * 1024 * 1024, :content_type => mime_type, :metadata => {'md5' => filesum}) 
  
end

local_list_update(cs)
s3_list_update(cs)
make_local_tbu(cs)
make_upload(cs)

