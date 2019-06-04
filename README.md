# Mac RSync backup

A script that I use for making periodic copies of selected folders from my laptop to an external (encrypted) disk. It uses the classic _rsync_  with hard links pattern. Therefore, nothing new. The only interesting things are the commands for mounting and decryptin disk devices with `diskutils`. 

## Installation

**To be done**. I would like to have the script started avery hour when the external disk is attached. Some of the things needed are in the `rsync_backup_cron.sh` shell script which is no longer working because the main script have changed since.

## Configuration

The script is configured with a `yaml` file which is essentially divided in two parts: 
  1. few global parameters (name of the backup disk, global `rsync` exclude rules, etc.)
  2. a list of _backups_ each providing at least a _dir_ or a _path_ entry. Where
    * a _dir_ will be _rsynced_ as is;
    * a _path_ will only get its childer directories _rsynced_;
 
 Here is an example:

``` yaml
 ---
# Rsync backup configuration file

# Base source path for all backups (my home directory)
src: "/Users/cangiani"

# Destination device and path. In this example final destinatino will be /Volumes/RsyncBackup/work
deviceName: "RsyncBackup"
encrypted: 1
dst: "work"

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
 
 ## TODO
  - [ ] Fix cron script and make installation easier;
  - [ ] Add a script for cleaning up older backups and free up space on the backup disk;
