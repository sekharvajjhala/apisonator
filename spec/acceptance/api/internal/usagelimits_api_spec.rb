require_relative '../../acceptance_spec_helper'

resource 'UsageLimits (prefix: /services/:service_id/plans/:plan_id/usagelimits)' do
  set_app ThreeScale::Backend::API::Internal
  header 'Accept', 'application/json'
  header 'Content-Type', 'application/json'

  let(:service_id) { '7575' }
  let(:plan_id) { '100' }

  before do
    ThreeScale::Backend::Metric.delete(service_id, '100')
    ThreeScale::Backend::Metric.delete(service_id, '101')
    metric = ThreeScale::Backend::Metric.save(service_id: service_id, id: '100',
                                                 name: 'hits')
    metric_alt = ThreeScale::Backend::Metric.save(service_id: service_id, id: '101',
                                                   name: 'ads')
    @metric_h = { metric => { year: 1000, month: 200 },
                  metric_alt => { month: 100, day: 10 } }
    @metric_h.each do |m, h|
      ThreeScale::Backend::UsageLimit.save({service_id: m.service_id, plan_id: '100', metric_id: m.id}.merge!(h))
    end
  end

  get '/services/:service_id/plans/:plan_id/usagelimits/:metric_id/:period' do
    parameter :service_id, 'Service ID', required: true
    parameter :plan_id, 'Plan ID', required: true
    parameter :metric_id, 'Metric ID', required: true
    parameter :period, 'Period', required: true

    example 'Get UsageLimits' do
      @metric_h.each do |m, periods|
        periods.each do |period, value|
          do_request metric_id: m.id, period: period
          response_json['usagelimit']['service_id'].should == service_id
          response_json['usagelimit']['plan_id'].should == plan_id
          response_json['usagelimit']['metric_id'].should == m.id
          response_json['usagelimit'][period.to_s].should == value
          status.should == 200
        end
      end
    end
  end

  put '/services/:service_id/plans/:plan_id/usagelimits/:metric_id/:period' do
    parameter :service_id, 'Service ID', required: true
    parameter :plan_id, 'Plan ID', required: true
    parameter :metric_id, 'Metric ID', required: true
    parameter :period, 'Period', required: true
    parameter :usagelimit, 'UsageLimit attributes', required: true

    # need this to _not_ be memoized but eval'ed each time, see below
    define_method :raw_post do
      params.to_json
    end

    example 'Update UsageLimits' do
      @metric_h.each do |m, periods|
        periods.each do |p, value|
          do_request(metric_id: m.id, period: p, usagelimit: { p.to_sym => value.succ.to_s })
          response_json['usagelimit']['service_id'].should == service_id
          response_json['usagelimit']['plan_id'].should == plan_id
          response_json['usagelimit']['metric_id'].should == m.id
          response_json['usagelimit'][p.to_s].should == value.succ.to_s
          response_json['status'].should == 'modified'
          status.should == 200

          ThreeScale::Backend::UsageLimit.load_value(service_id, plan_id, m.id, p).
            should == value.succ
        end
      end
    end
  end

  delete '/services/:service_id/plans/:plan_id/usagelimits/:metric_id/:period' do
    parameter :service_id, 'Service ID', required: true
    parameter :plan_id, 'Plan ID', required: true
    parameter :metric_id, 'Metric ID', required: true
    parameter :period, 'Period', required: true

    example 'Delete UsageLimits' do
      @metric_h.each do |m, periods|
        periods.each do |period, value|
          do_request metric_id: m.id, period: period
          response_json['status'].should == 'deleted'
          status.should == 200

          ThreeScale::Backend::UsageLimit.load_value(service_id, plan_id, m.id, period).
            should be_nil
        end
      end
    end
  end
end