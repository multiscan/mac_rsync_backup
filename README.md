# Mac RSync backup

A script that I use for making periodic copies of selected folders from my laptop to an external (encrypted) disk. It uses the classic _rsync_  with hard links pattern. Therefore, nothing new. The only interesting things are the commands for mounting and decryptin disk devices with `diskutils`. 

## Installation

If you want to automatically run the script for one or more configurations, just put all your `yml` configuration files inside a `config` directory at the same level of the script. Then execute

```
  rsync_backup_cron.sh status
  rsync_backup_cron.sh start
```

This will setup a launchctl job that will run every 30 minutes. 

## Configuration

The script is configured with a `yaml` file. The path of the file (either full or relative to a set of standard paths) is passed as parameter to the script.
 
The configuration file is essentially divided in two parts: 
  1. few global parameters (name of the backup disk, global `rsync` exclude rules, etc.)
  2. a list of _backups_ each providing at least a _dir_ or a _path_ entry. Where
    * a _dir_ will be _rsynced_ as is;
    * a _path_ will only get its childer directories _rsynced_;
 
 Here is an example:

``` yaml
 ---
# Rsync backup configuration file

# The job's title that will be displayed in the notification
title: "BackupUSB"

# Base source path for all backups (my home directory)
src: "/Users/cangiani"


# Destination path relative to backup device root.
dst: "work"

# Backup device informations
device:
  # this is the name given to the disk upon formatting
  name: "BackupUSB"
  pass: "BlueWDPassport2"
  path: "/keybase/private/YOUR_KB_USERNAME/backup_disk_pass.yml"
  # pass is the true password if path is not given 
  # otherwise it is just the key in a file that will look something like:
  # ---
  # BlueWDPassport1: password for disk BlueWDPassport1
  # BlueWDPassport2: password for disk BlueWDPassport2
  # Black2TbUSB: password for disk Black2TbUSB

# Global Exclude used for all backups
exclude:
  - ".DS_Store"
  - "aaa*"
  - "bbb*"
  - "ccc*"
  - "backup"
  - "*.bkp"
  - "data"
  - "deletable"
  - "node_modules"
  - "old"
  - "speta"
  - "PARK"
  - "tmp"
  - "volumes"

# This is the list of directories to backup
backups:
  # I constantly edit my scripts in ~/bin. 
  - dir: "bin"
    frequency: daily
    exclude: {}
    configs: {}
  
  # Where I have currently running projects. The most actively edited are synced hourly.
  - path: Projects/VPSI
    title: "VPSI projects"
    skip: []
    
    # frequency and exclude are inherited (but can be overwriten) by all subfolders
    frequency: daily
    exclude: {}
    
    # when path is given above, we rsync the subfolders of path. Optionally, we can
    # provide special options for each subfolder to override those given for the whole path.
    configs:
      LHD:
        frequency: hourly
        exclude:
          - mysql  
      external-noc:
        frequency: hourly
      inform_docker:
        frequency: hourly
      wp-dev:
        exclude:
          - wordpress-state.tgz

  # This is a path with projects related to my previous job. No need to backup so often....
  - path: Projects/Kandou
    title: "Kandou projects"
    frequency: monthly
    # there is the option to skip one of the subfolders of path
    skip:
      - "bombini"
    exclude: {}
    configs:
      staticmevideo:
        exclude: 
          - "projects"
          
  # Here are projects I essentially no longer touch
  - path: Projects/Archived
    title: "Archived projects"
    frequency: monthly
    skip: []
    exclude: {}
    configs: {}

 ```

An `example.yml` file is provided in a `config_example` directory.

### Using disc images instead of devices

Alternatively, the backup can be done into a disk image. This allows to store encrypted backup on an unencrypted disk that you use also for other things. You may want to create a different backup image foreach project. 

In this case, just add the full path to the image file as `image` in the `device` section as in the following example:

```
...
device:
  name: "KeybaseBackup"
  pass: "keybase"
  path: "/keybase/private/YOUR_KB_USERNAME/ext_disc_pass.yml"
  image: "/backup/keybase.sparsebundle"
```


 ## TODO
  - [X] Fix cron script and make installation easier;
  - [ ] Add a script for cleaning up older backups and free up space on the backup disk;
  - [X] Figure out how to prompt for password when running as cron
  - [X] Add option to backup to disk images instead of physical devices
