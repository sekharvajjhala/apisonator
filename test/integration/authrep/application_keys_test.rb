require File.expand_path(File.dirname(__FILE__) + '/../../test_helper')

class AuthrepApplicationKeysTest < Test::Unit::TestCase
  include TestHelpers::AuthorizeAssertions
  include TestHelpers::Fixtures
  include TestHelpers::Integration

  include TestHelpers::AuthRep

  def setup
    Storage.instance(true).flushdb

    Memoizer.reset!

    setup_oauth_provider_fixtures

    @application = Application.save(:service_id => @service.id,
                                    :id         => next_id,
                                    :state      => :active,
                                    :plan_id    => @plan_id,
                                    :plan_name  => @plan_name)
  end

  test_authrep 'succeeds if no application key is defined nor passed' do |e|
    get e, :provider_key => @provider_key,
           :app_id       => @application.id

    assert_authorized
  end

  test_authrep 'succeeds if one application key is defined and the same one is passed' do |e|
    application_key = @application.create_key

    get e, :provider_key => @provider_key,
           :app_id       => @application.id,
           :app_key      => application_key

    assert_authorized
  end

  test_authrep 'succeeds if multiple application keys are defined and one of them is passed' do |e|
    application_key_one = @application.create_key
    _application_key_two = @application.create_key

    get e, :provider_key => @provider_key,
           :app_id       => @application.id,
           :app_key      => application_key_one

    assert_authorized
  end

  test_authrep 'does not authorize if application key is defined but not passed',
               except: :oauth_authrep do |e|
    @application.create_key

    get e, :provider_key => @provider_key,
           :app_id       => @application.id

    assert_not_authorized 'application key is missing'
  end

  test_authrep 'does not authorize if application key is defined but wrong one is passed' do |e|
    @application.create_key('foo')

    get e, :provider_key => @provider_key,
           :app_id       => @application.id,
           :app_key      => 'bar'

    assert_not_authorized 'application key "bar" is invalid'
  end

  test_authrep 'authorize with a random app key and a custom one' do |e|
    key1 = @application.create_key('foo_app_key')
    key2 = @application.create_key

    get e, :provider_key => @provider_key,
           :app_id       => @application.id,
           :app_key      => key1

    assert_authorized

    get e, :provider_key => @provider_key,
           :app_id       => @application.id,
           :app_key      => key2

    assert_authorized

    assert_equal key1, 'foo_app_key'
    assert_equal [key2, 'foo_app_key'].sort, @application.keys.sort
  end
end
