require 'date'
require 'fileutils'
require 'open3'
require 'pathname'
require 'tempfile'
require 'yaml'

APPNAME="rsync_backup"
LOG_LEVEL=0
DONOTIFY=true
TIMEINTERVALS = {
  'hourly' => 3600,
  'daily'  => 3600 * 24,
  'weekly' => 3600 * 24 * 7,
  'monthly'=> 3600 * 24 * 30,
  'yearly' => 3600 * 24 * 365,
}

def die(msg)
  clog msg
  notify(msg) if DONOTIFY
  exit 1
end

def notify(msg)
  cmd = "osascript -e 'display notification \""
  cmd << msg
  cmd << "\" with title \"Rsync Backup\"'"
  run(cmd)
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
  notify(msg) if (DONOTIFY and lvl==0)
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

class Disc
  attr_reader :name, :mountpoint
  def initialize(name)
    @name = name
    @mountpoint = "/Volumes/#{@name}"
  end

  def attached?()
    Regexp.new(" #{@name} ") === run!("diskutil list")
  end

  def mounted?()
    ! dev.nil?
    # cmdout = run!("mount")
    # mounted = (Regexp.new(" on #{@mountpoint} ") === cmdout)
    # return mounted
  end

  def path()
    mounted? ? @mountpoint : nil
  end

  def dev()
    cmdout = run!("mount")
    re=Regexp.new("/dev/(.*) on #{@mountpoint} ")
    m=re.match(cmdout)
    return m.nil? ? nil : m[1]
  end
end

class DiscImage < Disc
  attr_reader :imagepath
  def initialize(name, imgpath)
    super(name)
    @imagepath = imgpath
    @info = nil
  end

  def locked?
    return true if attached?
    if @info.nil? || !@info.key?('encrypted')
      @info ||= {}
      cmdout = run!("hdiutil isencrypted #{@imagepath}")
      cmdout.lines.map{|l| l.chomp}.each do |l|
        k, v = l.split(/:\s*/)
        @info[k.strip] = v
      end
    end
    return @info['encrypted'] == "YES"
  end

  def mount(pass=nil)
    out, status = Open3.capture2("hdiutil attach -stdinpass #{@imagepath} -mountpoint #{@mountpoint}", :stdin_data=>pass)
    if status.exitstatus == 0
      @dev = out.lines.first.split.first.sub("/dev/", "")
      return true
    else
      return false
    end
  end

  def unmount()
    if mounted?
      run!("hdiutil detach #{dev}")
    end
    return !mounted?
  end

end

class DiscDevice < Disc
  attr_reader :uuid, :info
  def initialize(name)
    super(name)
    @uuid = nil
    @info = {}
    set_info if attached?
  end

  def locked?
    return false unless @uuid
    return @info['LV Status'] == "Locked"
  end

  def is_cs?()
    not @uuid.nil?
  end

  # return the name of the mount point or false if device cannot be mounted
  def mount(pass=nil)
    return false unless attached?
    return false if pass.nil? and locked?
    if @uuid
      return false unless unlock(pass)
    end
    cmdsta, cmdout = run("diskutil mount #{@name}")
    return cmdsta == 0
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
    cmdout.lines.map{|l| l.chomp}.each do |l|
      k, v = l.split(/:\s*/)
      @info[k.strip] = v
    end
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

  def unlock(pass)
    return true unless @uuid
    return true unless @info['LV Status'] == "Locked"
    cmdsta, cmdout = run("diskutil cs unlockVolume #{@uuid} -passphrase #{pass}")
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

def get_device_password(devconf)
  devicePass=nil
  # if a path is given then we assume the password is in an external file
  # a) the first line of a plain
  # b) a dictionary from a yml file that stores the pass on the 'pass' key
  if devconf.key?('path')
    p = Pathname.new(devconf['path'])
    die "Cannot read backup device password file #{p}" unless (p.file? and p.readable?)
    if p.extname == ".yml"
      clog "Reading password from yml file #{p} (ext=#{p.extname})", 2
      allpass = YAML.load_file(p)
      die "Cannot find password for backup disk #{bkpdev.name} in yml file #{p}" unless allpass.key?(devconf['pass'])
      devicePass = allpass[devconf['pass']]
    else
      clog "Reading password from plain text file #{p} (ext=#{p.extname})", 2
      devicePass = File.open(p) {|f| f.readline}
    end
  elsif devconf.key?('pass')
    devicePass = devconf['pass']
  end
  return devicePass
end

def mount_device!(devconf)
  if devconf.key?('image') 
    bkpdev = DiscImage.new(devconf['name'], devconf['image'])
  else
    bkpdev = DiscDevice.new(devconf['name'])
  end

  mountpath = nil
  if bkpdev.locked?
    devicePass=get_device_password(devconf)
    die "Encrypted disk #{bkpdev.name} needs password to be mounted" if devicePass.nil?
    clog "Mounting locked backup device with password #{devicePass}", 2
    bkpdev.mount(devicePass)
  else
    clog "Mounting unlocked backup device without password", 2
    bkpdev.mount
  end
  die "Could not mount Backup disk #{bkpdev.name}" unless bkpdev.mounted?
  clog "Backup disk successfully mounted", 2
  return bkpdev
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
  if skip
    return 0
  else
    run!(cmd)
    return 1
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

die "Device not provided" unless config.key?('device')
bkpdev = mount_device!(config['device'])

base_dst = Pathname.new(bkpdev.path) + config['dst']
FileUtils.mkdir_p(base_dst) unless base_dst.directory?

die("Backup destination is not mounted") unless base_dst.directory?

# Write a temp file containing all the common excludes 
exclude_file = Tempfile.new("rsync_backup.exclude")
exclude_file.write(config['exclude'].join("\n"))
exclude_file.close

dircount_total = 0
dircount_changed = 0

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
      dircount_total = dircount_total + 1
      dircount_changed = dircount_changed + backup_dir(src, dst, dirconf, exclude_file)

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

        dircount_total = dircount_total + 1
        dircount_changed = dircount_changed + backup_dir(src, dst, dirconf, exclude_file)
      end
    end # dir or path
  end # all backups

ensure
  exclude_file.unlink
  bkpdev.unmount
end
clog "#{config['title']||'Done'}: #{dircount_changed } / #{dircount_total} changed." 