# -*- coding: utf-8 -*-
#
# Author:: Andrew Leonard (<andy@hurricane-ridge.com>)
#
# Copyright (C) 2013-2014, Andrew Leonard
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fog'
require 'securerandom'

require 'kitchen'

module Kitchen
  module Driver
    # Google Compute Engine driver for Test Kitchen
    #
    # @author Andrew Leonard <andy@hurricane-ridge.com>
    class Gce < Kitchen::Driver::SSHBase
      default_config :area, 'us-central1'
      default_config :autodelete_disk, true
      default_config :disk_size, 10
      default_config :machine_type, 'n1-standard-1'
      default_config :network, 'default'
      default_config :inst_name, nil
      default_config :service_accounts, nil
      default_config :tags, []
      default_config :username, ENV['USER']
      default_config :zone_name, nil
      default_config :google_key_location, nil
      default_config :google_json_key_location, nil
      default_config :preemptible, false
      default_config :auto_restart, false

      required_config :google_client_email
      required_config :google_project
      required_config :image_name

      def create(state)
        return if state[:server_id]

        instance = create_instance
        state[:server_id] = instance.identity

        info("GCE instance <#{state[:server_id]}> created.")

        wait_for_up_instance(instance, state)

      rescue Fog::Errors::Error, Excon::Errors::Error => ex
        raise ActionFailed, ex.message
      end

      def destroy(state)
        return if state[:server_id].nil?

        instance = connection.servers.get(state[:server_id])
        instance.destroy unless instance.nil?
        info("GCE instance <#{state[:server_id]}> destroyed.")
        state.delete(:server_id)
        state.delete(:hostname)
      end

      private

      def connection
        options = {
          provider: 'google',
          google_client_email: config[:google_client_email],
          google_project: config[:google_project]
        }

        [
          :google_key_location,
          :google_json_key_location
        ].each do |k|
          options[k] = config[k] unless config[k].nil?
        end

        Fog::Compute.new(options)
      end

      def create_disk
        disk = connection.disks.create(
          name: config[:inst_name],
          size_gb: config[:disk_size],
          zone_name: config[:zone_name],
          source_image: config[:image_name]
        )

        disk.wait_for { disk.ready? }
        disk
      end

      def create_instance
        config[:region] ||= config[:area]

        config[:inst_name] ||= generate_inst_name
        config[:zone_name] ||= select_zone

        disk = create_disk
        create_server(disk)
      end

      def create_server(disk)
        connection.servers.create(
          name: config[:inst_name],
          disks: [disk.get_as_boot_disk(true, config[:autodelete_disk])],
          machine_type: config[:machine_type],
          network: config[:network],
          service_accounts: config[:service_accounts],
          tags: config[:tags],
          zone_name: config[:zone_name],
          public_key_path: config[:public_key_path],
          username: config[:username],
          preemptible: config[:preemptible],
          on_host_maintenance: config[:preemptible] ? 'TERMINATE': 'MIGRATE',
          auto_restart: config[:auto_restart]
        )
      end

      def generate_inst_name
        # Inspired by generate_name from kitchen-rackspace
        name = instance.name.downcase
        name.gsub!(/([^-a-z0-9])/, '-')
        name = 't' + name unless name =~ /^[a-z]/
        base_name = name[0..25] # UUID is 36 chars, max name length 63
        gen_name = "#{base_name}-#{SecureRandom.uuid}"
        unless gen_name =~ /^[a-z]([-a-z0-9]*[a-z0-9])?$/
          fail "Invalid generated instance name: #{gen_name}"
        end
        gen_name
      end

      def select_zone
        if config[:region] == 'any'
          zone_regexp = /^[a-z]+\-/
        else
          zone_regexp = /^#{config[:region]}\-/
        end
        zones = connection.zones.select do |z|
          z.status == 'UP' && z.name.match(zone_regexp)
        end
        fail 'No up zones in region' unless zones.length >= 1
        zones.sample.name
      end

      def wait_for_up_instance(instance, state)
        instance.wait_for do
          print '.'
          ready?
        end
        print '(server ready)'
        state[:hostname] = instance.public_ip_address ||
          instance.private_ip_address
        wait_for_sshd(state[:hostname], config[:username])
        puts '(ssh ready)'
      end
    end
  end
end
