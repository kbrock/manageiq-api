module Api
  class ServicesController < BaseController
    include Subcollections::ServiceDialogs
    include Subcollections::Tags
    include Subcollections::Vms
    include Subcollections::OrchestrationStacks
    include Subcollections::MetricRollups
    include Subcollections::GenericObjects
    include Subcollections::CustomAttributes
    include Api::Mixins::Pictures

    alias fetch_services_picture fetch_picture

    def create_resource(_type, _id, data)
      validate_service_data(data)
      attributes = build_service_attributes(data)
      service    = collection_class(:services).create(attributes)
      validate_service(service)
      service
    end

    def edit_resource(type, id, data)
      attributes = build_service_attributes(data)
      super(type, id, attributes)
    end

    def add_resource_resource(type, id, data)
      api_resource(type, id, "Assigning resource to") do |svc|
        resource_type, resource = validate_resource(data)
        raise BadRequestError, "Cannot assign #{resource_type} to #{service_ident(svc)}" unless resource.respond_to? :add_to_service

        resource.add_to_service(svc)
        action_result(true, "Assigning #{model_ident(resource, resource_type)} to #{service_ident(svc)}")
      end
    end

    def remove_resource_resource(type, id, data)
      api_resource(type, id, "Removing Resource from") do |svc|
        resource_type, resource = validate_resource(data)

        svc.remove_resource(resource)
        action_result(true, "Removing resource #{model_ident(resource, resource_type)} from #{service_ident(svc)}")
      end
    end

    def remove_all_resources_resource(type, id, _data)
      api_resource(type, id, "Removed all resources from") do |svc|
        svc.remove_all_resources
      end
    end

    def reconfigure_resource(type, id = nil, data = nil)
      api_resource(type, id, "Reconfiguring") do |svc|
        # TODO: svc.supports?(:reconfigure)
        unless svc.validate_reconfigure
          raise BadRequest, "Reconfiguring is not available for #{service_ident(svc)}")
        end

        wf_result = submit_reconfigure_dialog(svc, data)
        {:result => wf_result[:request]}
      end
    end

    def start_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Starting", :method_name => "start")
    end

    def stop_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Stopping", :method_name => "stop")
    end

    def suspend_resource(type, id = nil, _data = nil)
      enqueue_ems_action(type, id, "Suspending", :method_name => "suspend")
    end

    def add_provider_vms_resource(type, id, data)
      api_resource(type, id, "Adding provider vms for") do |service|
        provider_id = parse_id(data['provider'], :providers)
        raise BadRequest, 'Must specify a valid provider href or id' unless provider_id
        provider = resource_search(provider_id, :providers)

        {:task_id => service.add_provider_vms(provider, data['uid_ems']).miq_task_id}
      end
    end

    def queue_chargeback_report_resource(type, id, _data)
      api_resource(type, id, "Queued chargeback report generation for") do |service|
        {:task_id => service.queue_chargeback_report_generation(:userid => User.current_userid).id}
      end
    end

    private

    def validate_resource(data)
      resource_href = data.fetch_path("resource", "href")
      raise "Must specify a resource reference" unless resource_href

      href = Href.new(resource_href)
      raise "Invalid resource href specified #{resource_href}" unless href.subject && href.subject_id

      resource = resource_search(href.subject_id, href.subject)
      [href.subject, resource]
    end

    def build_service_attributes(data)
      attributes                 = data.dup
      attributes['job_template'] = fetch_configuration_script(data['job_template']) if data['job_template']
      attributes['parent']       = fetch_service(data['parent_service']) if data['parent_service']
      if data['orchestration_manager']
        attributes['orchestration_manager'] = fetch_ext_management_system(data['orchestration_manager'])
      end
      if data['orchestration_template']
        attributes['orchestration_template'] = fetch_orchestration_template(data['orchestration_template'])
      end
      if data['job_options']
        # AnsibleTowerClient needs the keys to be symbols
        attributes['job_options'][:limit]      ||= data['job_options'].delete('limit')
        attributes['job_options'][:extra_vars] ||= data['job_options'].delete('extra_vars')
      end
      attributes.delete('parent_service')
      attributes
    end

    def validate_service_data(data)
      assert_id_not_specified(data, 'service')
    end

    def validate_service(service)
      if service.invalid?
        raise BadRequestError, "Failed to add new service -
            #{service.errors.full_messages.join(', ')}"
      end
    end

    def fetch_ext_management_system(data)
      orchestration_manager_id = parse_id(data, :providers)
      raise BadRequestError, 'Missing ExtManagementSystem identifier id' if orchestration_manager_id.nil?
      resource_search(orchestration_manager_id, :providers)
    end

    def fetch_service(data)
      service_id = parse_id(data, :services)
      raise BadRequestError, 'Missing Service identifier id' if service_id.nil?
      resource_search(service_id, :services)
    end

    def fetch_orchestration_template(data)
      orchestration_template_id = parse_id(data, :orchestration_templates)
      raise BadRequestError, 'Missing OrchestrationTemplate identifier id' if orchestration_template_id.nil?
      resource_search(orchestration_template_id, :orchestration_templates)
    end

    def fetch_configuration_script(data)
      configuration_script_id = parse_id(data, :configuration_script)
      raise BadRequestError, 'Missing ConfigurationScript identifier id' if configuration_script_id.nil?
      resource_search(configuration_script_id, :configuration_scripts)
    end

    def service_ident(svc)
      "Service id: #{svc.id} name:'#{svc.name}'"
    end

    def submit_reconfigure_dialog(svc, data)
      ra = svc.reconfigure_resource_action
      wf = ResourceActionWorkflow.new({}, User.current_user, ra, :target => svc)
      data.each { |key, value| wf.set_value(key, value) } if data.present?
      wf_result = wf.submit_request
      raise StandardError, Array(wf_result[:errors]).join(", ") if wf_result[:errors].present?
      wf_result
    end
  end
end
