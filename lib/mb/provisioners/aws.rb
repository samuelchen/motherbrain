require 'active_support/inflector'
require 'fog'

module MotherBrain
  module Provisioners
    # @author Michael Ivey <michael.ivey@riotgames.com>
    #
    # Provisioner adapter for AWS/Eucalyptus
    #
    class AWS
      include Provisioner
      
      register_provisioner :aws


      def initialize(options = {})
      end

      def access_key(manifest=nil)
        if manifest && manifest.options[:access_key]
          manifest.options[:access_key]
        elsif ENV['AWS_ACCESS_KEY']
          ENV['AWS_ACCESS_KEY']
        elsif ENV['EC2_ACCESS_KEY']
          ENV['EC2_ACCESS_KEY']
        else
          abort InvalidProvisionManifest.new("The provisioner manifest options hash needs a key 'access_key' or the AWS_ACCESS_KEY or EC2_ACCESS_KEY variables need to be set")
        end
      end

      def secret_key(manifest=nil)
        if manifest && manifest.options[:secret_key]
          manifest.options[:secret_key]
        elsif ENV['AWS_SECRET_KEY']
          ENV['AWS_SECRET_KEY']
        elsif ENV['EC2_SECRET_KEY']
          ENV['EC2_SECRET_KEY']
        else
          abort InvalidProvisionManifest.new("The provisioner manifest options hash needs a key 'secret_key' or the AWS_SECRET_KEY or EC2_SECRET_KEY variables need to be set")
        end
      end

      def endpoint(manifest=nil)
        if manifest && manifest.options[:endpoint]
          manifest.options[:endpoint]
        elsif ENV['EC2_URL']
          ENV['EC2_URL']
        else
          abort InvalidProvisionManifest.new("The provisioner manifest options hash needs a key 'endpoint' or the EC2_URL variable needs to be set")
        end
      end

      # Provision nodes in the environment based on the contents of the given manifest
      #
      # @param [Job] job
      #   a job to track the progress of this action
      # @param [String] env_name
      #   the name of the environment to put the nodes in
      # @param [Provisioner::Manifest] manifest
      #   a manifest describing the way the environment should look
      #
      # @option options [Boolean] :skip_bootstrap (false) what does this even do
      #
      # @raise [MB::ProvisionError]
      #   if a caught error occurs during provisioning
      #
      # @return [Array<Hash>]
      def up(job, env_name, manifest, plugin, options = {})
        job.set_status "starting provision"
        fog = fog_connection(manifest)
        validate_manifest_options(job, manifest)
        instances = create_instances(job, manifest, fog)
        verified_instances = verify_instances(job, fog, instances)
        verify_ssh(job, fog, verified_instances)
        instances_as_manifest(verified_instances)
      end

      def down(job, env_name)
        fog = fog_connection
        terminate_instances(job, fog, env_name)
        job.set_status "deleting chef_environment:#{env_name}"
        delete_environment(env_name)
      end

      def fog_connection(manifest=nil)
        Fog::Compute.new(provider: 'aws',
                         aws_access_key_id: access_key(manifest),
                         aws_secret_access_key: secret_key(manifest),
                         endpoint: endpoint(manifest))
      end

      def validate_manifest_options(job, manifest)
        job.set_status "validating manifest options"
        [:image_id, :key_name, :availability_zone].each do |key|
          unless manifest.options[key]
            abort InvalidProvisionManifest.new("The provisioner manifest options hash needs a key '#{key}' with the AWS #{key.to_s.camelize}")
          end
        end

        if manifest.options[:security_groups] && !manifest.options[:security_groups].is_a?(Array)
          abort InvalidProvisionManifest.new("The provisioner manifest options hash key 'security_groups' needs an array of security group names")
        end

        true
      end

      def instance_counts(manifest)
        manifest[:nodes].inject({}) do |result, element|
          result[element[:type]] ||= 0
          result[element[:type]] += element[:count].to_i
          result
        end
      end

      def create_instances(job, manifest, fog)
        job.set_status "creating instances"
        instances = {}
        instance_counts(manifest).each do |instance_type, count|
          run_instances job, fog, instances, instance_type, count, manifest.options
        end
        instances
      end

      def run_instances(job, fog, instances, instance_type, count, options)
        job.set_status "creating #{count} #{instance_type} instance#{count > 1 ? 's' : ''}"
        begin
          response = fog.run_instances options[:image_id], count, count, {
            'InstanceType' => instance_type,
            'Placement.AvailabilityZone' => options[:availability_zone],
            'KeyName' => options[:key_name]
          }
          log.debug response.inspect
        rescue Fog::Compute::AWS::Error => e
          job.set_status "Error: #{e}"
          abort AWSRunInstancesError.new(e)
        end
        if response.status == 200
          response.body["instancesSet"].each do |i|
            instances[i["instanceId"]] = {type: i["instanceType"], ipaddress: nil, status: i["instanceState"]["code"]}
          end
        else
          abort AWSRunInstancesError, response.error
        end
        instances
      end

      def pending_instances(instances)
        instances.select {|i,d| d[:status].to_i != 16}.keys
      end

      def verify_instances(job, fog, instances, tries=10)
        if tries <= 0
          jog.debug "Giving up. instances: #{instances.inspect}"
          abort AWSRunInstancesError, "giving up on instances :-("
        end
        job.set_status "waiting for instances to be ready"
        pending = pending_instances(instances)
        return if pending.empty?
        log.info "pending instances: #{pending.join(',')}"
        begin
          response = fog.describe_instances('instance-id'=> pending)
          log.debug response.inspect
          if response.status == 200 && response.body["reservationSet"]
            reserved_instances = response.body["reservationSet"].collect {|x| x["instancesSet"] }.flatten
            reserved_instances.each do |i|
              log.debug i.inspect
              instances[i["instanceId"]][:status]    = i["instanceState"]["code"]
              instances[i["instanceId"]][:ipaddress] = i["ipAddress"]
            end
            log.debug "instances: #{instances}"
            still_pending = pending_instances(instances)
            return instances if still_pending.empty?
            sleep 10
          else
            sleep 1
          end
        rescue Fog::Compute::AWS::NotFound
          sleep 10
        end
        verify_instances(job, fog, instances, tries-1)
      end

      def verify_ssh(job, fog, instances)
        # TODO: remember working ones, only keep checking pending ones
        servers = instances.collect {|i,d| fog.servers.get(i) }
        Fog.wait_for do
          job.set_status "waiting for instances to be SSHable"
          servers.all? do |s|
            s.username = Application.config[:ssh][:user]
            s.private_key_path = Application.config[:ssh][:keys].first
            s.sshable?
          end
        end
      end

      def instances_as_manifest(instances)
        instances.collect do |instance_id, instance|
          { instance_type: instance[:type], public_hostname: instance[:ipaddress] }
        end
      end

      def instance_ids(env_name)
        # TODO: throw up hands if AWS and Euca nodes in same env
        nodes = ridley.search(:node, "chef_environment:#{env_name}")
        nodes.collect do |node|
          instance_id = nil
          [:ec2, :eucalyptus].each do |k|
            instance_id = node.automatic[k][:instance_id] if node.automatic.has_key?(k)
          end
          instance_id
        end
      end

      def terminate_instances(job, fog, env_name)
        ids = instance_ids(env_name)
        job.set_status "Terminating #{ids.join(',')}"
        fog.terminate_instances ids
      end
    end
  end

  class AWSProvisionError < ProvisionError
    error_code(5200)
  end

  class AWSRunInstancesError < AWSProvisionError
    error_code(5201)
  end
end

