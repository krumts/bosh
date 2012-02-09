require 'fileutils'

module Bosh::Agent
  module Message

    class MigrateDisk < Base
      def self.long_running?; true; end

      def self.process(args)
        #logger = Bosh::Agent::Config.logger
        #logger.info("MigrateDisk:" + args.inspect)

        self.new.migrate(args)
        {}
      end

      def migrate(args)
        logger.info("MigrateDisk:" + args.inspect)
        @old_cid, @new_cid = args

        300.times do |n|
          break if `lsof -t +D #{store_path}`.empty? && `lsof -t +D #{store_migration_target}`.empty?
          if n == 299
            raise Bosh::Agent::MessageHandlerError,
              "Failed to migrate store to new disk still processes with open files"
          end
          sleep 1
        end

        # TODO: remount old store read-only
        if check_mountpoints
          logger.info("Copy data from old to new store disk")
          `(cd #{store_path} && tar cf - .) | (cd #{store_migration_target} && tar xpf -)`
        end

        unmount_store
        unmount_store_migration_target
        mount_new_store
      end

      def check_mountpoints
        Pathname.new(store_path).mountpoint? && Pathname.new(store_migration_target).mountpoint?
      end

      def unmount_store
        `umount #{store_path}`
      end

      def unmount_store_migration_target
        `umount #{store_migration_target}`
      end

      def mount_new_store
        disk = DiskUtil.lookup_disk_by_cid(@new_cid)
        partition = "#{disk}1"
        logger.info("Mounting: #{partition} #{store_path}")
        `mount #{partition} #{store_path}`
        unless $?.exitstatus == 0
          raise Bosh::Agent::MessageHandlerError, "Failed to mount: #{partition} #{store_path} (exit code #{$?.exitstatus})"
        end
      end

    end

    class ListDisk < Base
      def self.process(args = nil)
        disk_info = []
        settings = Bosh::Agent::Config.settings

        # TODO abstraction for settings
        if settings["disks"].kind_of?(Hash) && settings["disks"]["persistent"].kind_of?(Hash)
          cids = settings["disks"]["persistent"]
        else
          cids = {}
        end

        cids.each_key do |cid|
          partition = "#{DiskUtil.lookup_disk_by_cid(cid)}1"
          disk_info << cid unless DiskUtil.mount_entry(partition).nil?
        end
        disk_info
      end
    end

    class MountDisk < Base
      def self.process(args)
        new(args).mount
      end

      def initialize(args)
        @cid = args.first
      end

      def mount
        if Bosh::Agent::Config.configure
          update_settings
          logger.info("MountDisk: #{@cid} - #{settings['disks'].inspect}")

          rescan_scsi_bus
          setup_disk
        end
      end

      def update_settings
        Bosh::Agent::Config.settings = Bosh::Agent::Config.infrastructure.load_settings
        logger.info("Settings: #{settings}")
      end

      def rescan_scsi_bus
        `/sbin/rescan-scsi-bus.sh`
        unless $?.exitstatus == 0
          raise Bosh::Agent::MessageHandlerError, "Failed to run /sbin/rescan-scsi-bus.sh (exit code #{$?.exitstatus})"
        end
      end

      def setup_disk
        disk = DiskUtil.lookup_disk_by_cid(@cid)
        partition = "#{disk}1"

        logger.info("setup disk settings: #{settings.inspect}")

        read_disk_attempts = 300
        read_disk_attempts.downto(0) do |n|
          begin
            # Parition table is blank
            disk_data = File.read(disk, 512)

            if disk_data == "\x00"*512
              logger.info("Found blank disk #{disk}")
            else
              logger.info("Disk has partition table")
              logger.info(`sfdisk -Llq #{disk} 2> /dev/null`)
            end
            break
          rescue => e
            # Do nothing - we'll retry
            logger.info("Re-trying reading from #{disk}")
          end

          if n == 0
            raise Bosh::Agent::MessageHandlerError, "Unable to read from new disk"
          end
          sleep 1
        end

        if File.blockdev?(disk) && DiskUtil.ensure_no_partition?(disk, partition)
          full_disk = ",,L\n"
          logger.info("Partitioning #{disk}")

          Bosh::Agent::Util.partition_disk(disk, full_disk)

          `/sbin/mke2fs -t ext4 -j #{partition}`
          unless $?.exitstatus == 0
            raise Bosh::Agent::MessageHandlerError, "Failed create file system (#{$?.exitstatus})"
          end
        elsif File.blockdev?(partition)
          logger.info("Found existing partition on #{disk}")
          # Do nothing
        else
          raise Bosh::Agent::MessageHandlerError, "Unable to format #{disk}"
        end

        mount_persistent_disk(partition)
        {}
      end

      def mount_persistent_disk(partition)
        store_mountpoint = File.join(base_dir, 'store')

        if Pathname.new(store_mountpoint).mountpoint?
          logger.info("Mounting persistent disk store migration target")
          mountpoint = File.join(base_dir, 'store_migraton_target')
        else
          logger.info("Mounting persistent disk store")
          mountpoint = store_mountpoint
        end

        FileUtils.mkdir_p(mountpoint)
        FileUtils.chmod(0700, mountpoint)

        logger.info("Mount #{partition} #{mountpoint}")
        `mount #{partition} #{mountpoint}`
        unless $?.exitstatus == 0
          raise Bosh::Agent::MessageHandlerError, "Failed mount #{partition} on #{mountpoint} #{$?.exitstatus}"
        end
      end

      def self.long_running?; true; end
    end

    class UnmountDisk < Base
      GUARD_RETRIES = 300
      GUARD_SLEEP = 1

      def self.long_running?; true; end

      def self.process(args)
        self.new.unmount(args)
      end

      def unmount(args)
        cid = args.first
        disk = DiskUtil.lookup_disk_by_cid(cid)
        partition = "#{disk}1"

        if DiskUtil.mount_entry(partition)
          @block, @mountpoint = DiskUtil.mount_entry(partition).split
          lsof_guard
          umount_guard
          logger.info("Unmounted #{@block} on #{@mountpoint}")
          return {:message => "Unmounted #{@block} on #{@mountpoint}" }
        else
          # TODO: should we raise MessageHandlerError here?
          return {:message => "Unknown mount for partition: #{partition}"}
        end
      end

      def lsof_guard
        lsof_attempts = GUARD_RETRIES
        until lsof_output = `lsof -t +D #{@mountpoint}`.empty?
          sleep GUARD_SLEEP
          lsof_attempts -= 1
          if lsof_attempts == 0
            raise Bosh::Agent::MessageHandlerError, "Failed lsof guard #{@block} on #{@mountpoint}: #{lsof_output}"
          end
        end
        logger.info("Unmount lsof_guard (attempts: #{GUARD_RETRIES-lsof_attempts})")
      end

      def umount_guard
        umount_attempts = GUARD_RETRIES
        loop {
          umount_output = `umount #{@mountpoint}`
          if $?.exitstatus == 0
            break
          else
            sleep GUARD_SLEEP
            umount_attempts -= 1
            if umount_attempts == 0
              raise Bosh::Agent::MessageHandlerError, "Failed to umount #{@block} on #{@mountpoint}: #{umount_output}"
            end
          end
        }
        logger.info("Unmount umount_guard (attempts: #{GUARD_RETRIES-umount_attempts})")
      end
    end

    class DiskUtil
      class << self
        def logger
          Bosh::Agent::Config.logger
        end

        def base_dir
          Bosh::Agent::Config.base_dir
        end

        def lookup_disk_by_cid(cid)
          settings = Bosh::Agent::Config.settings
          disk_id = settings['disks']['persistent'][cid]

          unless disk_id
            raise Bosh::Agent::MessageHandlerError, "Unknown persistent disk: #{cid}"
          end

          sys_path = detect_block_device(disk_id)
          blockdev = File.basename(sys_path)
          File.join('/dev', blockdev)
        end

        def detect_block_device(disk_id)
          dev_path = "/sys/bus/scsi/devices/2:0:#{disk_id}:0/block/*"
          while Dir[dev_path].empty?
            logger.info("Waiting for #{dev_path}")
            sleep 0.1
          end
          Dir[dev_path].first
        end

        def mount_entry(partition)
          File.read('/proc/mounts').lines.select { |l| l.match(/#{partition}/) }.first
        end

        # Pay a penalty on this check the first time a persistent disk is added to a system
        def ensure_no_partition?(disk, partition)
          check_count = 2
          check_count.times do
            if sfdisk_lookup_partition(disk, partition).empty?
              # keep on trying
            else
              if File.blockdev?(partition)
                return false # break early if partition is there
              end
            end
            sleep 1
          end

          # Double check that the /dev entry is there
          if File.blockdev?(partition)
            return false
          else
            return true
          end
        end

        def sfdisk_lookup_partition(disk, partition)
          `sfdisk -Llq #{disk}`.lines.select { |l| l.match(%q{/\A#{partition}.*83.*Linux}) }
        end

        def get_usage
          result = {
            "system" => { "percent" => nil },
            "ephemeral" => { "percent" => nil },
          }

          disk_usage = `#{disk_usage_command}`

          if $?.to_i != 0
            logger.error("Failed to get disk usage data, df exit code = #{$?.to_i}")
            return result
          end

          disk_usage.split("\n")[1..-1].each do |line|
            usage, mountpoint = line.split(/\s+/)
            usage.gsub!(/%$/, '')

            case mountpoint
            when "/"
              result["system"]["percent"] = usage
            when File.join("#{base_dir}", "data")
              result["ephemeral"]["percent"] = usage
            when File.join("#{base_dir}", "store")
              # Only include persistent disk data if
              # persistent disk is there
              result["persistent"] = { }
              result["persistent"]["percent"] = usage
            end
          end

          result
        end

        def disk_usage_command
          # '-l' excludes non-local partitions.
          # This allows us not to worry about NFS.
          "df -l | awk '{print $5, $6}'"
        end

      end
    end
  end
end
