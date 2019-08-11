require 'active_record'

# Multitenant: making cross tenant data leaks a thing of the past...since 2011
module Multitenant
  class AccessException < RuntimeError
  end
  
  class << self
    CURRENT_TENANT = 'Multitenant.current_tenant'.freeze
    ALLOW_DANGEROUS = 'Multitenant.allow_dangerous_cross_tenants'.freeze

    def current_tenant
      ap "********************"
      ap "TENANT: #{Thread.current[CURRENT_TENANT]}"
      ap "Account ID: #{Thread.current[CURRENT_TENANT].id}" if Thread.current[CURRENT_TENANT].present?
      ap "********************"
      Thread.current[CURRENT_TENANT]
    end

    def current_tenant=(value)
      Thread.current[CURRENT_TENANT] = value
    end

    def allow_dangerous_cross_tenants
      Thread.current[ALLOW_DANGEROUS]
    end

    def allow_dangerous_cross_tenants=(value)
      Thread.current[ALLOW_DANGEROUS] = value
    end

    # execute a block scoped to the current tenant
    # unsets the current tenant after execution
    def with_tenant(tenant, &block)
      previous_tenant = Multitenant.current_tenant
      Multitenant.current_tenant = tenant
      yield
    ensure
      Multitenant.current_tenant = previous_tenant
    end

    def dangerous_cross_tenants(&block)
      previous_value = Multitenant.allow_dangerous_cross_tenants
      Multitenant.allow_dangerous_cross_tenants = true
      Multitenant.with_tenant(nil) do
        yield
      end
    ensure
      Multitenant.allow_dangerous_cross_tenants = previous_value
    end
  end

  module ActiveRecordExtensions
    # configure the current model to automatically query and populate objects based on the current tenant
    # see Multitenant#current_tenant
    def belongs_to_multitenant(association = :tenant)
      reflection = reflect_on_association association
      before_validation Proc.new {|m|
        next unless Multitenant.current_tenant
        tenant = m.send "#{association}"
        if tenant.nil? then
          m.send "#{association}=".to_sym, Multitenant.current_tenant
        elsif tenant.id != Multitenant.current_tenant.id
          raise AccessException, "Can't create a new instance for tenant #{tenant.id} while Multitenant.current_tenant is #{Multitenant.current_tenant.id}"
        end          
      }, :on => :create
      
      # Prevent updating objects to a different tenant
      before_save Proc.new {|m|
        next unless Multitenant.current_tenant
        tenant = m.send "#{association}".to_sym
        raise AccessException, "Trying to update object in to tenant #{tenant.id} while in current_tenant #{Multitenant.current_tenant.id}" unless tenant.id == Multitenant.current_tenant.id
      }
      
      default_scope -> () {
        if Multitenant.current_tenant.present?
          where({reflection.foreign_key => Multitenant.current_tenant.id})
        elsif Multitenant.allow_dangerous_cross_tenants == true
          next nil # do nothing
        else
          begin
            # log only requests to app servers
            if Thread.current[:request_path].present?
              $logger.info({
                message: 'multitenant account is not defined',
                request_path: Thread.current[:request_path],
                current_queue: Thread.current[:current_queue],
                klass: self.to_s
              })
            end
            next nil # do nothing
          rescue StandardError => e
            next nil # do nothing
          end
        end
      }
    end
  end
end
ActiveRecord::Base.extend Multitenant::ActiveRecordExtensions
