module BlueHydra
  class Runner

    attr_accessor :command,
                  :raw_queue,
                  :chunk_queue,
                  :result_queue,
                  :btmon_thread,
                  :discovery_thread,
                  :chunker_thread,
                  :parser_thread,
                  :info_scan_queue,
                  :l2ping_queue,
                  :result_thread

    if BlueHydra.config[:file]
      if BlueHydra.config[:file] =~ /\.xz$/
        @@command = "xzcat #{BlueHydra.config[:file]}"
      else
        @@command = "cat #{BlueHydra.config[:file]}"
      end
    else
      @@command = "btmon -T -i #{BlueHydra.config[:bt_device]}"
    end

    def start(command=@@command)
      begin
        BlueHydra.logger.info("Runner starting with '#{command}' ...")
        self.command         = command
        self.raw_queue       = Queue.new
        self.chunk_queue     = Queue.new
        self.result_queue    = Queue.new
        self.info_scan_queue = Queue.new
        self.l2ping_queue    = Queue.new

        start_btmon_thread
        start_discovery_thread unless BlueHydra.config[:file]
        start_chunker_thread
        start_parser_thread
        start_result_thread

      rescue => e
        BlueHydra.logger.error("Runner master thread: #{e.message}")
        e.backtrace.each do |x|
          BlueHydra.logger.error("#{x}")
        end
      end
    end

    def stop
      BlueHydra.logger.info("Runner exiting...")
      self.raw_queue       = nil
      self.chunk_queue     = nil
      self.result_queue    = nil
      self.info_scan_queue = nil
      self.l2ping_queue    = nil

      self.btmon_thread.kill
      self.discovery_thread.kill unless BlueHydra.config[:file]
      self.chunker_thread.kill
      self.parser_thread.kill
      self.result_thread.kill
    end

    def start_btmon_thread
      BlueHydra.logger.info("Btmon thread starting")
      self.btmon_thread = Thread.new do
        begin
          spawner = BlueHydra::BtmonHandler.new(
            self.command,
            self.raw_queue
          )
        rescue => e
          BlueHydra.logger.error("Btmon thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
        end
      end
    end

    def start_discovery_thread
      BlueHydra.logger.info("Discovery thread starting")
      self.discovery_thread = Thread.new do
        begin
          discovery_command = "#{File.expand_path('../../../bin/test-discovery', __FILE__)} -i #{BlueHydra.config[:bt_device]}"
          loop do
            begin

              # do a discovery
              interface_reset = BlueHydra::Command.execute3("hciconfig #{BlueHydra.config[:bt_device]} reset")
              sleep 1
              discovery_errors = BlueHydra::Command.execute3(discovery_command)[:stderr]

              if discovery_errors
                BlueHydra.logger.error("Error with test-discovery script..")
                discovery_errors.split("\n").each do |ln|
                  BlueHydra.logger.error(ln)
                end
              end

              # clear queues
              until info_scan_queue.empty? && l2ping_queue.empty?

                # clear out entire info scan queue
                until info_scan_queue.empty?
                  BlueHydra.logger.debug("Popping off info scan queue. Depth: #{ info_scan_queue.length}")
                  command = info_scan_queue.pop
                  case command[:command]
                  when :info
                    BlueHydra::Command.execute3("hcitool -i #{BlueHydra.config[:bt_device]} info #{command[:address]}")
                  when :leinfo
                    BlueHydra::Command.execute3("hcitool -i #{BlueHydra.config[:bt_device]} leinfo --random #{command[:address]}")
                  else
                    BlueHydra.logger.error("Invalid command detected... #{command.inspect}")
                  end
                end

                # run 1 l2ping a time while still checking if info scan queue
                # is empty
                unless l2ping_queue.empty?
                  command = l2ping_queue.pop
                  BlueHydra::Command.execute3("l2ping -c 3 -i #{BlueHydra.config[:bt_device]} #{command[:address]}")
                end
              end

            rescue => e
              BlueHydra.logger.error("Discovery loop crashed: #{e.message}")
              e.backtrace.each do |x|
                BlueHydra.logger.error("#{x}")
              end
              BlueHydra.logger.error("Sleeping 20s...")
              sleep 20
            end

            # sleep
            sleep 1
          end
        rescue => e
          BlueHydra.logger.error("Discovery thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
        end
      end
    end

    def start_chunker_thread
      BlueHydra.logger.info("Chunker thread starting")
      self.chunker_thread = Thread.new do
        begin
          chunker = BlueHydra::Chunker.new(
            self.raw_queue,
            self.chunk_queue
          )
          chunker.chunk_it_up
        rescue => e
          BlueHydra.logger.error("Chunker thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
        end
      end
    end

    def start_parser_thread
      BlueHydra.logger.info("Parser thread starting")
      self.parser_thread = Thread.new do
        begin
          while chunk = chunk_queue.pop do
            p = BlueHydra::Parser.new(chunk)
            p.parse
            result_queue.push(p.attributes)
          end
        rescue => e
          BlueHydra.logger.error("Parser thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
        end
      end
    end

    def start_result_thread
      BlueHydra.logger.info("Result thread starting")
      self.result_thread = Thread.new do
        begin
          query_history = {}
          loop do

            unless BlueHydra.config[:file]
              # if their last_seen value is > 15 minutes ago and not > 1 hour ago
              #   l2ping them :  "l2ping -c 3 result[:address]"
              BlueHydra::Device.all.select{|x|
                x.last_seen < (Time.now.to_i - (60 * 15)) && x.last_seen > (Time.now.to_i - (60*60))
              }.each{|device|
                query_history[device.address] ||= {}
                if (Time.now.to_i - (15 * 60)) >= query_history[device.address][:l2ping].to_i
                  #BlueHydra.logger.debug("device l2ping scan triggered")
                  l2ping_queue.push({
                    command: :l2ping,
                    address: device.address
                  })
                  query_history[device.address][:l2ping] = Time.now.to_i
                end
              }
            end

            until result_queue.empty?

              if (queue_depth = result_queue.length) > 100
                BlueHydra.logger.warn("Popping off result queue. Depth: #{queue_depth}")
              end

              result = result_queue.pop
              if result[:address]
                device = BlueHydra::Device.update_or_create_from_result(result)

                query_history[device.address] ||= {}

                unless BlueHydra.config[:file]
                  # BlueHydra.logger.debug("#{device.address} | le: #{device.le_mode.inspect}| classic: #{device.classic_mode.inspect} | hist: #{query_history[device.address]}")

                  if device.le_mode
                    # device.le_mode - this is a le device which has not been queried for >=15m
                    #   if true, add to active_queue to "hcitool leinfo result[:address]"
                    if (Time.now.to_i - (15 * 60)) >= query_history[device.address][:le].to_i
                      #BlueHydra.logger.debug("device le scan triggered")
                      info_scan_queue.push({command: :leinfo, address: device.address})
                      query_history[device.address][:le] = Time.now.to_i
                    end
                  end

                  if device.classic_mode
                    # device.classic_mode - this is a classic device which has not been queried for >=15m
                    #   if true, add to active_queue "hcitool info result[:address]"
                    if (Time.now.to_i - (15 * 60)) >= query_history[device.address][:classic].to_i
                      #BlueHydra.logger.debug("device classic scan triggered")
                      info_scan_queue.push({command: :info, address: device.address})
                      query_history[device.address][:classic] = Time.now.to_i
                    end
                  end
                end

              else
                BlueHydra.logger.warn("Device without address #{JSON.generate(result)}")
              end
            end

            unless BlueHydra.config[:file]
              # mark hosts as 'offline' if we haven't seen for a while
              BlueHydra::Device.all(status: "online").select{|x|
                x.last_seen < (Time.now.to_i - (60*60))
              }.each{|device|
                device.status = 'offline'
                device.save
              }
            end

            sleep 1
          end

        rescue => e
          BlueHydra.logger.error("Result thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
        end
      end

    end
  end
end
