# Copyright (c) 2017 Oracle and/or its affiliates. All rights reserved.

require 'chef/knife'
require 'chef/knife/bmcs_common_options'
require 'chef/knife/bmcs_helper'

# Methods to extend the instance model
module ServerDetails
  attr_accessor :compartment_name
  attr_accessor :image_name
  attr_accessor :launchtime
  attr_accessor :vcn_id
  attr_accessor :vcn_name
end

# Methods to extend the vnic model
module VnicDetails
  attr_accessor :fqdn
  attr_accessor :subnet_name
end

class Chef
  class Knife
    # List BMCS instances. Note that this lists all instances in a
    # compartment, not just those that are set up as Chef nodes.
    class BmcsServerShow < Knife
      banner 'knife bmcs server show (options)'

      include BmcsHelper
      include BmcsCommonOptions

      deps do
        require 'oraclebmc'
      end

      option :instance_id,
             long: '--instance_id LIMIT',
             description: 'The OCID of the server to display. (required)'

      def lookup_compartment_name(compartment_id)
        compartments = identity_client.list_compartments(bmcs_config.tenancy, {})
        compartments.data && compartments.data.each do |compartment|
          next unless compartment.id == compartment_id
          return compartment.description || compartment.name
        end
      end

      def lookup_image_name(image_id)
        images = compute_client.list_images(compartment_id, {})
        images.data && images.data.each do |image|
          next unless image.id == image_id
          return image.display_name
        end
      end

      def lookup_vcn(compartment_id)
        vcns = network_client.list_vcns(compartment_id, {})
        vcns.data && vcns.data.each do |vcn|
          next unless vcn.compartment_id == compartment_id
          return vcn
        end
      end

      def add_server_details(server)
        server.extend ServerDetails

        server.launchtime = server.time_created.strftime('%a, %e %b %Y %T %Z')
        server.compartment_name = lookup_compartment_name(server.compartment_id)
        server.image_name = lookup_image_name(server.image_id)
        vcn = lookup_vcn(server.compartment_id)
        server.vcn_id = vcn.id
        server.vcn_name = vcn.display_name
      end

      def add_vnic_details(vnic)
        vnic.extend VnicDetails

        subnet = network_client.get_subnet(vnic.subnet_id, {})
        vnic.fqdn = vnic.hostname_label + '.' + subnet.data.subnet_domain_name if
          subnet.data && subnet.data.subnet_domain_name && vnic.hostname_label
        vnic.subnet_name = subnet.data.display_name if
          subnet.data && subnet.data.display_name
      end

      def run
        validate_required_params(%i[instance_id], config)
        vnic_array = []
        server = check_can_access_instance(config[:instance_id])
        error_and_exit 'Unable to retrieve instance' unless server.data
        add_server_details(server.data)
        vnics = compute_client.list_vnic_attachments(compartment_id, instance_id: config[:instance_id])
        vnics.data && vnics.data.each do |vnic|
          next unless vnic.lifecycle_state == 'ATTACHED'
          begin
            vnic_info = network_client.get_vnic(vnic.vnic_id, {})
            add_vnic_details(vnic_info.data)
          rescue OracleBMC::Errors::ServiceError => service_error
            raise unless service_error.serviceCode == 'NotAuthorizedOrNotFound'
          else
            # for now, only display information for primary vnic
            if vnic_info.data.is_primary == true
              vnic_array.push(vnic_info.data)
              break
            end
          end
        end

        display_server_info(config, server.data, vnic_array)
      end
    end
  end
end
