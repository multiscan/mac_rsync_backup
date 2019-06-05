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
  cmdout = `#{cmd} 2>/dev/null`
  cmdsta = $?.exitstatus
  clog(cmd, 3)
  clog(cmdout, 3)
  return cmdsta, cmdout
end

def run!(cmd)
  cmdsta, cmdout = run(cmd)
  die "!Error #{cmdsta} running #{cmd}:\n#{cmdout}" unless cmdsta == 0
  cmdout
end

class DiscDevice
  attr_reader :name, :uuid, :info
  def initialize(name)
    @name = name
    @uuid = nil
    @info = {}

    @attached = (run!("diskutil list") =~ Regexp.new(" #{@name} "))
    set_info if @attached
  end

  def attached?()
    @attached
  end

  def is_cs?()
    not @uuid.nil?
  end

  def mounted?()
    cmdout = run!("mount")
    return (cmdout =~ Regexp.new(" /Volumes/#{@name} ")) ? true : false
  end

  # return the name of the mount point or false if device cannot be mounted
  def mount()
    return false unless @attached
    if @uuid
      return false unless unlock()
    end
    cmdsta, cmdout = run("diskutil mount #{@name}")
    if cmdsta == 0
      return "/Volumes/#{@name}"
    else
      return false
    end
  end

  def unmount()
    if mounted?
      run!("diskutil unmount #{@name}")
    end
    return !mounted?
  end

 private

  def parse_info(cmdout=nil)
    @info = {}
    if cmdout.nil?
      name_or_uuid = @uuid ? @uuid : @name
      cmdsta, cmdout = run("diskutil cs info #{name_or_uuid}")
      return unless cmdsta == 0
    end      
    # cmdout.lines.map{|l| l.chomp}.select{|l| l =~ /^\s+[a-zA-Z]:\s+[^ ]+$/}.each do |l|
    cmdout.lines.map{|l| l.chomp}.each do |l|
      k, v = l.split(/:\s*/)
      @info[k.strip] = v
    end
    p @info
  end

  def set_info

    # First try to get info. This works only when disk is already unlocked
    # Apple have never understood how a command line tools should work :(
    cmdsta, cmdout = run("diskutil cs info #{@name}")
    if cmdsta == 0
      parse_info(cmdout)
      @uuid = @info["UUID"]
    else
      cmdout = run!("diskutil cs list")
      m = cmdout =~ Regexp.new(" #{@name} *$")
      return unless m
      ll = cmdout.lines.map{|l| l.chomp}
      m = false      
      until m
        l = ll.pop
        m = (l =~ Regexp.new("LV Name:\s*#{@name}$"))
      end
      m = false      
      until m
        l = ll.pop
        m = (l =~ Regexp.new("Logical Volume"))
      end
      @uuid = l.split.last
      parse_info
    end
  end

  def unlock()
    return true unless @uuid
    return true unless @info['LV Status'] == "Locked"
    cmdsta, cmdout = run("diskutil cs unlockVolume #{@uuid}")
    if cmdsta == 0
      parse_info
      return @info['LV Status'] != "Locked"
    else
      return false
    end
  end

end

# d = DiscDevice.new("RsyncBackup")
# puts "uuid = #{d.uuid}"

# puts "already mounted? #{d.mounted? ? 'yes' : 'no'}"

# if d.mounted?
#   puts "Disk is already mounted. Let's unmount it"
#   if d.unmount
#     puts "Ok Disk is now unmounted"
#   else
#     puts "!! Failed to unmount"
#   end
# else
#   puts "Disk is npt mounted. Let's mount it"
#   if d.mount
#     puts "Ok Disk is now mounted"
#   else
#     puts "!! Failed to mount"
#   end
# end

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
ymlpath = Pathname.new(ymlbase)
unless ymlpath.file?
  search_path = [
    "/etc", "/etc/{APPNAME}", 
    File.expand_path('~'), File.expand_path("~/.{APPNAME}"), 
    File.dirname(__FILE__), File.dirname(__FILE__) + "/config", "."
  ].map{|p| Pathname.new(p)}
  while p=search_path.pop
    ymlpath = p + ymlbase
    break if ymlpath.file?
  end
end
die "Cannot find configuration  file #{ymlbase}" unless ymlpath.file?
config = YAML.load_file(ymlpath)

# Minimum validation of the configuration before mounting the disk
base_src = Pathname.new(config['src'])
die("Base source directory not mounted") unless base_src.directory?

bkpdev = DiscDevice.new(config['deviceName'])
mountpath = bkpdev.mount
die "Could not mount Backup disk #{config['deviceName']}" unless mountpath

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
  bkpdev.unmount
end
