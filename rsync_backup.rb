require 'date'
require 'fileutils'
require 'pathname'
require 'tempfile'
require 'yaml'

APPNAME="rsync_backup"
LOG_LEVEL=2
TIMEINTERVALS = {
  'hourly' => 3600,
  'daily'  => 3600 * 24,
  'weekly' => 3600 * 24 * 7,
  'monthly'=> 3600 * 24 * 30,
  'yearly' => 3600 * 24 * 365,
}

def die(msg)
  puts msg
  exit 1
end

def clog(msg, lvl=0, indent=0)
  if LOG_LEVEL >= lvl
    if (indent > 0)
      sindent = " " * indent
      puts msg.split("\n").map{|l| sindent + l}.join("\n")
    else
      puts msg
    end
  end 
end

def run(cmd)
  cmdout = `#{cmd}`
  cmdsta = $?.exitstatus
  unless cmdsta == 0
    clog("!Error #{cmdsta} running #{cmd}:\n#{cmdout}", 1)
  end
  clog(cmd, 3)
  clog(cmdout, 3)
  return cmdsta, cmdout
end

def run!(cmd)
  cmdsta, cmdout = run(cmd)
  die "!Error #{cmdsta} running #{cmd}:\n#{cmdout}" unless cmdsta == 0
  cmdout
end


def get_device_uuid(name)
  cmdout = run!("diskutil cs info #{name}")
  uuid_line = cmdout.lines.select{|l| l =~ /Parent LVF UUID:/}.first
  if uuid_line.nil?
    die "Error while looking for backup disk #{name}"
  end
  uuid = uuid_line.chomp.gsub(/^.*:\s*/, '')
end

def get_device_encryption_status(uuid)
  cmdout = run!("diskutil cs list #{uuid}")
  esta_line = cmdout.lines.select{|l| l =~ /Encryption Status:/}.first
  if esta_line.nil?
    die "Error while listing backup disk with uuid=#{uuid}"
  end
  esta = esta_line.chomp.gsub(/^.*:\s*/, '')
end

def attached?(name)
  cmdsta, cmdout = run("diskutil list #{name}")
  return cmdsta == 0
end

def mounted?(name)
  cmdout = run!("mount")
  return (cmdout =~ Regexp.new(" /Volumes/#{name} ")) ? true : false
end

def mount!(name)
  die "Backup device #{name} is not attached" unless attached?(name)

  if device_encrypted?(name)
    # Decrypt and mount the device
    unlock_device!(name)
  end

  cmdout = run!("diskutil mount #{name}")
  "/Volumes/#{name}"
end

def unmount!(name)
  if mounted?(name)
    run!("diskutil unmount #{name}")
  end
  die "Disk #{name} is still mounted after unmount" if mounted?(name)
end

# "diskutil cs info" returns error if the disk is not a "CoreStorage disk"
def device_encrypted?(name)
  cmdsta, cmdout = run("diskutil cs info #{name}")
  cmdsta == 0
end

def unlock_device!(name)
  uuid = get_device_uuid(name)
  esta = get_device_encryption_status(uuid)
  if esta == "Locked"
    run!("diskutil cs unlockVolume #{uuid}")
    esta = get_device_encryption_status(uuid)
    die("Could not decrypt backup device #{name}") unless esta == "Unlocked"
  else
    clog "Device #{name} already unlocked", 2
  end
end


