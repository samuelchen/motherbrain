ENV['RUBY_ENV'] ||= 'test'
ENV['MOTHERBRAIN_PATH'] ||= File.join(File.expand_path(File.dirname(__FILE__)), "tmp/.mb")
ENV['BERKSHELF_PATH'] ||= File.join(File.expand_path(File.dirname(__FILE__)), "tmp/.berkshelf")
ENV['CHEF_API_URL'] = 'http://localhost:28890'

require 'rubygems'
require 'bundler'
require 'rspec'
require 'json_spec'
require 'webmock/rspec'
require 'rack/test'
require 'motherbrain'
require 'chef_zero/server'

def setup_rspec
  require File.expand_path('../../spec/support/berkshelf.rb', __FILE__)
  Dir[File.join(File.expand_path("../../spec/support/**/*.rb", __FILE__))].each { |f| require f }

  RSpec.configure do |config|
    config.include JsonSpec::Helpers
    config.include MotherBrain::RSpec::Doubles
    config.include MotherBrain::Matchers
    config.include MotherBrain::SpecHelpers
    config.include MotherBrain::RSpec::Berkshelf
    config.include MotherBrain::RSpec::ChefServer
    config.include MotherBrain::Mixin::Services

    config.mock_with :rspec
    config.treat_symbols_as_metadata_keys_with_true_values = true
    config.filter_run focus: true
    config.run_all_when_everything_filtered = true

    config.before(:suite) do
      WebMock.disable_net_connect!(allow_localhost: true, net_http_connect_on_start: true)
      MB::RSpec::ChefServer.start
    end

    config.before(:all) do
      Celluloid.shutdown
      @config = generate_valid_config
      @app    = MB::Application.run!(@config)
      MB::Logging.setup(location: '/dev/null')
    end

    config.before(:each) do
      clean_tmp_path
      MB::RSpec::ChefServer.server.clear_data
    end
  end
end

if jruby?
  setup_rspec
else
  require 'spork'

  Spork.prefork do
    setup_rspec
  end

  Spork.each_run do
    require 'motherbrain'

    # Required to ensure Celluloid boots properly on each run
    Celluloid::Notifications::Fanout.supervise_as :notifications_fanout
    Celluloid::IncidentReporter.supervise_as :default_incident_reporter, STDERR
  end
end
