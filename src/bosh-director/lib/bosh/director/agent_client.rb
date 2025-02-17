require 'bosh/director/agent_message_converter'

module Bosh::Director
  class AgentClient

    PROTOCOL_VERSION = 3

    DEFAULT_POLL_INTERVAL = 1.0

    STOP_MESSAGE_TIMEOUT = 300 # 5 minutes
    SYNC_DNS_MESSAGE_TIMEOUT = 10

    # in case of timeout errors
    GET_TASK_MAX_RETRIES = 2

    # get_task should retry at least once because some long running tasks
    # (e.g. configure_networks) will restart the agent (current implementation)
    # which most likely will result in first get_task message being lost
    # because agent was not listening on NATS and second retry message
    # will probably be received because agent came back up.
    GET_STATE_MAX_RETRIES = 2

    UPLOAD_BLOB_MAX_RETRIES = 3

    attr_accessor :id

    def self.with_agent_id(agent_id, instance_name, options = {})
      defaults = {
        retry_methods: {
          get_state: GET_STATE_MAX_RETRIES,
          get_task: GET_TASK_MAX_RETRIES,
          upload_blob: UPLOAD_BLOB_MAX_RETRIES,
        }
      }

      new('agent', agent_id, instance_name, defaults.merge(options))
    end

    def initialize(service_name, client_id, instance_name, options = {})
      @service_name = service_name
      @client_id = client_id
      @instance_name = instance_name || 'unknown'
      @nats_rpc = Config.nats_rpc
      @timeout = options[:timeout] || 45
      @logger = Config.logger
      @retry_methods = options[:retry_methods] || {}
      @resource_manager = Api::ResourceManager.new
    end

    def method_missing(method_name, *args)
      handle_message_with_retry(method_name, *args)
    end

    def get_state(*args, &blk)
      send_message(:get_state, *args, &blk)
    end

    def cancel_task(*args)
      send_message(:cancel_task, *args)
    end

    def list_disk(*args)
      send_message(:list_disk, *args)
    end

    def start(*args)
      send_message(:start, *args)
    end

    def prepare(*args)
      send_message(:prepare, *args)
    end

    def apply(*args)
      send_message(:apply, *args)
    end

    def compile_package(*args, &blk)
      send_message(:compile_package, *args, &blk)
    end

    def compile_package_with_signed_url(*args, &blk)
      send_message(:compile_package_with_signed_url, *args, &blk)
    end

    def drain(*args)
      send_cancellable_message(:drain, *args)
    end

    def fetch_logs(*args)
      send_message(:fetch_logs, *args)
    end

    def fetch_logs_with_signed_url(*args)
      send_message(:fetch_logs_with_signed_url, *args)
    end

    def migrate_disk(*args)
      send_message(:migrate_disk, *args)
    end

    def mount_disk(*args)
      send_message(:mount_disk, *args)
    end

    def unmount_disk(*args)
      send_message(:unmount_disk, *args)
    end

    def add_persistent_disk(*args)
      safe_send_message(:add_persistent_disk, *args)
    end

    def remove_persistent_disk(*args)
      safe_send_message(:remove_persistent_disk, *args)
    end

    def shutdown
      fire_and_forget(:shutdown)
    end

    def info(*args)
      begin
        send_message(:info, *args)
      rescue RpcRemoteException => e
        if e.message =~ /unknown message/
          @logger.warn("Ignoring info 'unknown message' error from the agent: #{e.inspect}")
          { 'api_version' => 0 }
        else
          raise
        end
      end
    end

    def delete_arp_entries(*args)
      fire_and_forget(:delete_arp_entries, *args)
    end

    def sync_dns(*args, &blk)
      send_nats_request_quietly(:sync_dns, args, &blk)
    end

    def sync_dns_with_signed_url(*args, &blk)
      send_nats_request_quietly(:sync_dns_with_signed_url, args, &blk)
    end

    def cancel_sync_dns(request_id)
      @nats_rpc.cancel_request(request_id)
    end

    def upload_blob(blob_id, payload_checksum, encoded_payload)
      begin
        send_message(:upload_blob, {
          'blob_id' => blob_id,
          'checksum' => payload_checksum,
          'payload' => encoded_payload,
        })
      rescue RpcRemoteException => e
        if e.message =~ /unknown message/
          @logger.warn("'upload_blob' 'unknown message' error from the agent: #{e.inspect}")
          raise Bosh::Director::AgentUnsupportedAction, 'Unsupported action: upload_blob'
        elsif e.message =~ /Opening blob store file: open \\var\\vcap\\data\\blobs.*: The system cannot find the path specified/
          @logger.warn("'upload_blob' error from the agent: #{e.inspect}")
          raise Bosh::Director::AgentUploadBlobUnableToOpenFile, "'Upload blob' action: failed to open blob"
        else
          raise
        end
      end
    end

    def update_settings(certs, disk_associations)
      safe_send_message(:update_settings, 'trusted_certs' => certs, 'disk_associations' => disk_associations)
    end

    def run_script(script_name, options)
      begin
        send_message(:run_script, script_name, options)
      rescue RpcRemoteException => e
        if e.message =~ /unknown message/
          @logger.warn("Ignoring run_script 'unknown message' error from the agent: #{e.inspect}. Received while trying to run: #{script_name}")
        else
          raise
        end
      end
    end

    def stop(*args)
      timeout = Timeout.new(STOP_MESSAGE_TIMEOUT)
      begin
        send_message_with_timeout(:stop, timeout, *args)
      rescue Exception => e
        if e.message.include? 'Timed out waiting for service'
          @logger.warn("Ignoring stop timeout error from the agent: #{e.inspect}")
        else
          raise
        end
      end
    end

    def run_errand(*args)
      start_task(:run_errand, *args)
    end

    def wait_for_task(agent_task_id, timeout = nil, &blk)
      task = get_task_status(agent_task_id)
      timed_out = false

      until task['state'] != 'running' || (timeout && timed_out = timeout.timed_out?)
        blk.call if block_given?
        sleep(DEFAULT_POLL_INTERVAL)
        task = get_task_status(agent_task_id)
      end

      @logger.debug("Task #{agent_task_id} timed out") if timed_out

      task['value']
    end

    def wait_until_ready(deadline = Config.agent_wait_timeout)
      old_timeout = @timeout
      @timeout = 1.0
      @deadline = Time.now.to_i + deadline

      begin
        Config.job_cancelled?
        ping
      rescue TaskCancelled => e
        @logger.debug('Task was cancelled. Stop waiting response from vm')
        raise e
      rescue RpcTimeout
        retry if @deadline - Time.now.to_i > 0
        raise RpcTimeout, "Timed out pinging to #{@client_id} after #{deadline} seconds"
      rescue RpcRemoteException => e
        retry if e.message =~ /^restarting agent/ && @deadline - Time.now.to_i > 0
        raise e
      ensure
        @timeout = old_timeout
      end
    end

    def send_nats_request_with_options(method_name, args, options, &callback)
      request = { :protocol => PROTOCOL_VERSION, :method => method_name, :arguments => args }
      recipient = "#{@service_name}.#{@client_id}"
      @nats_rpc.send_request(recipient, @client_id, request, options, &callback)
    end

    def send_nats_request_quietly(method_name, args, &callback)
      send_nats_request_with_options(method_name, args, { 'logging' => false }, &callback)
    end

    def send_nats_request(method_name, args, &callback)
      send_nats_request_with_options(method_name, args, { 'logging' => true }, &callback)
    end

    def handle_method(method_name, args, &blk)
      result = {}
      result.extend(MonitorMixin)

      cond = result.new_cond
      timeout_time = Time.now.to_f + @timeout

      request_id = send_nats_request(method_name, args) do |response|
        result.synchronize do
          inject_compile_log(response)
          result.merge!(response)
          cond.signal
        end
      end

      result.synchronize do
        while result.empty?
          timeout = timeout_time - Time.now.to_f
          begin
            blk.call if block_given?
          rescue TaskCancelled => e
            @nats_rpc.cancel_request(request_id)
            raise e
          end
          if timeout <= 0
            @nats_rpc.cancel_request(request_id)
            raise RpcTimeout,
                  "Timed out sending '#{method_name}' to instance: '#{@instance_name}', agent-id: '#{@client_id}' " \
                  "after #{@timeout} seconds"
          end
          cond.wait(timeout)
        end
      end

      if result.has_key?('exception')
        raise RpcRemoteException, format_exception(result['exception'])
      end

      result['value']
    end

    # Returns formatted exception information
    # @param [Hash|#to_s] exception Serialized exception
    # @return [String]
    def format_exception(exception)
      return exception.to_s unless exception.is_a?(Hash)

      msg = exception['message'].to_s

      if exception['backtrace']
        msg += "\n"
        msg += Array(exception['backtrace']).join("\n")
      end

      if exception['blobstore_id']
        blob = download_and_delete_blob(exception['blobstore_id'])
        msg += "\n"
        msg += blob.to_s
      end

      msg
    end

    private

    # the blob is removed from the blobstore once we have fetched it,
    # but if there is a crash before it is injected into the response
    # and then logged, there is a chance that we lose it
    def inject_compile_log(response)
      if response['value'] && response['value'].is_a?(Hash) &&
        response['value']['result'].is_a?(Hash) &&
        blob_id = response['value']['result']['compile_log_id']
        compile_log = download_and_delete_blob(blob_id)
        response['value']['result']['compile_log'] = compile_log
      end
    end

    # Downloads blob and ensures it's deleted from the blobstore
    # @param [String] blob_id Blob id
    # @return [String] Blob contents
    def download_and_delete_blob(blob_id)
      blob = @resource_manager.get_resource(blob_id)
      blob
    ensure
      @resource_manager.delete_resource(blob_id)
    end

    def handle_message_with_retry(message_name, *args, &blk)
      retries = @retry_methods[message_name] || 0
      begin
        handle_method(message_name, args, &blk)
      rescue RpcTimeout
        if retries > 0
          retries -= 1
          retry
        end
        raise
      end
    end

    def fire_and_forget(message_name, *args)
      request_id = send_nats_request_quietly(message_name, args)
      @nats_rpc.cancel_request(request_id)
    rescue => e
      @logger.warn("Ignoring '#{e.message}' error from the agent: #{e.inspect}. Received while trying to run: #{message_name} on client: '#{@client_id}'")
    end

    def send_message(method_name, *args, &blk)
      task = start_task(method_name, *args, &blk)
      if task['agent_task_id']
        wait_for_task(task['agent_task_id'], &blk)
      else
        task['value']
      end
    end

    def safe_send_message(method_name, *args, &blk)
      begin
        send_message(method_name, *args, &blk)
      rescue RpcRemoteException => e
        if e.message.match?(/unknown message/)
          @logger.warn("Ignoring #{method_name} 'unknown message' error from the agent: #{e.inspect}")
        else
          raise
        end
      end
    end

    def send_message_with_timeout(method_name, timeout, *args, &blk)
      task = start_task(method_name, *args)

      if task['agent_task_id']
        wait_for_task(task['agent_task_id'], timeout, &blk)
      else
        task['value']
      end
    end

    def send_cancellable_message(method_name, *args)
      task = start_task(method_name, *args)
      if task['agent_task_id']
        begin
          wait_for_task(task['agent_task_id']) { Config.job_cancelled? }
        rescue TaskCancelled => e
          cancel_task(task['agent_task_id'])
          raise e
        end
      else
        task['value']
      end
    end


    def start_task(method_name, *args, &blk)
      AgentMessageConverter.convert_old_message_to_new(handle_message_with_retry(method_name, *args, &blk))
    end

    def get_task_status(agent_task_id)
      AgentMessageConverter.convert_old_message_to_new(get_task(agent_task_id))
    end
  end
end
