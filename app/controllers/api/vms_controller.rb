module Api
  class VmsController < BaseController
    extend Api::Mixins::CentralAdmin
    include Api::Mixins::PolicySimulation
    include Api::Mixins::Genealogy
    include Subcollections::Accounts
    include Subcollections::Cdroms
    include Subcollections::Compliances
    include Subcollections::CustomAttributes
    include Subcollections::Disks
    include Subcollections::Metrics
    include Subcollections::MetricRollups
    include Subcollections::Policies
    include Subcollections::PolicyProfiles
    include Subcollections::SecurityGroups
    include Subcollections::Snapshots
    include Subcollections::Software
    include Subcollections::Tags

    def start_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Starting", :method_name => "start", :supports => true)
    end
    central_admin :start_resource, :start

    def stop_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Stopping", :method_name => "stop", :supports => true)
    end
    central_admin :stop_resource, :stop

    def suspend_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Suspending", :method_name => "suspend", :supports => true)
    end
    central_admin :suspend_resource, :suspend

    def pause_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Pausing", :method_name => "pause", :supports => true)
    end

    def shelve_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Shelving", :method_name => "shelve", :supports => true)
    end

    def shelve_offload_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Shelve-Offloading", :method_name => "shelve_offload", :supports => true)
    end

    def edit_resource(type, id, data)
      edit_resource_with_genealogy(type, id, data)
    rescue => err
      raise BadRequestError, "Cannot edit VM - #{err}"
    end

    def delete_resource(type, id, _data = nil)
      enqueue_ems_action(type, id, "Deleting", :method_name => "destroy")
    end

    def set_owner_resource(type, id = nil, data = nil)
      api_resource(type, id, "Setting owner of") do |vm|
        owner = data.blank? ? "" : data["owner"].strip
        raise BadRequestError, "Must specify an owner" if owner.blank?
        user = User.lookup_by_identity(owner)
        raise BadRequestError, "Invalid user #{owner} specified" unless user

        vm.update!(:evm_owner => user, :miq_group => user.current_group)
        {}
      end
    end

    def add_lifecycle_event_resource(type, id = nil, data = nil)
      lifecycle_event = lifecycle_event_from_data(data)
      api_resource(type, id, "Adding Life Cycle Event #{lifecycle_event['event']} to") do |vm|
        LifecycleEvent.create_event(vm, lifecycle_event)
        {}
      end
    end

    def scan_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Scanning", :method_name => "scan", :supports => :smartstate_analysis, :role => "smartstate")
    end

    def add_event_resource(type, id = nil, data = nil)
      raise BadRequestError, "Must specify an id for adding an event to a #{type} resource" unless id

      data ||= {}

      api_resource(type, id, "Adding Event to") do |vm|
        event_timestamp = data["event_time"].blank? ? Time.now.utc : data["event_time"].to_s.to_time(:utc)

        vm.add_ems_event(data["event_type"].to_s, data["event_message"].to_s, event_timestamp)
        {}
      end
    end

    def reset_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Resetting", :method_name => "reset", :supports => true)
    end
    central_admin :reset_resource, :reset

    def reboot_guest_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Rebooting", :method_name => "reboot_guest", :supports => true)
    end
    central_admin :reboot_guest_resource, :reboot_guest

    def rename_resource(type, id, data = {})
      raise BadRequestError, "Must specify an id for renaming a #{type} resource" unless id

      new_name = data.blank? ? "" : data["new_name"].strip
      raise BadRequestError, "Must specify a new_name" if new_name.blank?

      api_action(type, id) do |klass|
        vm = resource_search(id, type, klass)
        api_log_info("Renaming #{vm_ident(vm)} to #{new_name}")

        result = validate_vm_for_action(vm, "rename")
        result = rename_vm(vm, new_name) if result[:success]
        result
      end
    end
    central_admin :rename_resource, :rename

    def shutdown_guest_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Shutting Down", :method_name => "shutdown_guest", :supports => true)
    end
    central_admin :shutdown_guest_resource, :shutdown_guest

    def refresh_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Refreshing", :method_name => :refresh_ems)
    end

    def request_console_resource(type, id = nil, data = nil)
      raise BadRequestError, "Must specify an id for requesting a console for a #{type} resource" unless id

      # NOTE:
      # for Future ?:
      #   data ||= {}
      #   protocol = data["protocol"] || "mks"
      # However, there are different entitlements for the different protocol as per miq_product_feature,
      # so we may go for different action, i.e. request_console_vnc
      # protocol = "mks"
      protocol = data["protocol"] || "vnc"

      args = [User.current_user.userid, MiqServer.my_server.id, protocol]
      enqueue_ems_action(type, id, "Requesting Console", :method_name => "remote_console_acquire_ticket", :args => args) do |vm|
        # NOTE: we are queuing the :remote_console_acquire_ticket and returning the task id and href.
        #
        # The remote console ticket/info can be stashed in the task's context_data by the *_acquire_ticket method
        vm.validate_remote_console_acquire_ticket(protocol)
      end
    end

    def set_miq_server_resource(type, id, data)
      if data['miq_server'].empty?
        api_resource(id, type, "Removing MiqServer") do |vm|
          vm.miq_server = nil
        end
      else
        api_resource(id, type, "Setting MiqServer") do |vm|
          miq_server_id = parse_id(data['miq_server'], :servers)
          raise BadRequest, 'Must specify a valid miq_server href or id' unless miq_server_id

          miq_server = resource_search(miq_server_id, :servers)
          vm.miq_server = miq_server
        end
      end
    end

    def request_retire_resource(type, id = nil, data = nil)
      raise BadRequestError, "Must specify an id for retiring a #{type} resource" unless id

      if data && data["date"]
        opts = {:date => data["date"]}
        opts[:warn] = data["warn"] if data["warn"]
        enqueue_action(type, id, "Retiring on #{data["date"]}", :method_name => "retire", :role => "automate", :args => [opts])
      else
        enqueue_action(type, id, "Retiring immediately", :method_name => "make_retire_request", :role => "automate", :args => [User.current_user.id])
      end
    end
    alias retire_resource request_retire_resource

    def check_compliance_resource(type, id, _data = nil)
      enqueue_ems_action(type, id, "Check Compliance for", :method_name => "check_compliance", :supports => true)
    end

    def options
      return super unless @req.subcollection?

      # Try to look for subcollection specific options
      subcollection_options_method = "#{@req.subject}_subcollection_options"
      return super unless respond_to?(subcollection_options_method)

      vm = resource_search(params[:c_id], @req.collection)
      render_options(@req.collection.to_sym, send(subcollection_options_method, vm))
    end

    private

    def miq_server_message(miq_server)
      miq_server ? "Set miq_server id:#{miq_server.id}" : "Removed miq_server"
    end

    def vm_ident(vm)
      "VM id:#{vm.id} name:'#{vm.name}'"
    end

    def validate_vm_for_action(vm, action)
      action_result(vm.supports?(action), vm.unsupported_reason(action.to_sym))
    end

    def add_lifecycle_event_vm(vm, lifecycle_event)
      desc = "#{vm_ident(vm)} adding lifecycle event=#{lifecycle_event['event']} message=#{lifecycle_event['message']}"
      event = LifecycleEvent.create_event(vm, lifecycle_event)
      action_result(event.present?, desc)
    rescue => err
      action_result(false, err.to_s)
    end

    def lifecycle_event_from_data(data)
      data ||= {}
      data = data.slice("event", "status", "message", "created_by")
      data.keys.each { |k| data[k] = data[k].to_s }
      data
    end

    def vm_event(vm, event_type, event_message, event_time)
      desc = "Adding Event type=#{event_type} message=#{event_message}"
      event_timestamp = event_time.blank? ? Time.now.utc : event_time.to_time(:utc)

      vm.add_ems_event(event_type, event_message, event_timestamp)
      action_result(true, desc)
    rescue => err
      action_result(false, err.to_s)
    end

    def rename_vm(vm, new_name)
      desc = "#{vm_ident(vm)} renaming to #{new_name}"
      task_id = vm.rename_queue(User.current_user.userid, new_name)
      action_result(true, desc, :task_id => task_id)
    rescue => err
      action_result(false, err.to_s)
    end
  end
end