def backup_dir(src, dst, dirconf={"frequency" => "daily", "exclude" => {}}, exclude_file=nil)
  now=DateTime.now().to_time
  datedir=now.strftime("%Y-%m-%d-%H%M")
  dstdate = dst + datedir

  deadline = now - TIMEINTERVALS[dirconf['frequency']]

  exc = exclude_file.nil? ? "" : "--exclude-from=#{exclude_file.path} "
  exc << dirconf['exclude'].map{|l| "--exclude='#{l}'"}.join(" ") unless dirconf['exclude'].nil? or dirconf['exclude'].empty?  

  clog "conf: #{dirconf}", 2, 4
  clog "src: #{src}", 2, 4
  clog "dst: #{dst}", 2, 4
  clog "dstdate: #{dstdate}", 2, 4
  clog "exc: #{exc}", 2, 4
  clog "frq: #{dirconf['frequency']}", 2, 4
  clog "ddl: #{deadline.strftime('"%Y-%m-%d-%H%M"')}", 2, 4

  if dst.directory?
    existing_bakcups = dst.children.select{|s| s.basename.to_s =~ /2[0-9]{3}-[0-9]{2}-[0-9]{2}-[0-9]{4}/}
    unless existing_bakcups.empty?
      last_backup = existing_bakcups.sort.last
      last_backup_time = DateTime.strptime("#{last_backup.basename}#{now.zone}", "%Y-%m-%d-%H%M%Z").to_time
      clog "last: #{last_backup_time.strftime('%Y-%m-%d-%H%M')}", 2, 4
      if (last_backup_time < deadline )
        # last backup is too old. Have to be done.

        cmd = "rsync -am --stats --delete --dry-run #{exc} #{src}/ #{last_backup}/"
        cmdout = run!(cmd)
        if cmdout =~ /Number of files transferred: 0/
          clog "Last is old but unchanged rename #{last_backup} to #{dstdate}", 2, 4
          File.rename(last_backup, "#{dstdate}")
          skip=true
        else
          skip=false
          lnk="--link-dest=#{last_backup}"
        end
      else
        skip=true
      end
    end
  else
    FileUtils.mkdir_p dst
    skip=false
  end
  cmd = "rsync -am --delete #{exc} #{lnk} #{src}/ #{dstdate}/"
  clog "lnk: #{lnk}", 2, 4
  clog "skip #{skip ? 'yes' : 'no'}", 2, 4
  unless skip
    # cmdout = run!(cmd)
  end
end

# -----------------------------------------------------------------------------
# 
# Read configuration file from file given as first argument. 
# The file is searched in few standard directories.
#
ymlbase = ARGV[0] || "{APPNAME}.yml"
search_path = [
  "/etc", "/etc/{APPNAME}", 
  File.expand_path('~'), File.expand_path("~/.{APPNAME}"), 
  File.dirname(__FILE__), File.dirname(__FILE__) + "/config", "."
].map{|p| Pathname.new(p)}
while p=search_path.pop
  ymlpath = p + ymlbase
  break if ymlpath.file?
end
die "Cannot find configuration  file #{ymlbase}" unless ymlpath.file?
config = YAML.load_file(ymlpath)

# Minimum validation of the configuration before mounting the disk
base_src = Pathname.new(config['src'])
die("Base source directory not mounted") unless base_src.directory?

mountpath = mount!(config['deviceName'])
base_dst = Pathname.new(mountpath) + config['dst']
FileUtils.mkdir_p(base_dst) unless base_dst.directory?

die("Backup destination is not mounted") unless base_dst.directory?

# Write a temp file containing all the common excludes 
exclude_file = Tempfile.new("rsync_backup.exclude")
exclude_file.write(config['exclude'].join("\n"))
exclude_file.close
begin # ensure exclude_file is deleted 

  config['backups'].each do |backup|

    if backup['dir']
      clog "\nbackup dir  #{backup['dir']}", 2
      src = base_src + backup['dir']
      dst = base_dst + backup['dir']
      dirconf = {
        "frequency" => backup["frequency"]   || "daily",
        "exclude"   => backup["exclude"]     || {},
      }
      backup_dir(src, dst, dirconf, exclude_file)

    else
      clog "\nbackup path #{backup['path']}", 2
      # default configuration for this backup path
      dirconf_default = {
        "frequency" => backup["frequency"]   || "daily",
        "exclude"   => backup["exclude"]     || {},
      }

      # specific subdirectory configurations (if any)
      dirconfigs = backup['configs'] || {}

      base_src_path = base_src + backup['path']
      base_dst_path = base_dst + backup['path']

      base_src_path.each_child do |src|
        next unless src.directory?
        dir = src.basename.to_s
        clog "dir: #{dir}", 2, 2
        next if backup['skip'].include?(dir)
        dst = base_dst_path + dir
        dirconf = dirconfigs.key?(dir) ? dirconf_default.merge(dirconfigs[dir]) : dirconf_default
        backup_dir(src, dst, dirconf, exclude_file)
      end
    end # dir or path
  end # all backups

ensure
  exclude_file.unlink
  unmount!(config['deviceName'])
end
