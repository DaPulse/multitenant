require 'active_record'

# Multitenant: making cross tenant data leaks a thing of the past...since 2011
module Multitenant
  class AccessException < RuntimeError
  end
  
  class << self
    CURRENT_TENANT = 'Multitenant.current_tenant'.freeze
    ALLOW_DANGEROUS = 'Multitenant.allow_dangerous_cross_tenants'.freeze
    EXTRA_TENANT_IDS = 'Multitenant.extra_tenant_ids'.freeze
    ALLOW_NEXT_TENANT_OPERATION = 'Multitenant.allow_next_tenant_operation'.freeze

    @@multitenant_violation_log_sample_rate = 0

    def set_multitenant_violation_log_sample_rate(sample_rate)
      @@multitenant_violation_log_sample_rate = sample_rate
    end

    def multitenant_violation_log_sample_rate
      @@multitenant_violation_log_sample_rate
    end
    
    def allow_next_tenant_operation
      Thread.current[ALLOW_NEXT_TENANT_OPERATION] = true
    end

    def current_tenant
      Thread.current[CURRENT_TENANT]
    end

    def current_tenant=(value)
      if current_tenant != value && value != nil
        log_multitenant_violation_if_needed('current_tenant_set')
      end
      
      _set_current_tenant(value)
    end

    def allow_dangerous_cross_tenants
      Thread.current[ALLOW_DANGEROUS]
    end

    def allow_dangerous_cross_tenants=(value)
      if value && !allow_dangerous_cross_tenants
        log_multitenant_violation_if_needed('allow_dangerous_cross_tenants_set')
      end

      _set_allow_dangerous_cross_tenants(value)
    end

    def extra_tenant_ids
      Thread.current[EXTRA_TENANT_IDS]
    end

    def extra_tenant_ids=(value)
      Thread.current[EXTRA_TENANT_IDS] = value
    end

    # execute a block scoped to the current tenant
    # unsets the current tenant after execution
    def with_tenant(tenant, options = {}, &block)
      if current_tenant != tenant && tenant != nil
        log_multitenant_violation_if_needed('with_tenant')
      end

      previous_tenant = Multitenant.current_tenant
      _set_current_tenant(tenant)
      
      previous_extra_tenant_ids = Multitenant.extra_tenant_ids
      Multitenant.extra_tenant_ids = options[:extra_tenant_ids] if options[:extra_tenant_ids]
      yield
    ensure
      _set_current_tenant(previous_tenant)
      Multitenant.extra_tenant_ids = previous_extra_tenant_ids
    end

    def dangerous_cross_tenants(&block)
      if !allow_dangerous_cross_tenants
        log_multitenant_violation_if_needed('dangerous_cross_tenants')
      end
      
      previous_value = Multitenant.allow_dangerous_cross_tenants
      _set_allow_dangerous_cross_tenants(true)
      
      Multitenant.with_tenant(nil) do
        yield
      end
    ensure
      _set_allow_dangerous_cross_tenants(previous_value)
    end
    
    private
    
    def _set_current_tenant(value)
      Thread.current[CURRENT_TENANT] = value
    end
    
    def _set_allow_dangerous_cross_tenants(value)
      Thread.current[ALLOW_DANGEROUS] = value
    end
    
    def log_multitenant_violation_if_needed(kind)
      if Thread.current[ALLOW_NEXT_TENANT_OPERATION]
        Thread.current[ALLOW_NEXT_TENANT_OPERATION] = false
        return
      end

      return unless Random.rand < Multitenant.multitenant_violation_log_sample_rate

      caller_frame = caller(2, 1).first rescue 'unknown'

      $logger.warn(
        tag: 'multitenant_violation',
        message: 'multitenant usage outside allowed contexts',
        kind: kind,
        caller: caller_frame
      )
    rescue => e
      begin
        $logger.error(tag: 'multitenant_violation', message: 'error while logging multitenant violation', error: e.message)
      rescue
      end
    end
  end

  module ActiveRecordExtensions
    # configure the current model to automatically query and populate objects based on the current tenant
    # see Multitenant#current_tenant
    def belongs_to_multitenant(association = :tenant)
      reflection = reflect_on_association association
      association_key = reflection.foreign_key.to_s
      before_validation Proc.new {|m|
        next unless Multitenant.current_tenant
        tenant_id = m.send association_key
        if tenant_id.nil? then
          m.send "#{association}=".to_sym, Multitenant.current_tenant

          if Thread.current[:unauthenticated_route]
            $logger.info(
              message: 'account_id was assigned by multitenant in an unauthenticated route',
              request_path: Thread.current[:request_path],
              request_domain: Thread.current[:request_domain]
            )
          end
        elsif tenant_id != Multitenant.current_tenant.id
          raise AccessException, "Can't create a new instance for tenant #{tenant_id} while Multitenant.current_tenant is #{Multitenant.current_tenant.id}"
        end          
      }, :on => :create
      
      # Prevent updating objects to a different tenant
      before_save Proc.new {|m|
        next unless Multitenant.current_tenant
        tenant_id = m.send association_key.to_sym
        raise AccessException, "Trying to update object in to tenant #{tenant_id} while in current_tenant #{Multitenant.current_tenant.id}" unless tenant_id == Multitenant.current_tenant.id
      }
      
      default_scope -> () {
        if Multitenant.current_tenant.present?
          tenant_ids = Multitenant.extra_tenant_ids.present? ? Multitenant.extra_tenant_ids + [Multitenant.current_tenant.id] : Multitenant.current_tenant.id
          where({association_key => tenant_ids})
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
            elsif Thread.current[:current_queue].present?
              #log once in 100 to make less logs
              $logger.info({
                message: '[sidekiq] multitenant account is not defined',
                current_queue: Thread.current[:current_queue],
                klass: self.to_s
              })
              raise SidekiqMultitenantError
            end
            next nil # do nothing
          rescue SidekiqMultitenantError => e
            raise e
          rescue StandardError => e
            next nil # do nothing
          end
        end
      }
    end
  end
end
ActiveRecord::Base.extend Multitenant::ActiveRecordExtensions

class SidekiqMultitenantError < StandardError
  def message
    '[sidekiq] multitenant account is not defined'
  end
end