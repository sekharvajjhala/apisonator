require 'json'
require 'ruby-debug'

require '3scale/backend/transactor/notify_job'
require '3scale/backend/transactor/process_job'
require '3scale/backend/transactor/report_job'
require '3scale/backend/transactor/status'

module ThreeScale
  module Backend
    # Methods for reporting and authorizing transactions.
    module Transactor
      include Core::StorageKeyHelpers

      extend self

      def report(provider_key, transactions)
        service_id = Service.load_id!(provider_key)

				report_enqueue(service_id, transactions)
        #Resque.enqueue(ReportJob, service_id, transactions)

        notify(provider_key, 'transactions/create_multiple' => 1,
                             'transactions' => transactions.size)
      end

      VALIDATORS = [Validators::Key,
                    Validators::Referrer,
                    Validators::ReferrerFilters,
                    Validators::State,
                    Validators::Limits]

      VALIDATORS_WITHOUT_LIMITS = [Validators::Key,
                                   Validators::Referrer,
                                   Validators::ReferrerFilters,
                                   Validators::State]

      OAUTH_VALIDATORS = [Validators::OauthSetting,
                          Validators::OauthKey,
                          Validators::RedirectUrl,
                          Validators::Referrer,
                          Validators::ReferrerFilters,
                          Validators::State,
                          Validators::Limits]

      OAUTH_VALIDATORS_WITHOUT_LIMITS = [Validators::OauthSetting,
                                         Validators::OauthKey,
                                         Validators::RedirectUrl,
                                         Validators::Referrer,
                                         Validators::ReferrerFilters,
                                         Validators::State]

      def authorize(provider_key, params, options = {})
        notify(provider_key, 'transactions/authorize' => 1)

        service     = Service.load!(provider_key)
        application = Application.load_by_id_or_user_key!(service.id,
                                                          params[:app_id],
                                                          params[:user_key])

        params = check_for_users(service, application, params)
        options[:avoid_cache] = true
        if not options[:avoid_cache]
          status = Status.new(:service     => service, :application => application).tap do |st|
            VALIDATORS_WITHOUT_LIMITS.all? do |validator|
              if validator == Validators::Referrer && !st.service.referrer_filters_required?
                true
              else
                validator.apply(st, params)
              end
            end
          end

          if status.authorized?
            return get_status_cached(service, application, params, {:add_usage_on_report => false, :add_usage_on_limit_check =>true})
          else
            return [status, nil, nil]
          end

        else
          usage  = load_current_usage(application)
          status = Status.new(:service     => service, :application => application, :values => usage).tap do |st|
            VALIDATORS.all? do |validator|
              if validator == Validators::Referrer && !st.service.referrer_filters_required?
                true
              else
                validator.apply(st, params)
              end
            end
          end 
          return [status, nil, nil]
        end
      end

      def oauth_authorize(provider_key, params, options = {})
        notify(provider_key, 'transactions/authorize' => 1)

        service     = Service.load!(provider_key)
        application = Application.load_by_id_or_user_key!(service.id,
                                                          params[:app_id],
                                                          params[:user_key])

        params = check_for_users(service, application, params)

        options[:avoid_cache] = true
        if not options[:avoid_cache]
          Status.new(:service     => service, :application => application).tap do |status|
            OAUTH_VALIDATORS_WITHOUT_LIMITS.all? do |validator|
              if validator == Validators::Referrer && !status.service.referrer_filters_required?
                true
              else
                validator.apply(status, params)
              end
            end
          end

          if status.authorized?
            return get_status_cached(service, application, params, {:add_usage_on_report => false, :add_usage_on_limit_check =>true})
          else
            return [status, nil, nil]
          end
        else
          usage = load_current_usage(application)
          status = Status.new(:service     => service, :application => application, :values => usage).tap do |status|
            OAUTH_VALIDATORS.all? do |validator|
              if validator == Validators::Referrer && !status.service.referrer_filters_required?
                true
              else
                validator.apply(status, params)
              end
            end
          end
          return [status, nil, nil]
        end
      end

      def authrep_2(provider_key, params, options ={})

        status = nil
        service = Service.load!(provider_key)
        application =  Application.load_by_id_or_user_key!(service.id,
                                                          params[:app_id],
                                                          params[:user_key])
				
        params = check_for_users(service, application, params)

        
        status = Status.new(:service     => service, :application => application).tap do |st|
          VALIDATORS_WITHOUT_LIMITS.all? do |validator|
            if validator == Validators::Referrer && !st.service.referrer_filters_required?
              true
            else
              validator.apply(st, params)
            end
          end
        end

        if status.authorized?
          status , cached_status_text, cached_status_result = get_status_cached(service, application, params, {:add_usage_on_report => true, :add_usage_on_limit_check =>true})
          # FIXME: the following line looks like ...
          if (!params[:usage].nil? && !params[:usage].empty? && ((!status.nil? && status.authorized?) || (status.nil? && !cached_status_result.nil? && cached_status_result))) 
            #if (cached_status_result.nil? || cached_status_result) && status.authorized? && !params[:usage].nil? && !params[:usage].empty?
            ## don't forget to add the user_id
            report_enqueue(service.id, ({ 0 => {"app_id" => application.id, "usage" => params[:usage], "user_id" => params[:user_id]}}))
            notify(provider_key, 'transactions/authorize' => 1, 'transactions/create_multiple' => 1, 'transactions' => params[:usage].size)
          else
            notify(provider_key, 'transactions/authorize' => 1)
          end
          return [status , cached_status_text, cached_status_result]
        else
          notify(provider_key, 'transactions/authorize' => 1)
          return [status, nil, nil]
        end

      rescue ThreeScale::Backend::ApplicationNotFound, ThreeScale::Backend::UserNotDefined => e 
        # we still want to track these
        notify(provider_key, 'transactions/authorize' => 1)
        raise e
      end

      
      def authrep(provider_key, params, options ={})
        status = nil
        user = nil
        service = Service.load!(provider_key)
        application =  Application.load_by_id_or_user_key!(service.id,
                                                          params[:app_id],
                                                          params[:user_key])

        if not (params[:user_id].nil? || params[:user_id].empty?)
          ## user_id on the paramters
          user = User.load!(service,params[:user_id])
          raise UserRequiresRegistration, service.id, params[:user_id] if user.nil?     
        else
          raise UserNotDefined, application.id if application.user_required?
          params[:user_id]=nil
        end

        status = run_validators(VALIDATORS_WITHOUT_LIMITS,service,application,user,params)
        if status.authorized?
          cached_status_text = nil
          cached_status_result = nil

          usage = load_current_usage(application)
          user_usage = load_user_current_usage(user) unless user.nil?
          status = Status.new(:service     => service, :application => application, :values => usage, :user => user, :user_values => user_usage)

          Validators::Limits.apply(status,params)
          # FIXME: same here, this should be rewritten
          if (!params[:usage].nil? && !params[:usage].empty? && ((!status.nil? && status.authorized?) || (status.nil? && !cached_status_result.nil? && cached_status_result))) 
            report_enqueue(service.id, ({ 0 => {"app_id" => application.id, "usage" => params[:usage], "user_id" => params[:user_id]}}))
            notify(provider_key, 'transactions/authorize' => 1, 'transactions/create_multiple' => 1, 'transactions' => params[:usage].size)
          else
            notify(provider_key, 'transactions/authorize' => 1)
          end
          return [status , cached_status_text, cached_status_result]
        else
          notify(provider_key, 'transactions/authorize' => 1)
          return [status, nil, nil]
        end

      rescue ThreeScale::Backend::ApplicationNotFound, ThreeScale::Backend::UserNotDefined => e 
        # we still want to track these
        notify(provider_key, 'transactions/authorize' => 1)
        raise e
      end

      def self.put_limit_violation(application_id, expires_in)
        key = "limit_violations/#{application_id}"
        storage.pipelined do 
          storage.set(key,1) 
          storage.expire(key,expires_in) 
          storage.sadd("limit_violations_set",application_id)
        end
      end

      ## this one is hacky, handle with care. This updates the cached xml so that we can increment 
      ## the current_usage. TODO: we can do limit checking here, however, the non-cached authrep does not	
      ## cover this corner case either, e.g. it could be that the output is <current_value>101</current_value>
      ## and <max_value>100</max_value> and still be authorized, the next authrep with fail be limits though.
      ## This would have been much more elegant if we were caching serialized objects, but binary marshalling
      ## is extremely slow, divide performance by 2, and marshalling is faster than json, yaml, byml, et
      ## (benchmarked)
      def clean_cached_xml(xmlstr, options = {})
        v = xmlstr.split("|.|")
        newxmlstr = ""
        limit_violation_without_usage = false
        limit_violation_with_usage = false

        i=0
        v.each do |str|
          if (i%2==1)
            metric, curr_value, max_value = str.split(",")
            curr_value = curr_value.to_i
            max_value = max_value.to_i
            inc = 0
            inc = options[:usage][metric].to_i unless options[:usage].nil?

            limit_violation_without_usage = (curr_value > max_value) unless limit_violation_without_usage
            limit_violation_with_usage = (curr_value + inc > max_value) unless limit_violation_with_usage

            if options[:add_usage_on_report]
              str = (curr_value + inc).to_s
            else
              str = curr_value.to_s
            end
          end

          newxmlstr << str
          i += 1
        end
        return [newxmlstr, limit_violation_without_usage, limit_violation_with_usage]
      end

      ## preemptive_usage is whether or not the usage[] from params needs
      ## to be accounted for in the calculation of the limits
      ## options[:add_usage]=true, add the usage in the result
      ## options[:obey_limits]=true, returns the real status, not from cache, 
      ## if the usage (+ the params[usage] if :add_usage==true) 
      ## are above the max_value
      ## {:add_usage_on_report => true, :add_usage_on_limit_check => false}
      def get_status_cached(service, application, params, options = {}) 
        status = nil

        ## app_user_key is the application.id if the plan is :default and application.id#user_id if the plan is :user
        app_user_key = application_and_user_key(application,params[:user_id])
				
        ismember, cached_status_text = storage.pipelined do 
          storage.sismember("limit_violations_set",app_user_key)
          cached_status_text = storage.get("cached_status/#{app_user_key}")
        end
        cached_status_result = false
        cached_status_result = true if (ismember==0 || ismember==false) 

        if not cached_status_text.nil?
          options[:usage] = params[:usage] 
          cached_status_text, violation_without_usage, violation_with_usage = clean_cached_xml(cached_status_text, options)
          if not (violation_without_usage || violation_with_usage)
            return [status, cached_status_text, cached_status_result] 
          end
        end

        ## could not get the cached value or the violation just ellapsed
        cached_status_result = nil					
        cached_status_text = nil

        usage = load_current_usage(application)

        ## rebuild status to add the usage, @values in Status is readonly?
        status = Status.new(:service => service, :application => application, :values => usage)
        ## don't do Validators::Limits.apply(status,params) to avoid preemptive checking
        ## of the usage

        if options[:add_usage_on_limit_check]
          Validators::Limits.apply(status,params)
        else
          Validators::Limits.apply(status,{})
        end

        if status.authorized?
          ## it just violated the Limits, add to the violation set
          storage.pipelined do 
            key = "cached_status/#{app_user_key}"
            storage.set(key,status.to_xml({:anchors_for_caching => true}))
            storage.expire(key,60-Time.now.sec)
            storage.srem("limit_violations_set",app_user_key)
          end
        else ## it just violated the Limits, add to the violation set
          storage.pipelined do 
            key = "cached_status/#{app_user_key}"
            storage.set(key,status.to_xml({:anchors_for_caching => true}))
            storage.expire(key,60-Time.now.sec)
            storage.sadd("limit_violations_set",app_user_key)
          end 
        end
        return [status, cached_status_text, cached_status_result]
      end

      private

      def run_validators(validators_set, service, application, user, params)
        status = Status.new(:service => service, :application => application).tap do |st|
          validators_set.all? do |validator|
            if validator == Validators::Referrer && !st.service.referrer_filters_required?
              true
            else
              validator.apply(st, params)
            end
          end
        end
        return status
      end

      def check_for_users(service, application, params)
        if application.user_required? 
          raise UserNotDefined, application.id if params[:user_id].nil? || params[:user_id].empty?

          if service.user_registration_required?
            raise UserRequiresRegistration, service.id, params[:user_id] unless service.user_exists?(params[:user_id])
          end
        else
          ## for sanity, it's important to get rid of the request parameter :user_id if the 
          ## plan is default. :user_id is passed all the way up and sometimes its existance
          ## is the only way to know which application plan we are in (:default or :user) 
          params[:user_id] = nil
        end
        return params
      end

      def report_enqueue(service_id, data)
        Resque.enqueue(ReportJob, service_id, data)
      end

      def notify(provider_key, usage)
        Resque.enqueue(NotifyJob, provider_key, usage, encode_time(Time.now.getutc))
      end

      def encode_time(time)
        time.to_s
      end

      def parse_predicted_usage(service, usage)
        ## warning, empty method? :-)
      end

      def load_user_current_usage(user)
        pairs = user.usage_limits.map do |usage_limit|
          [usage_limit.metric_id, usage_limit.period]
        end
        # preloading metric names
        user.metric_names = ThreeScale::Core::Metric.load_all_names(user.service_id, pairs.map{|e| e.first}.uniq)
        now = Time.now.getutc
        keys = pairs.map do |metric_id, period|
          user_usage_value_key(user, metric_id, period, now)
        end
        raw_values = storage.mget(*keys)
        values     = {}
        pairs.each_with_index do |(metric_id, period), index|
          values[period] ||= {}
          values[period][metric_id] = raw_values[index].to_i
        end
        values
      end

      def load_current_usage(application)
        pairs = application.usage_limits.map do |usage_limit|
          [usage_limit.metric_id, usage_limit.period]
        end
        ## Warning this makes the test transactor_test.rb fail, weird because it didn't happen before
        if pairs.nil? or pairs.size==0 
          return {}
        end
        # preloading metric names
        application.metric_names = ThreeScale::Core::Metric.load_all_names(application.service_id, pairs.map{|e| e.first}.uniq)
        now = Time.now.getutc
        keys = pairs.map do |metric_id, period|
          usage_value_key(application, metric_id, period, now)
        end
        raw_values = storage.mget(*keys) 
        values     = {}
        pairs.each_with_index do |(metric_id, period), index|
          values[period] ||= {}
          values[period][metric_id] = raw_values[index].to_i
        end

        values
      end

      def usage_value_key(application, metric_id, period, time)
        encode_key("stats/{service:#{application.service_id}}/" +
                   "cinstance:#{application.id}/metric:#{metric_id}/" +
                   "#{period}:#{time.beginning_of_cycle(period).to_compact_s}")
      end

      def user_usage_value_key(user, metric_id, period, time)
        encode_key("stats/{service:#{user.service_id}}/" +
                   "uinstance:#{user.username}/metric:#{metric_id}/" +
                   "#{period}:#{time.beginning_of_cycle(period).to_compact_s}")
      end

      #def usage_value_key(application, user_id, metric_id, period, time)
      #  encode_key("stats/{service:#{application.service_id}}/" +
      #             "cinstance:#{application_and_user_key(application,user_id)}/metric:#{metric_id}/" +
      #             "#{period}:#{time.beginning_of_cycle(period).to_compact_s}")
      #end

      ## this merges the application_id and the user_id to
      def application_and_user_key(application, user_id)
        key = "#{application.id}"
        key
      end

      def storage
        Storage.instance
      end
    end
  end
end
